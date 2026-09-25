import AppKit
import ClockyCore
import Combine
import XCTest

@testable import Clocky

@MainActor
final class BatteryServiceTests: XCTestCase {
    /// Deliberately holds cancelled reads until released, like slow helpers winding down.
    private actor Provider: BatteryProviding {
        private struct Request: Hashable {
            let source: BatterySource
            let id: Int
        }

        private var counts: [BatterySource: Int] = [:]
        private var active: [BatterySource: Int] = [:]
        private var cancelledRequests: Set<Request> = []
        private var pending: [Request: CheckedContinuation<BatterySnapshot, Never>] = [:]
        private(set) var maximumActive = 0
        var reads: Int { BatterySource.allCases.map { count($0) }.min() ?? 0 }
        var cancelled: Set<Int> { Set(cancelledRequests.map(\.id)) }

        func count(_ source: BatterySource) -> Int { counts[source, default: 0] }
        func wasCancelled(_ source: BatterySource, _ id: Int) -> Bool {
            cancelledRequests.contains(Request(source: source, id: id))
        }
        func readMac() async -> Int? { await read(.mac).mac }
        func readIPhone() async -> Int? { await read(.iPhone).iPhone }
        func readAirPods() async -> AirPodsBattery? { await read(.airPods).airPods }

        private func read(_ source: BatterySource) async -> BatterySnapshot {
            counts[source, default: 0] += 1
            let request = Request(source: source, id: count(source))
            active[source, default: 0] += 1
            maximumActive = max(maximumActive, active[source, default: 0])
            defer { active[source, default: 0] -= 1 }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { pending[request] = $0 }
            } onCancel: {
                Task { await self.recordCancellation(request) }
            }
        }

