import ClockyCore
import Combine
import Foundation

struct BLEDeviceCandidate: Identifiable, Equatable {
    enum Kind { case airPods, iPhone }
    let id: UUID
    let name: String
    let kind: Kind
}

/// Opt-in and demand boundary for BLE. No native manager exists until an enabled
/// discovery or selected-device fallback actually needs it. Results are never cached.
@MainActor
final class BLEBatteryController: ObservableObject {
    @Published private(set) var candidates: [BLEDeviceCandidate] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var status = "Bluetooth fallback is off"
    let available: Bool

    private let makeAccess: @MainActor () -> any BLEBatteryAccessing
    private let scanTimeout: TimeInterval
    private let phoneTimeout: TimeInterval
    private let cleanupGrace: TimeInterval
    private let uptime: @MainActor () -> TimeInterval
    private var access: (any BLEBatteryAccessing)?
    private var preferences = BLEPreferences()
    private var active = false
    private var stopped = false
    private var generation = UUID()
    private var discoveryTask: Task<Void, Never>?
    private var phoneReadInProgress = false
    private var suppressEventsUntil: TimeInterval = 0

    init(
        available: Bool = true, scanTimeout: TimeInterval = 5,
        phoneTimeout: TimeInterval = 10, cleanupGrace: TimeInterval = 3,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeAccess: @escaping @MainActor () -> any BLEBatteryAccessing = {
            CoreBluetoothBatteryAccess()
        }
    ) {
        self.available = available
        self.scanTimeout = scanTimeout.isFinite ? max(0.01, min(scanTimeout, 5)) : 5
        self.phoneTimeout = phoneTimeout.isFinite ? max(0.01, min(phoneTimeout, 10)) : 10
        self.cleanupGrace = cleanupGrace.isFinite ? max(0, cleanupGrace) : 3
        self.uptime = uptime
        self.makeAccess = makeAccess
    }

    private var allowed: Bool { available && !stopped && active && preferences.enabled }

    /// Our own GATT connect/disconnect can generate classic Bluetooth notifications.
    /// The user-approved quiet window prevents a refresh -> connection -> refresh loop.
    var suppressesConnectionRefreshes: Bool {
        phoneReadInProgress || uptime() < suppressEventsUntil
    }

    func configure(_ preferences: BLEPreferences) {
        guard self.preferences != preferences else { return }
        self.preferences = preferences
        invalidate()
        if !preferences.enabled { candidates = [] }
        updateIdleStatus()
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if !active {
            invalidate()
            candidates = []
        }
        updateIdleStatus()
    }

    private func updateIdleStatus() {
        if !available || stopped {
            status = "Bluetooth fallback is unavailable"
        } else if !preferences.enabled {
            status = "Bluetooth fallback is off"
        } else if !active {
            status = "Bluetooth fallback paused"
        } else {
            status = "Select devices; existing readers stay primary"
        }
    }

    private func invalidate() {
        generation = UUID()
        cancelDiscovery()
        access?.stop()
    }

    private func backend() -> any BLEBatteryAccessing {
        if let access { return access }
        let created = makeAccess()
        access = created
        return created
    }

    func discover() {
        guard allowed, discoveryTask == nil else { return }
        let generation = generation
        let access = backend()
        candidates = []
        isDiscovering = true
        status = "Scanning nearby devices for five seconds"
        discoveryTask = Task { [weak self, scanTimeout] in
            let observations = await access.scan(timeout: scanTimeout)
            guard let self else { return }
            self.discoveryTask = nil
            self.isDiscovering = false
            guard !Task.isCancelled, self.allowed, self.generation == generation else { return }
            self.candidates = Self.deviceCandidates(from: observations)
            self.status =
                self.candidates.isEmpty
                ? "No supported candidates. \(access.status)"
                : "Choose your devices by name and identifier"
        }
    }

    func cancelDiscovery() {
        discoveryTask?.cancel()
        // Retain the task until its cancellation finishes, so shutdown can await it.
        // Cancelling one scan must not stop a concurrent AirPods fallback scan.
        if isDiscovering { status = "Scan stopped" }
        isDiscovering = false
    }

    static func deviceCandidates(from observations: [BLEAdvertisement]) -> [BLEDeviceCandidate] {
        var latest: [UUID: BLEAdvertisement] = [:]
        for observation in observations { latest[observation.identifier] = observation }
        return latest.values.compactMap { observation -> BLEDeviceCandidate? in
            let kind: BLEDeviceCandidate.Kind
            if BLEAdvertisementParser.isAirPods(observation.manufacturerData) {
                kind = .airPods
            } else if BLEAdvertisementParser.isPhoneCandidate(observation.manufacturerData) {
                kind = .iPhone
            } else {
                return nil
            }
            let selection = BLEDeviceSelection(
                id: observation.identifier, name: observation.name ?? "")
            return BLEDeviceCandidate(
                id: selection.id,
                name: selection.name.isEmpty
                    ? (kind == .airPods ? "Unnamed AirPods" : "Apple device (verify iPhone)")
                    : selection.name,
                kind: kind
            )
        }.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Whole-device fallback only: never join CoreBluetooth UUIDs to classic MACs
    /// or iPhone USB IDs by name, and never mix components from different sources.
    func fallback(for primary: BatteryReading) async -> BatteryReading {
        guard !Task.isCancelled else { return primary }
        switch primary {
        case .airPods(nil): return .airPods(await readAirPods())
        case .iPhone(nil): return .iPhoneBLE(await readIPhone())
        default: return primary
        }
    }

    func readAirPods() async -> AirPodsBattery? {
        guard !Task.isCancelled, allowed, let selected = preferences.airPods else { return nil }
        let generation = generation
        let access = backend()
        let observations = await access.scan(timeout: scanTimeout)
        guard !Task.isCancelled, allowed, self.generation == generation,
            preferences.airPods?.id == selected.id
        else { return nil }
        guard let observation = observations.last(where: { $0.identifier == selected.id }),
            let battery = BLEAdvertisementParser.airPods(from: observation.manufacturerData)
        else {
            status = "Selected AirPods reading unavailable. \(access.status)"
            return nil
        }
        status = "AirPods Bluetooth reading is approximate (~)"
        return battery
    }

    func readIPhone() async -> Int? {
        guard !Task.isCancelled, allowed, !phoneReadInProgress,
            let selected = preferences.iPhone
        else { return nil }
        let generation = generation
        let access = backend()
        phoneReadInProgress = true
        defer {
            phoneReadInProgress = false
            // Native teardown is bounded to two seconds. Allow queued notification
            // delivery as well; do not turn this cooldown into a battery cache.
            suppressEventsUntil = uptime() + cleanupGrace
        }
        status = "Reading selected iPhone over Bluetooth"
        let level = await access.readIPhone(identifier: selected.id, timeout: phoneTimeout)
        guard !Task.isCancelled, allowed, self.generation == generation,
            preferences.iPhone?.id == selected.id
        else { return nil }
        status = access.status
        guard let level, (0...100).contains(level) else { return nil }
        return level
    }

    func stop() {
        stopped = true
        active = false
        invalidate()
        candidates = []
        updateIdleStatus()
    }

    func stopAndWait() async {
        stop()
        await discoveryTask?.value
    }
}
