import AppKit
import ClockyCore
import Combine

/// One demand-driven service shared by all overlays and the settings preview.
/// Sources publish and poll independently; reads for the same source never overlap.
@MainActor
final class BatteryService: ObservableObject {
    @Published private(set) var snapshot = BatterySnapshot()
    let ble: BLEBatteryController

    private struct Configuration: Equatable {
        let overlayNeedsBattery: Bool
        let ble: BLEPreferences
    }

    private let provider: any BatteryProviding
    private let interval: TimeInterval
    private let bluetoothDebounce: TimeInterval
    private let makeBluetoothMonitor: @MainActor () -> any BluetoothChangeMonitoring
    private let enabled: Bool
    private var overlayNeedsBattery: Bool
    private var blePreferences: BLEPreferences
    private var previewVisible = false
    private var displaysAsleep = false
    private var stopped = false
    private var timers: [BatterySource: Timer] = [:]
    private var readTasks: [BatterySource: Task<Void, Never>] = [:]
    private var bluetoothMonitor: (any BluetoothChangeMonitoring)?
    private var bluetoothTimer: Timer?
    private var subscription: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(
        settings: SettingsStore, enabled: Bool = true,
        provider: any BatteryProviding = SystemBatteryProvider(),
        interval: TimeInterval = 30,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        bluetoothDebounce: TimeInterval = 1,
        ble: BLEBatteryController? = nil,
        makeBluetoothMonitor: @escaping @MainActor () -> any BluetoothChangeMonitoring = {
            BluetoothChangeMonitor()
        }
    ) {
        self.provider = provider
        self.interval = interval.isFinite ? max(0.01, interval) : 30
        self.bluetoothDebounce = bluetoothDebounce.isFinite ? max(0.01, bluetoothDebounce) : 1
        self.makeBluetoothMonitor = makeBluetoothMonitor
        self.enabled = enabled
        self.ble = ble ?? BLEBatteryController(available: enabled)
        blePreferences = settings.preferences.ble
        self.ble.configure(blePreferences)
        overlayNeedsBattery = settings.preferences.isVisible && settings.preferences.showsAnyBattery
        // Smoke tests must not launch helpers, initialize Bluetooth, or access real device data.
        guard enabled else { return }
        subscription = settings.$preferences.map {
            Configuration(overlayNeedsBattery: $0.isVisible && $0.showsAnyBattery, ble: $0.ble)
        }
        .removeDuplicates().dropFirst()
        // SettingsStore publishes on MainActor. Invalidate synchronously so a
        // queued read cannot publish between hiding and a deferred cancellation.
        .sink { [weak self] configuration in
            guard let self else { return }
            self.overlayNeedsBattery = configuration.overlayNeedsBattery
            if self.blePreferences != configuration.ble {
                self.blePreferences = configuration.ble
                self.cancelSampling()
                self.ble.configure(configuration.ble)
                // A disabled/forgotten selection cannot leave its BLE result visible.
                let next = BatterySnapshot(
                    mac: self.snapshot.mac,
                    iPhone: self.snapshot.iPhoneUsesBLE ? nil : self.snapshot.iPhone,
                    airPods: self.snapshot.airPods?.isApproximate == true
                        ? nil : self.snapshot.airPods
                )
                if self.snapshot != next { self.snapshot = next }
            }
            self.refresh()
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(name, center: workspaceCenter, asleep: true)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(name, center: workspaceCenter, asleep: false)
        }
        refresh()
    }

    private var shouldPoll: Bool {
        // Settings still shows full details even when all overlay readings are off.
        enabled && !stopped && !displaysAsleep && (overlayNeedsBattery || previewVisible)
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, asleep: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // The observer explicitly runs on the main queue. Do not defer sleep
            // invalidation behind already queued read completions.
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.displaysAsleep = asleep
                self.refresh()
            }
        }
        observers.append((center, token))
    }

    private func refresh() {
        guard shouldPoll else {
            cancelSampling()
            ble.setActive(false)
            bluetoothMonitor?.stop()
            // Do not redisplay pre-sleep/hidden readings on the next show.
            if snapshot != BatterySnapshot() { snapshot = BatterySnapshot() }
            return
        }
        ble.setActive(true)
        if bluetoothMonitor == nil { bluetoothMonitor = makeBluetoothMonitor() }
        bluetoothMonitor?.start { [weak self] in self?.bluetoothChanged() }
        guard bluetoothTimer == nil else { return }
        for source in BatterySource.allCases { requestRead(source) }
    }

    private func requestRead(_ source: BatterySource) {
        timers.removeValue(forKey: source)?.invalidate()
        guard shouldPoll, bluetoothTimer == nil else { return }
        // Showing again while a cancelled helper exits must not overlap it;
        // its completion will start the replacement once cleanup has finished.
        guard readTasks[source] == nil else { return }
        readTasks[source] = Task { [weak self, provider, ble] in
            let primary = await provider.read(source)
            let reading = Task.isCancelled ? primary : await ble.fallback(for: primary)
            guard let self else { return }
            self.readTasks[source] = nil
            guard self.shouldPoll, self.bluetoothTimer == nil else { return }
            // Sleep/visibility changes and Bluetooth events invalidate in-flight results.
            guard !Task.isCancelled else {
                self.requestRead(source)
                return
            }
            let next = reading.updating(self.snapshot)
            if self.snapshot != next { self.snapshot = next }
            self.scheduleNextSample(source)
        }
    }

    private func scheduleNextSample(_ source: BatterySource) {
        guard shouldPoll else { return }
        let nextTimer = Timer(timeInterval: interval, repeats: false) { [weak self] timer in
            Task { @MainActor [weak self] in
                // Invalidating a timer does not cancel an already queued actor hop.
                guard let self, self.timers[source] === timer else { return }
                self.requestRead(source)
            }
        }
        nextTimer.tolerance = min(1, interval * 0.1)
        timers[source] = nextTimer
        RunLoop.main.add(nextTimer, forMode: .common)
    }

    private func bluetoothChanged() {
        // Ignore our own GATT connect/disconnect events, including a short cleanup
        // grace period. Normal polling still runs for every source during this window.
        guard shouldPoll, !ble.suppressesConnectionRefreshes else { return }
        // Discard reads begun before the topology changed. New reads wait for both
        // the quiet period and cancellation/reaping of each source's old helper.
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        readTasks.values.forEach { $0.cancel() }
        bluetoothTimer?.invalidate()
        let debounceTimer = Timer(timeInterval: bluetoothDebounce, repeats: false) {
            [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, self.bluetoothTimer === timer else { return }
                self.bluetoothTimer = nil
                guard self.shouldPoll else { return }
                // User-selected policy: every Bluetooth change refreshes all sources.
                for source in BatterySource.allCases { self.requestRead(source) }
            }
        }
        bluetoothTimer = debounceTimer
        RunLoop.main.add(debounceTimer, forMode: .common)
    }

    private func cancelSampling() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
        bluetoothTimer?.invalidate()
        bluetoothTimer = nil
        readTasks.values.forEach { $0.cancel() }
    }

    func setPreviewVisible(_ visible: Bool) {
        guard !stopped, previewVisible != visible else { return }
        previewVisible = visible
        refresh()
    }

    /// Application termination waits for every source's subprocess cancellation and reaping.
    func stopAndWait() async {
        stop()
        let tasks = Array(readTasks.values)
        for task in tasks { await task.value }
        await ble.stopAndWait()
    }

    func stop() {
        stopped = true
        cancelSampling()
        ble.stop()
        bluetoothMonitor?.stop()
        subscription?.cancel()
        subscription = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }
}