        private func recordCancellation(_ request: Request) { cancelledRequests.insert(request) }
        func resolve(_ source: BatterySource, _ id: Int, with snapshot: BatterySnapshot) {
            pending.removeValue(forKey: Request(source: source, id: id))?.resume(
                returning: snapshot)
        }
        func resolve(_ id: Int, with snapshot: BatterySnapshot) {
            for source in BatterySource.allCases { resolve(source, id, with: snapshot) }
        }
        func finish() {
            for request in Array(pending.keys) {
                resolve(request.source, request.id, with: BatterySnapshot())
            }
        }
    }

    private final class BluetoothMonitor: BluetoothChangeMonitoring {
        private(set) var creations = 0
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var isMonitoring = false
        private var onChange: (@MainActor () -> Void)?

        func created() { creations += 1 }
        func start(onChange: @escaping @MainActor () -> Void) {
            guard !isMonitoring else { return }
            starts += 1
            isMonitoring = true
            self.onChange = onChange
        }
        func stop() {
            guard isMonitoring else { return }
            stops += 1
            isMonitoring = false
            onChange = nil
        }
        func emit() { onChange?() }
    }

    private struct Fixture {
        let settings: SettingsStore
        let provider: Provider
        let center: NotificationCenter
        let bluetooth: BluetoothMonitor
        let service: BatteryService
    }

    private func fixture(
        visible: Bool = true, enabled: Bool = true, interval: TimeInterval = 0.03,
        readingsVisible: Bool = true, bluetoothDebounce: TimeInterval = 0.03
    ) -> Fixture {
        let suite = "Clocky.BatteryServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.update {
            $0.isVisible = visible
            $0.showsMacBattery = readingsVisible
            $0.showsIPhoneBattery = readingsVisible
            $0.showsAirPodsBattery = readingsVisible
            $0.showsAirPodsCaseBattery = readingsVisible
        }
        let provider = Provider()
        let center = NotificationCenter()
        let bluetooth = BluetoothMonitor()
        let service = BatteryService(
            settings: settings, enabled: enabled, provider: provider,
            interval: interval, workspaceCenter: center, bluetoothDebounce: bluetoothDebounce,
            makeBluetoothMonitor: {
                bluetooth.created()
                return bluetooth
            }
        )
        addTeardownBlock { @MainActor in
            service.stop()
            // Let tasks that have not entered the provider yet suspend before releasing them.
            await Task.yield()
            await provider.finish()
            await service.stopAndWait()
            defaults.removePersistentDomain(forName: suite)
        }
        return Fixture(
            settings: settings, provider: provider, center: center, bluetooth: bluetooth,
            service: service)
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Condition not met within two seconds", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // Five normal polling intervals, without blocking the main run loop.
    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    func testDisabledSmokeModeNeverReadsEvenWithPreviewAndWake() async {
        let f = fixture(enabled: false)
        f.service.setPreviewVisible(true)
        f.settings.update { $0.isVisible = false }
        f.settings.update { $0.isVisible = true }
        f.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(f.bluetooth.creations, 0)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testHiddenClocksDoNotReadWithoutPreviewEvenAfterWake() async {
        let f = fixture(visible: false)
        f.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 0)
    }

    func testAllReadingsOffStopsPollingUntilAnyReadingIsEnabled() async {
        let f = fixture(readingsVisible: false)
        f.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle()
        let initialReads = await f.provider.reads
        XCTAssertEqual(initialReads, 0)
        f.settings.update { $0.showsAirPodsCaseBattery = true }
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(airPods: AirPodsBattery(caseLevel: 63)))
        await eventually { f.service.snapshot.airPods?.caseLevel == 63 }
        await eventually { await f.provider.reads == 2 }
        f.settings.update { $0.showsAirPodsCaseBattery = false }
        await eventually { await f.provider.cancelled.contains(2) }
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
        await f.provider.resolve(2, with: BatterySnapshot(mac: 72))
        await settle()
        let finalReads = await f.provider.reads
        XCTAssertEqual(finalReads, 2)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testSettingsDetailsRemainLiveWithAllOverlayReadingsOff() async {
        let f = fixture(interval: 60, readingsVisible: false)
        f.service.setPreviewVisible(true)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72, iPhone: 91))
        await eventually { f.service.snapshot.iPhone == 91 }
        f.service.setPreviewVisible(false)
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testHiddenPreviewPollsAndClosingItCancelsAndClears() async {
        let f = fixture(visible: false)
        f.service.setPreviewVisible(true)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await eventually { f.service.snapshot.mac == 72 }
        await eventually { await f.provider.reads == 2 }
        f.service.setPreviewVisible(false)
        await eventually { await f.provider.cancelled.contains(2) }
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
        await f.provider.resolve(2, with: BatterySnapshot(mac: 71))
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testVisibleClocksSampleImmediatelyButUnrelatedPreferencesDoNotResample() async {
        let f = fixture(interval: 60)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await eventually { f.service.snapshot.mac == 72 }
        f.settings.update {
            $0.showsSeconds.toggle()
            $0.fontSize = 42
            $0.timeFormat = .twentyFourHour
        }
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(f.service.snapshot.mac, 72)
    }

    func testRepeatedSlowReadsNeverOverlap() async {
        let f = fixture()
        for id in 1...3 {
            await eventually { await f.provider.reads == id }
            await settle()
            let reads = await f.provider.reads
            let maximumActive = await f.provider.maximumActive
            XCTAssertEqual(reads, id)
            XCTAssertEqual(maximumActive, 1)
            await f.provider.resolve(id, with: BatterySnapshot(mac: id))
            await eventually { f.service.snapshot.mac == id }
        }
    }

    func testHideCancelsInflightReadAndDiscardsItsLateResult() async {
        let f = fixture()
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await eventually { await f.provider.reads == 2 }
        f.settings.update { $0.isVisible = false }
        await eventually { await f.provider.cancelled.contains(2) }
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
        await f.provider.resolve(2, with: BatterySnapshot(mac: 71))
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testShowWaitsForCancelledReadThenRequestsFreshSample() async {
        let f = fixture(interval: 60)
        var published: [BatterySnapshot] = []
        let token = f.service.$snapshot.dropFirst().sink { published.append($0) }
        defer { token.cancel() }
        await eventually { await f.provider.reads == 1 }
        f.settings.update { $0.isVisible = false }
        await eventually { await f.provider.cancelled.contains(1) }
        f.settings.update { $0.isVisible = true }
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 1)
        await f.provider.resolve(1, with: BatterySnapshot(mac: 10))
        await eventually { await f.provider.reads == 2 }
        XCTAssertTrue(
            published.isEmpty, "Cancelled sample must never be published after showing again")
        await f.provider.resolve(2, with: BatterySnapshot(mac: 90))
        await eventually { f.service.snapshot.mac == 90 }
        XCTAssertEqual(published, [BatterySnapshot(mac: 90)])
        let maximumActive = await f.provider.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    func testSystemAndDisplaySleepClearReadingsAndWakeSamplesImmediately() async {
        for (sleep, wake) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
        ] {
            let f = fixture(interval: 60)
            await eventually { await f.provider.reads == 1 }
            await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
            await eventually { f.service.snapshot.mac == 72 }
            f.center.post(name: sleep, object: nil)
            await eventually { f.service.snapshot == BatterySnapshot() }
            await settle()
            let reads = await f.provider.reads
            XCTAssertEqual(reads, 1)
            f.center.post(name: wake, object: nil)
            await eventually { await f.provider.reads == 2 }
            await f.provider.resolve(2, with: BatterySnapshot(mac: 69))
            await eventually { f.service.snapshot.mac == 69 }
            f.service.stop()
        }
    }

    func testStopIsTerminalAndDiscardsInflightResult() async {
        let f = fixture()
        await eventually { await f.provider.reads == 1 }
        f.service.stop()
        f.service.stop()
        await eventually { await f.provider.cancelled.contains(1) }
        f.service.setPreviewVisible(true)
        f.settings.update { $0.isVisible = false }
        f.settings.update { $0.isVisible = true }
        f.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        f.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testStopAndWaitDoesNotFinishUntilCancelledReadCleansUp() async {
        let f = fixture()
        await eventually { await f.provider.reads == 1 }
        var finished = false
        let shutdown = Task {
            await f.service.stopAndWait()
            finished = true
        }
        await eventually { await f.provider.cancelled.contains(1) }
        await settle()
        XCTAssertFalse(finished)
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await shutdown.value
        XCTAssertTrue(finished)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testHidingSynchronouslyInvalidatesPublishedReadingsAndMonitoring() async {
        let f = fixture(interval: 60)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await eventually { f.service.snapshot.mac == 72 }
        f.settings.update { $0.isVisible = false }
        // No actor hop may separate the visibility change from invalidation.
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
        XCTAssertFalse(f.bluetooth.isMonitoring)
    }

    func testSleepNotificationSynchronouslyInvalidatesPublishedReadingsAndMonitoring() async {
        let f = fixture(interval: 60)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await eventually { f.service.snapshot.mac == 72 }
        f.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        // Notification delivery on the main queue must not defer cancellation.
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
        XCTAssertFalse(f.bluetooth.isMonitoring)
    }

    func testMacPublishesAndPollsWhileBothOtherSourcesAreStillReading() async {
        let f = fixture()
        await eventually { await f.provider.reads == 1 }
        for id in 1...3 {
            await eventually { await f.provider.count(.mac) == id }
            await f.provider.resolve(.mac, id, with: BatterySnapshot(mac: 70 + id))
            await eventually { f.service.snapshot.mac == 70 + id }
            XCTAssertNil(f.service.snapshot.iPhone)
            XCTAssertNil(f.service.snapshot.airPods)
        }
        let phoneReads = await f.provider.count(.iPhone)
        let airPodsReads = await f.provider.count(.airPods)
        let maximumActive = await f.provider.maximumActive
        XCTAssertEqual(phoneReads, 1)
        XCTAssertEqual(airPodsReads, 1)
        XCTAssertEqual(maximumActive, 1)
    }

    func testOutOfOrderResultsMergeAndFailuresClearOnlyTheirOwnSource() async {
        let f = fixture(interval: 60)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(.iPhone, 1, with: BatterySnapshot(iPhone: 91))
        await eventually { f.service.snapshot == BatterySnapshot(iPhone: 91) }
        await f.provider.resolve(
            .airPods, 1, with: BatterySnapshot(airPods: AirPodsBattery(caseLevel: 63)))
        await eventually { f.service.snapshot.airPods?.caseLevel == 63 }
        await f.provider.resolve(.mac, 1, with: BatterySnapshot(mac: 72))
        let first = BatterySnapshot(mac: 72, iPhone: 91, airPods: AirPodsBattery(caseLevel: 63))
        await eventually { f.service.snapshot == first }

        f.bluetooth.emit()
        await eventually { await f.provider.reads == 2 }
        await f.provider.resolve(.airPods, 2, with: BatterySnapshot())
        await eventually { f.service.snapshot == BatterySnapshot(mac: 72, iPhone: 91) }
        await f.provider.resolve(.mac, 2, with: BatterySnapshot(mac: 73))
        await eventually { f.service.snapshot == BatterySnapshot(mac: 73, iPhone: 91) }
        await f.provider.resolve(.iPhone, 2, with: BatterySnapshot())
        await eventually { f.service.snapshot == BatterySnapshot(mac: 73) }
    }

    func testBluetoothBurstIsDebouncedAndRefreshesEverySourceBeforePollDeadline() async {
        let f = fixture(interval: 60, bluetoothDebounce: 0.1)
        await eventually { await f.provider.reads == 1 }
        let first = BatterySnapshot(mac: 72, iPhone: 91, airPods: AirPodsBattery(main: 80))
        await f.provider.resolve(1, with: first)
        await eventually { f.service.snapshot == first }
        f.bluetooth.emit()
        try? await Task.sleep(for: .milliseconds(60))
        f.bluetooth.emit()
        try? await Task.sleep(for: .milliseconds(60))
        for source in BatterySource.allCases {
            let count = await f.provider.count(source)
            XCTAssertEqual(count, 1, "The quiet period restarts after each event")
        }
        await eventually { await f.provider.reads == 2 }
        await f.provider.resolve(2, with: BatterySnapshot(mac: 71, iPhone: 90))
        await eventually { f.service.snapshot == BatterySnapshot(mac: 71, iPhone: 90) }
        await settle()
        for source in BatterySource.allCases {
            let count = await f.provider.count(source)
            XCTAssertEqual(count, 2, "One burst schedules only one refresh")
        }
    }

    func testBluetoothInvalidatesInflightResultsAndWaitsForEachSourceToCleanUp() async {
        let f = fixture(interval: 60, bluetoothDebounce: 0.05)
        await eventually { await f.provider.reads == 1 }
        f.bluetooth.emit()
        for source in BatterySource.allCases {
            await eventually { await f.provider.wasCancelled(source, 1) }
        }
        await f.provider.resolve(.mac, 1, with: BatterySnapshot(mac: 10))
        await eventually { await f.provider.count(.mac) == 2 }
        XCTAssertEqual(
            f.service.snapshot, BatterySnapshot(), "Pre-event readings must be discarded")
        let phoneReads = await f.provider.count(.iPhone)
        let airPodsReads = await f.provider.count(.airPods)
        XCTAssertEqual(phoneReads, 1, "Cancelled helpers cannot overlap their replacements")
        XCTAssertEqual(airPodsReads, 1)
        await f.provider.resolve(.mac, 2, with: BatterySnapshot(mac: 90))
        await eventually { f.service.snapshot.mac == 90 }
        await f.provider.resolve(.iPhone, 1, with: BatterySnapshot(iPhone: 10))
        await eventually { await f.provider.count(.iPhone) == 2 }
        XCTAssertNil(f.service.snapshot.iPhone)
        await f.provider.resolve(
            .airPods, 1, with: BatterySnapshot(airPods: AirPodsBattery(main: 10)))
        await eventually { await f.provider.count(.airPods) == 2 }
        XCTAssertNil(f.service.snapshot.airPods)
        await f.provider.resolve(
            2, with: BatterySnapshot(iPhone: 80, airPods: AirPodsBattery(main: 70)))
        await eventually {
            f.service.snapshot
                == BatterySnapshot(mac: 90, iPhone: 80, airPods: AirPodsBattery(main: 70))
        }
        let maximumActive = await f.provider.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    func testBluetoothMonitoringIsLazyAndFollowsDemandAndSleep() async {
        let f = fixture(visible: false, interval: 60)
        XCTAssertEqual(f.bluetooth.creations, 0)
        f.service.setPreviewVisible(true)
        await eventually { await f.provider.reads == 1 }
        XCTAssertEqual(f.bluetooth.creations, 1)
        XCTAssertEqual(f.bluetooth.starts, 1)
        f.settings.update { $0.isVisible = true }
        await settle()
        XCTAssertEqual(f.bluetooth.starts, 1)
        f.service.setPreviewVisible(false)
        XCTAssertTrue(f.bluetooth.isMonitoring, "Visible overlays still need readings")
        f.center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await eventually { !f.bluetooth.isMonitoring }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 10))
        f.center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await eventually { await f.provider.reads == 2 }
        XCTAssertEqual(f.bluetooth.starts, 2)
        XCTAssertEqual(f.bluetooth.creations, 1)
        f.settings.update { $0.isVisible = false }
        await eventually { !f.bluetooth.isMonitoring }
        XCTAssertEqual(f.bluetooth.stops, 2)
    }

    func testHideCancelsPendingBluetoothDebounceAndShowingStartsFreshReads() async {
        let f = fixture(interval: 60, bluetoothDebounce: 0.1)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await eventually { f.service.snapshot.mac == 72 }
        f.bluetooth.emit()
        f.settings.update { $0.isVisible = false }
        await eventually { !f.bluetooth.isMonitoring }
        await settle()
        let reads = await f.provider.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
        f.settings.update { $0.isVisible = true }
        await eventually { await f.provider.reads == 2 }
        await f.provider.resolve(2, with: BatterySnapshot(mac: 90))
        await eventually { f.service.snapshot.mac == 90 }
        await settle()
        let finalReads = await f.provider.reads
        XCTAssertEqual(finalReads, 2)
    }

    func testStopCancelsPendingBluetoothDebounceAndUnregistersMonitor() async {
        let f = fixture(interval: 60, bluetoothDebounce: 0.1)
        await eventually { await f.provider.reads == 1 }
        await f.provider.resolve(1, with: BatterySnapshot(mac: 72))
        await eventually { f.service.snapshot.mac == 72 }
        f.bluetooth.emit()
        await f.service.stopAndWait()
        f.bluetooth.emit()
        await settle()
        XCTAssertFalse(f.bluetooth.isMonitoring)
        for source in BatterySource.allCases {
            let count = await f.provider.count(source)
            XCTAssertEqual(count, 1)
        }
    }

    func testShutdownWaitsForAllIndependentSourcesNotJustTheFirst() async {
        let f = fixture(interval: 60)
        await eventually { await f.provider.reads == 1 }
        var finished = false
        let shutdown = Task {
            await f.service.stopAndWait()
            finished = true
        }
        for source in BatterySource.allCases {
            await eventually { await f.provider.wasCancelled(source, 1) }
        }
        await f.provider.resolve(.mac, 1, with: BatterySnapshot(mac: 72))
        await settle()
        XCTAssertFalse(finished)
        await f.provider.resolve(
            .airPods, 1, with: BatterySnapshot(airPods: AirPodsBattery(main: 80)))
        await settle()
        XCTAssertFalse(finished)
        await f.provider.resolve(.iPhone, 1, with: BatterySnapshot(iPhone: 91))
        await shutdown.value
        XCTAssertTrue(finished)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }

    func testUnchangedSnapshotsAreNotRepublishedAndFailureClearsStaleValues() async {
        let f = fixture()
        let sample = BatterySnapshot(mac: 72, iPhone: 51, airPods: AirPodsBattery(main: 80))
        var published: [BatterySnapshot] = []
        let token = f.service.$snapshot.dropFirst().sink { published.append($0) }
        defer { token.cancel() }
        for id in 1...2 {
            await eventually { await f.provider.reads == id }
            await f.provider.resolve(id, with: sample)
        }
        // Starting the third read proves the second identical result was processed.
        await eventually { await f.provider.reads == 3 }
        XCTAssertEqual(published.last, sample)
        XCTAssertEqual(
            published.count, 3,
            "Each source publishes its first result, not its identical second one")
        // Failed/unavailable reads clear only their own source.
        await f.provider.resolve(3, with: BatterySnapshot())
        await eventually { f.service.snapshot == BatterySnapshot() }
        XCTAssertEqual(published.count, 6)
        XCTAssertEqual(published.last, BatterySnapshot())
    }
}
