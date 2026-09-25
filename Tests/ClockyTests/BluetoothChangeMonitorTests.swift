import Foundation
import XCTest

@testable import Clocky

@MainActor
final class BluetoothChangeMonitorTests: XCTestCase {
    /// These fixtures never construct an IOBluetooth object or call the native backend.
    private final class Registration: BluetoothNotificationRegistration, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var unregisterCalls: Int { lock.withLock { calls } }
        func unregister() { lock.withLock { calls += 1 } }
    }

    @MainActor
    private final class Device: BluetoothNotificationDevice {
        var id: ObjectIdentifier { ObjectIdentifier(self) }
        var isConnected: Bool
        var failsRegistration = false
        var disconnectsDuringRegistration = false
        private(set) var callbacks: [@Sendable () -> Void] = []
        private(set) var registrations: [Registration] = []

        init(connected: Bool = true) { isConnected = connected }

        func registerForDisconnect(
            _ onDisconnect: @escaping @Sendable () -> Void
        ) -> (any BluetoothNotificationRegistration)? {
            callbacks.append(onDisconnect)
            guard !failsRegistration else { return nil }
            let registration = Registration()
            registrations.append(registration)
            if disconnectsDuringRegistration {
                isConnected = false
                onDisconnect()
            }
            return registration
        }
    }

    @MainActor
    private final class Backend: BluetoothNotificationBackend {
        var devices: [Device] = []
        var failsRegistration = false
        var connectsDuringRegistration: Device?
        private(set) var calls: [String] = []
        private(set) var callbacks: [@Sendable (any BluetoothNotificationDevice) -> Void] = []
        private(set) var registrations: [Registration] = []

        func pairedDevices() -> [any BluetoothNotificationDevice] {
            calls.append("paired")
            return devices
        }

        func registerForConnections(
            _ onConnect: @escaping @Sendable (any BluetoothNotificationDevice) -> Void
        ) -> (any BluetoothNotificationRegistration)? {
            calls.append("connect")
            callbacks.append(onConnect)
            guard !failsRegistration else { return nil }
            let registration = Registration()
            registrations.append(registration)
            if let device = connectsDuringRegistration { onConnect(device) }
            return registration
        }
    }

    private final class WeakReference<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value?) { self.value = value }
    }

    @MainActor
    private final class CallbackOwner {
        var changes = 0
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Condition not met within two seconds", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    func testInitializationAndStopBeforeStartDoNotTouchBackend() {
        let backend = Backend()
        let monitor = BluetoothChangeMonitor(backend: backend)
        monitor.stop()
        monitor.stop()
        XCTAssertTrue(backend.calls.isEmpty)
        monitor.start {}
        XCTAssertEqual(backend.calls, ["connect", "paired"])
        monitor.stop()
    }

    func testStartSeedsOnlyConnectedPairedDevicesAndDeduplicatesObservers() {
        let backend = Backend()
        let connected = Device()
        let disconnected = Device(connected: false)
        backend.devices = [connected, disconnected, connected]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        XCTAssertEqual(backend.calls, ["connect", "paired"])
        XCTAssertEqual(connected.registrations.count, 1)
        XCTAssertTrue(disconnected.callbacks.isEmpty)
        XCTAssertEqual(changes, 0, "Seeding must not manufacture a connection event")
        monitor.stop()
        XCTAssertEqual(connected.registrations[0].unregisterCalls, 1)
    }

    func testRepeatedStartAndStopAreIdempotentAndKeepOriginalCallback() async {
        let backend = Backend()
        let first = Device()
        let second = Device()
        backend.devices = [first, second]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        var replacementChanges = 0
        monitor.start { changes += 1 }
        monitor.start { replacementChanges += 1 }
        XCTAssertEqual(backend.registrations.count, 1)
        XCTAssertEqual(backend.calls, ["connect", "paired"])
        backend.callbacks[0](first)
        await eventually { changes == 1 }
        XCTAssertEqual(replacementChanges, 0)
        XCTAssertEqual(first.registrations.count, 1)
        monitor.stop()
        monitor.stop()
        XCTAssertEqual(backend.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(first.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(second.registrations[0].unregisterCalls, 1)
    }

    func testBackgroundConnectionsAndDisconnectionsAreDeliveredOnMainActor() async {
        let backend = Backend()
        let device = Device()
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start {
            XCTAssertTrue(Thread.isMainThread)
            changes += 1
        }
        let connect = backend.callbacks[0]
        await Task.detached { connect(device) }.value
        await eventually { changes == 1 }
        XCTAssertEqual(
            device.registrations.count, 1, "New, not just paired, devices need observers")
        let disconnect = device.callbacks[0]
        device.isConnected = false
        await Task.detached { disconnect() }.value
        await eventually { changes == 2 }
        XCTAssertEqual(device.registrations[0].unregisterCalls, 1)
        monitor.stop()
        XCTAssertEqual(device.registrations[0].unregisterCalls, 1)
    }

    func testDisconnectRemovesOnlyItsObserverAndReconnectRearmsIt() async {
        let backend = Backend()
        let first = Device()
        let second = Device()
        backend.devices = [first, second]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        let oldDisconnect = first.callbacks[0]
        first.isConnected = false
        oldDisconnect()
        await eventually { changes == 1 }
        XCTAssertEqual(first.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(second.registrations[0].unregisterCalls, 0)
        first.isConnected = true
        backend.callbacks[0](first)
        await eventually { changes == 2 }
        XCTAssertEqual(first.registrations.count, 2)
        // This callback belongs to the previous connection, but the session is the same.
        oldDisconnect()
        await settle()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(first.registrations[1].unregisterCalls, 0)
        first.isConnected = false
        first.callbacks[1]()
        await eventually { changes == 3 }
        XCTAssertEqual(first.registrations[1].unregisterCalls, 1)
        monitor.stop()
        XCTAssertEqual(second.registrations[0].unregisterCalls, 1)
    }

    func testReconnectionDeliveredBeforeOldDisconnectStillObservesNextDisconnect() async {
        let backend = Backend()
        let device = Device()
        backend.devices = [device]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        let oldDisconnect = device.callbacks[0]
        // The device has disconnected and reconnected, but its connection event
        // reaches the actor before the old disconnect event.
        backend.callbacks[0](device)
        await eventually { changes == 1 }
        XCTAssertEqual(device.registrations.count, 1)
        oldDisconnect()
        await eventually { changes == 2 }
        XCTAssertEqual(device.registrations.count, 2)
        XCTAssertEqual(device.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(device.registrations[1].unregisterCalls, 0)
        device.isConnected = false
        device.callbacks[1]()
        await eventually { changes == 3 }
        XCTAssertEqual(device.registrations[1].unregisterCalls, 1)
        monitor.stop()
    }

    func testStoppedMonitorIgnoresAlreadyQueuedAndLaterCallbacks() async {
        let backend = Backend()
        let paired = Device()
        let unpaired = Device()
        backend.devices = [paired]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        backend.callbacks[0](unpaired)
        paired.callbacks[0]()
        // Both callbacks have queued a main-actor hop but cannot have run yet.
        monitor.stop()
        backend.callbacks[0](unpaired)
        paired.callbacks[0]()
        await settle()
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(unpaired.callbacks.isEmpty)
        XCTAssertEqual(paired.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(backend.registrations[0].unregisterCalls, 1)
    }

    func testRestartIgnoresPriorGenerationAndReseedsConnectedDevices() async {
        let backend = Backend()
        let paired = Device()
        let staleDevice = Device()
        backend.devices = [paired]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var oldChanges = 0
        var newChanges = 0
        monitor.start { oldChanges += 1 }
        let oldConnect = backend.callbacks[0]
        let oldDisconnect = paired.callbacks[0]
        oldConnect(staleDevice)
        oldDisconnect()
        monitor.stop()
        monitor.start { newChanges += 1 }
        oldConnect(staleDevice)
        oldDisconnect()
        await settle()
        XCTAssertEqual(oldChanges, 0)
        XCTAssertEqual(newChanges, 0)
        XCTAssertTrue(staleDevice.callbacks.isEmpty)
        XCTAssertEqual(backend.calls, ["connect", "paired", "connect", "paired"])
        XCTAssertEqual(paired.registrations.count, 2)
        XCTAssertEqual(paired.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(paired.registrations[1].unregisterCalls, 0)
        paired.isConnected = false
        paired.callbacks[1]()
        await eventually { newChanges == 1 }
        paired.isConnected = true
        backend.callbacks[1](paired)
        await eventually { newChanges == 2 }
        XCTAssertEqual(paired.registrations.count, 3)
        monitor.stop()
        XCTAssertTrue(backend.registrations.allSatisfy { $0.unregisterCalls == 1 })
        XCTAssertTrue(paired.registrations.allSatisfy { $0.unregisterCalls == 1 })
    }

    func testConnectionRegistrationFailureStillSeedsDisconnectsAndCanRetryAfterStop() async {
        let backend = Backend()
        let paired = Device()
        backend.devices = [paired]
        backend.failsRegistration = true
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        monitor.start { XCTFail("Repeated start must not replace the callback") }
        XCTAssertEqual(backend.calls, ["connect", "paired"])
        XCTAssertTrue(backend.registrations.isEmpty)
        XCTAssertEqual(paired.registrations.count, 1)
        paired.isConnected = false
        paired.callbacks[0]()
        await eventually { changes == 1 }
        monitor.stop()
        backend.failsRegistration = false
        paired.isConnected = true
        monitor.start { changes += 1 }
        XCTAssertEqual(backend.registrations.count, 1)
        XCTAssertEqual(paired.registrations.count, 2)
        backend.callbacks[1](paired)
        await eventually { changes == 2 }
        monitor.stop()
        XCTAssertTrue(paired.registrations.allSatisfy { $0.unregisterCalls == 1 })
    }

    func testDisconnectRegistrationFailureDoesNotBlockOtherDevicesOrConnectionEvents() async {
        let backend = Backend()
        let unavailable = Device()
        let available = Device()
        unavailable.failsRegistration = true
        backend.devices = [unavailable, available]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        XCTAssertTrue(unavailable.registrations.isEmpty)
        XCTAssertEqual(available.registrations.count, 1)
        backend.callbacks[0](unavailable)
        await eventually { changes == 1 }
        XCTAssertEqual(unavailable.callbacks.count, 2)
        XCTAssertTrue(unavailable.registrations.isEmpty)
        unavailable.failsRegistration = false
        backend.callbacks[0](unavailable)
        await eventually { changes == 2 }
        XCTAssertEqual(unavailable.registrations.count, 1)
        // Even a spurious callback from a failed registration cannot cancel the new one.
        unavailable.callbacks[0]()
        unavailable.callbacks[1]()
        await settle()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(unavailable.registrations[0].unregisterCalls, 0)
        available.isConnected = false
        available.callbacks[0]()
        await eventually { changes == 3 }
        monitor.stop()
        XCTAssertEqual(available.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(unavailable.registrations[0].unregisterCalls, 1)
    }

    func testConnectionDuringSeedingDoesNotDuplicateDisconnectRegistration() async {
        let backend = Backend()
        let device = Device()
        backend.devices = [device]
        backend.connectsDuringRegistration = device
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        XCTAssertEqual(changes, 0, "Backend callbacks must always hop to MainActor")
        await eventually { changes == 1 }
        XCTAssertEqual(device.registrations.count, 1)
        monitor.stop()
    }

    func testSynchronousDisconnectCallbackWaitsUntilRegistrationIsStored() async {
        let backend = Backend()
        let device = Device()
        device.disconnectsDuringRegistration = true
        backend.devices = [device]
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        XCTAssertEqual(changes, 0)
        await eventually { changes == 1 }
        XCTAssertEqual(device.registrations[0].unregisterCalls, 1)
        monitor.stop()
        XCTAssertEqual(device.registrations[0].unregisterCalls, 1)
    }

    func testDeviceAlreadyDisconnectedBeforeConnectionDeliveryStillReportsChange() async {
        let backend = Backend()
        let device = Device(connected: false)
        let monitor = BluetoothChangeMonitor(backend: backend)
        var changes = 0
        monitor.start { changes += 1 }
        backend.callbacks[0](device)
        await eventually { changes == 1 }
        XCTAssertTrue(device.callbacks.isEmpty)
        monitor.stop()
    }

    func testStopReleasesChangeCallback() {
        let backend = Backend()
        let monitor = BluetoothChangeMonitor(backend: backend)
        var owner: CallbackOwner? = CallbackOwner()
        let weakOwner = WeakReference(owner)
        monitor.start { [owner] in owner?.changes += 1 }
        owner = nil
        XCTAssertNotNil(weakOwner.value)
        monitor.stop()
        XCTAssertNil(weakOwner.value)
    }

    func testDeinitUnregistersAndRetainedOrQueuedBackendCallbacksDoNotKeepMonitorAlive() async {
        let backend = Backend()
        let device = Device()
        backend.devices = [device]
        var monitor: BluetoothChangeMonitor? = BluetoothChangeMonitor(backend: backend)
        let weakMonitor = WeakReference(monitor)
        var changes = 0
        monitor?.start { changes += 1 }
        backend.callbacks[0](device)
        device.callbacks[0]()
        monitor = nil
        XCTAssertNil(weakMonitor.value)
        XCTAssertEqual(backend.registrations[0].unregisterCalls, 1)
        XCTAssertEqual(device.registrations[0].unregisterCalls, 1)
        // The fixture deliberately retains even unregistered callbacks.
        backend.callbacks[0](device)
        device.callbacks[0]()
        await settle()
        XCTAssertEqual(changes, 0)
    }
}
