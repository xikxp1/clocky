import ClockyCore
import Foundation
import XCTest

@testable import Clocky

@MainActor
final class BLEBatteryControllerTests: XCTestCase {
    private final class Access: BLEBatteryAccessing {
        var status = "Fixture result"
        var scans: [TimeInterval] = []
        var phones: [(UUID, TimeInterval)] = []
        var stops = 0
        var cancelledScans: Set<Int> = []
        private var scanContinuations: [Int: CheckedContinuation<[BLEAdvertisement], Never>] = [:]
        private var phoneContinuations: [Int: CheckedContinuation<Int?, Never>] = [:]

        func scan(timeout: TimeInterval) async -> [BLEAdvertisement] {
            let index = scans.count
            scans.append(timeout)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { scanContinuations[index] = $0 }
            } onCancel: {
                Task { @MainActor in self.cancelledScans.insert(index) }
            }
        }
        func readIPhone(identifier: UUID, timeout: TimeInterval) async -> Int? {
            let index = phones.count
            phones.append((identifier, timeout))
            return await withCheckedContinuation { phoneContinuations[index] = $0 }
        }
        // Hold stale results deliberately, even after stop, to test the generation boundary.
        func stop() { stops += 1 }
        func resolveScan(_ index: Int, _ values: [BLEAdvertisement]) {
            scanContinuations.removeValue(forKey: index)?.resume(returning: values)
        }
        func resolvePhone(_ index: Int, _ level: Int?) {
            phoneContinuations.removeValue(forKey: index)?.resume(returning: level)
        }
        func finish() {
            for index in Array(scanContinuations.keys) { resolveScan(index, []) }
            for index in Array(phoneContinuations.keys) { resolvePhone(index, nil) }
        }
    }

    @MainActor
    private final class Environment {
        let access = Access()
        var creations = 0
        var uptime: TimeInterval = 100
    }

    private struct Fixture {
        let environment: Environment
        let controller: BLEBatteryController
        var access: Access { environment.access }
    }

    private func fixture(
        available: Bool = true, enabled: Bool = true, active: Bool = true,
        scanTimeout: TimeInterval = 5, phoneTimeout: TimeInterval = 10
    ) -> Fixture {
        let environment = Environment()
        let controller = BLEBatteryController(
            available: available, scanTimeout: scanTimeout, phoneTimeout: phoneTimeout,
            uptime: { environment.uptime },
            makeAccess: {
                environment.creations += 1
                return environment.access
            }
        )
        controller.configure(BLEPreferences(enabled: enabled))
        controller.setActive(active)
        addTeardownBlock { @MainActor in
            controller.stop()
            await Task.yield()
            environment.access.finish()
            await controller.stopAndWait()
        }
        return Fixture(environment: environment, controller: controller)
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Condition not met", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func selection(_ name: String = "My device") -> BLEDeviceSelection {
        BLEDeviceSelection(id: UUID(), name: name)
    }

    private func airPods(_ id: UUID, name: String = "AirPods", levels: UInt8 = 0x87)
        -> BLEAdvertisement
    {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes.replaceSubrange(0...9, with: [0x4C, 0, 7, 0x19, 1, 0x14, 0x20, 0x20, levels, 6])
        return BLEAdvertisement(identifier: id, name: name, manufacturerData: Data(bytes))
    }

    func testOffPausedAndSmokeControllersNeverCreateNativeAccess() async {
        for (available, enabled, active) in [
            (false, true, true), (true, false, true), (true, true, false),
        ] {
            let f = fixture(available: available, enabled: enabled, active: active)
            f.controller.configure(
                BLEPreferences(enabled: enabled, airPods: selection(), iPhone: selection()))
            f.controller.discover()
            let pods = await f.controller.readAirPods()
            let phone = await f.controller.readIPhone()
            XCTAssertNil(pods)
            XCTAssertNil(phone)
            XCTAssertFalse(f.controller.isDiscovering)
            XCTAssertEqual(f.environment.creations, 0)
        }
    }

    func testConfiguredBudgetsCannotExceedAdvertisedScanAndPhoneLimits() async {
        let f = fixture(scanTimeout: 600, phoneTimeout: 600)
        f.controller.configure(
            BLEPreferences(enabled: true, airPods: selection(), iPhone: selection()))
        let pods = Task { await f.controller.readAirPods() }
        let phone = Task { await f.controller.readIPhone() }
        await eventually { f.access.scans.count == 1 && f.access.phones.count == 1 }
        XCTAssertEqual(f.access.scans[0], 5)
        XCTAssertEqual(f.access.phones[0].1, 10)
        f.access.resolveScan(0, [])
        f.access.resolvePhone(0, nil)
        _ = await pods.value
        _ = await phone.value
    }

    func testEnabledWithoutExplicitSelectionsDoesNotScanOrConnectForFallback() async {
        let f = fixture()
        let pods = await f.controller.readAirPods()
        let phone = await f.controller.readIPhone()
        XCTAssertNil(pods)
        XCTAssertNil(phone)
        XCTAssertEqual(f.environment.creations, 0)
    }

    func testExistingPrimaryReadingsIncludingPartialAirPodsNeverInvokeBLE() async {
        let f = fixture()
        f.controller.configure(
            BLEPreferences(enabled: true, airPods: selection(), iPhone: selection()))
        let readings: [BatteryReading] = [
            .mac(nil), .mac(72), .iPhone(0), .iPhone(100),
            .airPods(AirPodsBattery(caseLevel: 63)), .airPods(AirPodsBattery(left: 74)),
            .airPods(AirPodsBattery(main: 80)),
        ]
        for primary in readings {
            let fallback = await f.controller.fallback(for: primary)
            XCTAssertEqual(
                fallback.updating(BatterySnapshot()), primary.updating(BatterySnapshot()))
        }
        XCTAssertEqual(f.environment.creations, 0)
    }

    func testAirPodsMatchesOnlySelectedUUIDEvenWhenNearbyNamesAreIdentical() async {
        let f = fixture()
        let selected = selection("Same name")
        f.controller.configure(BLEPreferences(enabled: true, airPods: selected))
        let task = Task { await f.controller.readAirPods() }
        await eventually { f.access.scans.count == 1 }
        f.access.resolveScan(
            0, [airPods(UUID(), name: "Same name", levels: 0xAA), airPods(selected.id)])
        let result = await task.value
        XCTAssertEqual(
            result, AirPodsBattery(left: 70, right: 80, caseLevel: 60, isApproximate: true))
        XCTAssertEqual(f.access.scans, [5])
        XCTAssertTrue(
            f.access.phones.isEmpty, "AirPods advertisements never need a GATT connection")
    }

    func testNearbyDeviceCannotReplaceMissingSelectionAndNoBatteryCacheIsUsed() async {
        let f = fixture()
        let selected = selection()
        f.controller.configure(BLEPreferences(enabled: true, airPods: selected))
        for index in 0...2 {
            let task = Task { await f.controller.readAirPods() }
            await eventually { f.access.scans.count == index + 1 }
            f.access.resolveScan(
                index, index == 0 ? [airPods(selected.id)] : (index == 1 ? [airPods(UUID())] : []))
            let reading = await task.value
            if index == 0 { XCTAssertNotNil(reading) } else { XCTAssertNil(reading) }
        }
    }

    func testInvalidSelectedAdvertisementDoesNotUseAnotherDevicesValidPacket() async {
        let f = fixture()
        let selected = selection()
        f.controller.configure(BLEPreferences(enabled: true, airPods: selected))
        let task = Task { await f.controller.readAirPods() }
        await eventually { f.access.scans.count == 1 }
        f.access.resolveScan(
            0,
            [
                airPods(UUID()),
                BLEAdvertisement(
                    identifier: selected.id, name: "AirPods", manufacturerData: Data()),
            ])
        let result = await task.value
        XCTAssertNil(result)
    }

    func testSelectionChangeInvalidatesLateAirPodsResult() async {
        let f = fixture()
        let first = selection()
        let second = selection()
        f.controller.configure(BLEPreferences(enabled: true, airPods: first))
        let task = Task { await f.controller.readAirPods() }
        await eventually { f.access.scans.count == 1 }
        f.controller.configure(BLEPreferences(enabled: true, airPods: second))
        f.access.resolveScan(0, [airPods(first.id), airPods(second.id)])
        let result = await task.value
        XCTAssertNil(result)
        let fresh = Task { await f.controller.readAirPods() }
        await eventually { f.access.scans.count == 2 }
        f.access.resolveScan(1, [airPods(second.id)])
        let freshResult = await fresh.value
        XCTAssertNotNil(freshResult)
    }

    func testPausingAndResumingRejectsPrePauseResults() async {
        let f = fixture()
        let selected = selection()
        f.controller.configure(BLEPreferences(enabled: true, airPods: selected))
        let task = Task { await f.controller.readAirPods() }
        await eventually { f.access.scans.count == 1 }
        f.controller.setActive(false)
        f.controller.setActive(true)
        f.access.resolveScan(0, [airPods(selected.id)])
        let result = await task.value
        XCTAssertNil(result)
    }

    func testIPhoneReadTargetsSelectedUUIDAndTracksEventSuppressionGrace() async {
        let f = fixture()
        let selected = selection()
        f.controller.configure(BLEPreferences(enabled: true, iPhone: selected))
        XCTAssertFalse(f.controller.suppressesConnectionRefreshes)
        let task = Task { await f.controller.fallback(for: .iPhone(nil)) }
        await eventually { f.access.phones.count == 1 }
        XCTAssertEqual(f.access.phones[0].0, selected.id)
        XCTAssertEqual(f.access.phones[0].1, 10)
        XCTAssertTrue(f.controller.suppressesConnectionRefreshes)
        f.access.resolvePhone(0, 83)
        let reading = await task.value
        XCTAssertEqual(
            reading.updating(BatterySnapshot()), BatterySnapshot(iPhone: 83, iPhoneUsesBLE: true))
        XCTAssertTrue(f.controller.suppressesConnectionRefreshes)
        f.environment.uptime += 2.99
        XCTAssertTrue(f.controller.suppressesConnectionRefreshes)
        f.environment.uptime += 0.02
        XCTAssertFalse(f.controller.suppressesConnectionRefreshes)
        XCTAssertTrue(f.access.scans.isEmpty)
    }

    func testFailedOrInvalidIPhoneValueDoesNotInventPercentageOrProvenance() async {
        let f = fixture()
        f.controller.configure(BLEPreferences(enabled: true, iPhone: selection()))
        for (index, level) in [nil, -1, 101, 0, 100].enumerated() {
            let task = Task { await f.controller.fallback(for: .iPhone(nil)) }
            await eventually { f.access.phones.count == index + 1 }
            f.access.resolvePhone(index, level)
            let result = await task.value.updating(BatterySnapshot())
            let valid = level.flatMap { (0...100).contains($0) ? $0 : nil }
            XCTAssertEqual(result.iPhone, valid)
            XCTAssertEqual(result.iPhoneUsesBLE, valid != nil)
        }
    }

    func testPhoneReadsNeverOverlapAndDisablingRejectsLateResult() async {
        let f = fixture()
        f.controller.configure(BLEPreferences(enabled: true, iPhone: selection()))
        let first = Task { await f.controller.readIPhone() }
        await eventually { f.access.phones.count == 1 }
        let overlapping = await f.controller.readIPhone()
        XCTAssertNil(overlapping)
        XCTAssertEqual(f.access.phones.count, 1)
        f.controller.configure(BLEPreferences())
        f.access.resolvePhone(0, 83)
        let result = await first.value
        XCTAssertNil(result)
    }

    func testDiscoveryRequiresExplicitActionAndKeepsDistinctUUIDsWithSameNames() async {
        let f = fixture()
        XCTAssertEqual(f.environment.creations, 0)
        f.controller.discover()
        f.controller.discover()
        await eventually { f.access.scans.count == 1 }
        XCTAssertTrue(f.controller.isDiscovering)
        let first = UUID()
        let second = UUID()
        let phone = UUID()
        f.access.resolveScan(
            0,
            [
                airPods(first, name: "Same"), airPods(second, name: "Same"),
                BLEAdvertisement(
                    identifier: phone, name: "Phone candidate",
                    manufacturerData: Data([0x4C, 0, 0x10, 2, 1, 2])),
                BLEAdvertisement(identifier: UUID(), name: "AirPods", manufacturerData: Data()),
            ])
        await eventually { !f.controller.isDiscovering }
        XCTAssertEqual(Set(f.controller.candidates.map(\.id)), Set([first, second, phone]))
        XCTAssertEqual(f.controller.candidates.filter { $0.kind == .airPods }.count, 2)
        XCTAssertEqual(f.controller.candidates.filter { $0.kind == .iPhone }.count, 1)
        XCTAssertTrue(f.access.phones.isEmpty, "Discovery alone never connects to candidate phones")
    }

    func testCancellingDiscoveryDoesNotStopConcurrentFallbackScanOrPublishLateCandidates() async {
        let f = fixture()
        let selected = selection()
        f.controller.configure(BLEPreferences(enabled: true, airPods: selected))
        f.controller.discover()
        await eventually { f.access.scans.count == 1 }
        let fallback = Task { await f.controller.readAirPods() }
        await eventually { f.access.scans.count == 2 }
        let stopsBefore = f.access.stops
        f.controller.cancelDiscovery()
        await eventually { f.access.cancelledScans.contains(0) }
        XCTAssertEqual(f.access.stops, stopsBefore)
        f.access.resolveScan(0, [airPods(UUID())])
        f.access.resolveScan(1, [airPods(selected.id)])
        let result = await fallback.value
        XCTAssertNotNil(result)
        await Task.yield()
        XCTAssertTrue(f.controller.candidates.isEmpty)
    }

    func testStopAndWaitWaitsForDiscoveryAndStopIsTerminal() async {
        let f = fixture()
        f.controller.discover()
        await eventually { f.access.scans.count == 1 }
        var finished = false
        let stop = Task {
            await f.controller.stopAndWait()
            finished = true
        }
        await eventually { f.access.cancelledScans.contains(0) }
        XCTAssertFalse(finished)
        f.access.resolveScan(0, [airPods(UUID())])
        await stop.value
        XCTAssertTrue(finished)
        XCTAssertTrue(f.controller.candidates.isEmpty)
        f.controller.setActive(true)
        f.controller.configure(
            BLEPreferences(enabled: true, airPods: selection(), iPhone: selection()))
        f.controller.discover()
        let reading = await f.controller.readIPhone()
        XCTAssertNil(reading)
        XCTAssertEqual(f.access.scans.count, 1)
        XCTAssertTrue(f.access.phones.isEmpty)
    }

    func testIndependentSnapshotUpdatesPreserveBLEProvenanceUntilPrimaryPhoneReplacesIt() {
        let first = BatteryReading.iPhoneBLE(83).updating(BatterySnapshot())
        let second = BatteryReading.mac(72).updating(first)
        let third = BatteryReading.airPods(AirPodsBattery(left: 70, isApproximate: true)).updating(
            second)
        XCTAssertTrue(third.iPhoneUsesBLE)
        XCTAssertEqual(third.mac, 72)
        XCTAssertEqual(third.iPhone, 83)
        XCTAssertTrue(third.airPods?.isApproximate == true)
        let primary = BatteryReading.iPhone(84).updating(third)
        XCTAssertFalse(primary.iPhoneUsesBLE)
        XCTAssertEqual(primary.iPhone, 84)
        XCTAssertEqual(primary.airPods, third.airPods)
    }
}
