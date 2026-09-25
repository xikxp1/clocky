import Foundation
import IOBluetooth

@MainActor
protocol BluetoothChangeMonitoring: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// The backend only observes existing connections. It never scans, connects or pairs.
@MainActor
protocol BluetoothNotificationBackend: AnyObject {
    func pairedDevices() -> [any BluetoothNotificationDevice]
    func registerForConnections(
        _ onConnect: @escaping @Sendable (any BluetoothNotificationDevice) -> Void
    ) -> (any BluetoothNotificationRegistration)?
}

/// Callbacks may arrive on any thread; device queries and registration stay on MainActor.
protocol BluetoothNotificationDevice: AnyObject, Sendable {
    @MainActor var id: ObjectIdentifier { get }
    @MainActor var isConnected: Bool { get }
    @MainActor func registerForDisconnect(
        _ onDisconnect: @escaping @Sendable () -> Void
    ) -> (any BluetoothNotificationRegistration)?
}

/// Unregistration must be idempotent, including cleanup when the owner is released.
protocol BluetoothNotificationRegistration: AnyObject, Sendable {
    func unregister()
}

@MainActor
final class BluetoothChangeMonitor: BluetoothChangeMonitoring {
    private struct DisconnectObservation: Sendable {
        let id: UUID
        let device: any BluetoothNotificationDevice
        let registration: any BluetoothNotificationRegistration
    }

    private let backend: any BluetoothNotificationBackend
    private var onChange: (@MainActor () -> Void)?
    private var generation: UUID?
    private var connectionRegistration: (any BluetoothNotificationRegistration)?
    private var disconnectObservations: [ObjectIdentifier: DisconnectObservation] = [:]

    convenience init() {
        self.init(backend: NativeBluetoothNotificationBackend())
    }

    init(backend: any BluetoothNotificationBackend) {
        self.backend = backend
    }

    /// A repeated start leaves the current registration and callback unchanged.
    func start(onChange: @escaping @MainActor () -> Void) {
        guard generation == nil else { return }
        let generation = UUID()
        self.generation = generation
        self.onChange = onChange
        connectionRegistration = backend.registerForConnections { [weak self] device in
            // Read no actor-isolated state on the native callback thread. Capture the
            // session here so callbacks queued before stop cannot enter a later session.
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.observeDisconnect(of: device, generation: generation)
                self.onChange?()
            }
        }
        // Register for connections first, then seed devices already connected at start.
        // A nil registration is nonfatal: the service's polling remains the fallback.
        for device in backend.pairedDevices() where device.isConnected {
            observeDisconnect(of: device, generation: generation)
        }
    }

    private func observeDisconnect(of device: any BluetoothNotificationDevice, generation: UUID) {
        let deviceID = device.id
        guard disconnectObservations[deviceID] == nil, device.isConnected else { return }
        let observationID = UUID()
        guard
            let registration = device.registerForDisconnect({ [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation,
                        self.disconnectObservations[deviceID]?.id == observationID
                    else { return }
                    // A second/late callback must not remove an observer for a reconnection.
                    let observation = self.disconnectObservations.removeValue(forKey: deviceID)
                    observation?.registration.unregister()
                    // Native callbacks can reach MainActor out of order. If reconnection
                    // was handled first, its old observer was still present then; rearm
                    // now rather than leaving the connected device unobserved.
                    if let device = observation?.device {
                        self.observeDisconnect(of: device, generation: generation)
                    }
                    self.onChange?()
                }
            })
        else { return }
        disconnectObservations[deviceID] = DisconnectObservation(
            id: observationID, device: device, registration: registration
        )
    }

    func stop() {
        generation = nil
        onChange = nil
        let connection = connectionRegistration
        connectionRegistration = nil
        let disconnections = disconnectObservations.values
        disconnectObservations.removeAll()
        connection?.unregister()
        disconnections.forEach { $0.registration.unregister() }
    }

    deinit {
        connectionRegistration?.unregister()
        disconnectObservations.values.forEach { $0.registration.unregister() }
    }
}

@MainActor
private final class NativeBluetoothNotificationBackend: BluetoothNotificationBackend {
    func pairedDevices() -> [any BluetoothNotificationDevice] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.map { NativeBluetoothNotificationDevice(device: $0) }
    }

    func registerForConnections(
        _ onConnect: @escaping @Sendable (any BluetoothNotificationDevice) -> Void
    ) -> (any BluetoothNotificationRegistration)? {
        let observer = NativeBluetoothNotificationObserver(onChange: onConnect)
        guard
            let notification = IOBluetoothDevice.register(
                forConnectNotifications: observer,
                selector: #selector(NativeBluetoothNotificationObserver.deviceChanged(_:device:))
            )
        else { return nil }
        return NativeBluetoothNotificationRegistration(
            notification: notification, observer: observer)
    }
}

/// The native reference is only retained on the callback thread. All calls into the
/// device are MainActor-isolated; the unchecked conformance does not expose it to callers.
private final class NativeBluetoothNotificationDevice: BluetoothNotificationDevice,
    @unchecked Sendable
{
    private let device: IOBluetoothDevice

    init(device: IOBluetoothDevice) { self.device = device }

    // IOBluetooth guarantees one device instance per remote address within a process.
    @MainActor var id: ObjectIdentifier { ObjectIdentifier(device) }
    @MainActor var isConnected: Bool { device.isConnected() }

    @MainActor func registerForDisconnect(
        _ onDisconnect: @escaping @Sendable () -> Void
    ) -> (any BluetoothNotificationRegistration)? {
        let observer = NativeBluetoothNotificationObserver { _ in onDisconnect() }
        guard
            let notification = device.register(
                forDisconnectNotification: observer,
                selector: #selector(NativeBluetoothNotificationObserver.deviceChanged(_:device:))
            )
        else { return nil }
        return NativeBluetoothNotificationRegistration(
            notification: notification, observer: observer)
    }
}

/// Deliberately not actor-isolated: Objective-C can deliver this selector on any thread.
/// Only an immutable Sendable callback is accessed here, never the monitor's state.
private final class NativeBluetoothNotificationObserver: NSObject {
    private let onChange: @Sendable (any BluetoothNotificationDevice) -> Void

    init(onChange: @escaping @Sendable (any BluetoothNotificationDevice) -> Void) {
        self.onChange = onChange
        super.init()
    }

    @objc func deviceChanged(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice)
    {
        onChange(NativeBluetoothNotificationDevice(device: device))
    }
}

/// Keep both the native token and its selector target alive until unregistration.
/// The lock also makes deinit cleanup safe if the last owner is released off actor.
private final class NativeBluetoothNotificationRegistration: BluetoothNotificationRegistration,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var registration: (IOBluetoothUserNotification, NativeBluetoothNotificationObserver)?

    init(notification: IOBluetoothUserNotification, observer: NativeBluetoothNotificationObserver) {
        registration = (notification, observer)
    }

    func unregister() {
        let current = lock.withLock {
            let current = registration
            registration = nil
            return current
        }
        if let (notification, observer) = current {
            withExtendedLifetime(observer) { notification.unregister() }
        }
    }

    deinit { unregister() }
}
