import AppKit
import ClockyCore
import Foundation
import XCTest

@testable import Clocky

@MainActor
final class BLEBatteryIntegrationTests: XCTestCase {
    private actor Provider: BatteryProviding {
        var phone: Int?
        var pods: AirPodsBattery?
        var counts: [BatterySource: Int] = [:]
        func readMac() async -> Int? {
            counts[.mac, default: 0] += 1
            return 72
        }
        func readIPhone() async -> Int? {
            counts[.iPhone, default: 0] += 1
            return phone
        }
        func readAirPods() async -> AirPodsBattery? {
            counts[.airPods, default: 0] += 1
            return pods
        }
        func count(_ source: BatterySource) -> Int { counts[source, default: 0] }
        func set(phone: Int?, pods: AirPodsBattery?) {
            self.phone = phone
            self.pods = pods
        }
    }

    private final class Access: BLEBatteryAccessing {
        var status = "Fixture"
        var scans = 0
        var phones: [UUID] = []
        var advertisements: [BLEAdvertisement] = []
        var holdPhone = false
        var continuations: [CheckedContinuation<Int?, Never>] = []
        func scan(timeout: TimeInterval) async -> [BLEAdvertisement] {
            scans += 1
            return advertisements
        }
        func readIPhone(identifier: UUID, timeout: TimeInterval) async -> Int? {
            phones.append(identifier)
            if holdPhone { return await withCheckedContinuation { continuations.append($0) } }
            return 83
        }
        func resolve(_ value: Int?) {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume(returning: value) }
        }
        func stop() { resolve(nil) }
    }

    private final class Monitor: BluetoothChangeMonitoring {
        var onChange: (@MainActor () -> Void)?
        func start(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        func stop() { onChange = nil }
        func emit() { onChange?() }
    }

    @MainActor
    private final class Environment {
        var time: TimeInterval = 100
        var backendCreations = 0
        let access = Access()
    }

    private struct Fixture {
        let settings: SettingsStore
        let provider: Provider
        let monitor: Monitor
        let service: BatteryService
        let environment: Environment
        let center: NotificationCenter
        var access: Access { environment.access }
    }

    private func fixture(enabled: Bool = true, holdPhone: Bool = false, interval: TimeInterval = 60)
        -> Fixture
    {
        let suite = "Clocky.BLEBatteryIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        let pods = BLEDeviceSelection(id: UUID(), name: "My AirPods")
        let phone = BLEDeviceSelection(id: UUID(), name: "My iPhone")
        settings.update { $0.ble = BLEPreferences(enabled: true, airPods: pods, iPhone: phone) }
        let environment = Environment()
        environment.access.holdPhone = holdPhone
        var data = [UInt8](repeating: 0, count: 29)
        data.replaceSubrange(0...9, with: [0x4C, 0, 7, 0x19, 1, 0x14, 0x20, 0x20, 0x87, 6])
        environment.access.advertisements = [
            BLEAdvertisement(identifier: pods.id, name: pods.name, manufacturerData: Data(data))
        ]
        let ble = BLEBatteryController(
            available: enabled, uptime: { environment.time },
            makeAccess: {
                environment.backendCreations += 1
                return environment.access
            }
        )
        let provider = Provider()
        let monitor = Monitor()
        let center = NotificationCenter()
        let service = BatteryService(
            settings: settings, enabled: enabled, provider: provider, interval: interval,
            workspaceCenter: center, bluetoothDebounce: 0.02, ble: ble,
            makeBluetoothMonitor: { monitor }
        )
        addTeardownBlock { @MainActor in
            await service.stopAndWait()
            defaults.removePersistentDomain(forName: suite)
        }
        return Fixture(
            settings: settings, provider: provider, monitor: monitor, service: service,
            environment: environment, center: center)
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Condition not met", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    func testBLEFallbacksPublishWithoutDelayingMacOrEachOther() async {
        let f = fixture(holdPhone: true)
        await eventually {
            f.access.phones.count == 1 && f.service.snapshot.mac == 72
                && f.service.snapshot.airPods != nil
        }
        XCTAssertNil(f.service.snapshot.iPhone)
        XCTAssertEqual(
            f.service.snapshot.airPods,
            AirPodsBattery(left: 70, right: 80, caseLevel: 60, isApproximate: true))
        f.access.resolve(83)
        await eventually { f.service.snapshot.iPhoneUsesBLE && f.service.snapshot.iPhone == 83 }
        XCTAssertEqual(f.access.phones.first, f.settings.preferences.ble.iPhone?.id)
        XCTAssertEqual(f.environment.backendCreations, 1)
    }

    func testPrimaryRecoveryReplacesWholeBLEReadingsAndStopsUsingFallback() async {
        let f = fixture()
        await eventually {
            f.service.snapshot.iPhoneUsesBLE && f.service.snapshot.airPods?.isApproximate == true
        }
        await f.provider.set(phone: 91, pods: AirPodsBattery(caseLevel: 63))
        f.environment.time += 4
        f.monitor.emit()
        await eventually {
            f.service.snapshot
                == BatterySnapshot(mac: 72, iPhone: 91, airPods: AirPodsBattery(caseLevel: 63))
        }
        XCTAssertEqual(f.access.phones.count, 1)
        XCTAssertEqual(
            f.access.scans, 1,
            "Missing buds in a primary case-only result must not be filled from a different BLE identity"
        )
    }

    func testDisablingOrForgettingBLEImmediatelyClearsItsReadings() async {
        for disable in [true, false] {
            let f = fixture()
            await eventually {
                f.service.snapshot.iPhoneUsesBLE
                    && f.service.snapshot.airPods?.isApproximate == true
            }
            f.settings.update {
                if disable {
                    $0.ble.enabled = false
                } else {
                    $0.ble.airPods = nil
                    $0.ble.iPhone = nil
                }
            }
            XCTAssertEqual(f.service.snapshot, BatterySnapshot(mac: 72))
            await settle()
            XCTAssertEqual(f.access.phones.count, 1)
            XCTAssertEqual(f.access.scans, 1)
            XCTAssertEqual(f.service.snapshot, BatterySnapshot(mac: 72))
        }
    }

    func testOwnPhoneConnectionEventsAreSuppressedDuringReadAndCleanupOnly() async {
        let f = fixture(holdPhone: true)
        await eventually { f.access.phones.count == 1 }
        f.monitor.emit()
        await settle()
        for source in BatterySource.allCases {
            let count = await f.provider.count(source)
            XCTAssertEqual(count, 1, "Own connection cannot cancel and restart the sample")
        }
        f.access.resolve(83)
        await eventually { f.service.snapshot.iPhoneUsesBLE }
        f.monitor.emit()
        await settle()
        XCTAssertEqual(f.access.phones.count, 1, "Disconnect cleanup must not loop")
        f.environment.time += 4
        f.monitor.emit()
        await eventually { f.access.phones.count == 2 }
        for source in BatterySource.allCases {
            let count = await f.provider.count(source)
            XCTAssertEqual(count, 2, "Normal event acceleration resumes after cleanup")
        }
    }

    func testNormalPollingContinuesWhilePhoneGATTIsPending() async {
        let f = fixture(holdPhone: true, interval: 0.03)
        await eventually { f.access.phones.count == 1 }
        await eventually { await f.provider.count(.mac) >= 3 }
        XCTAssertEqual(f.access.phones.count, 1)
        let phoneReads = await f.provider.count(.iPhone)
        XCTAssertEqual(phoneReads, 1, "No overlapping phone reads during its GATT wait")
        XCTAssertEqual(f.service.snapshot.mac, 72)
    }

    func testSleepStopsBLEAndWakeRequestsFreshFallbackReadings() async {
        let f = fixture(holdPhone: true)
        await eventually { f.access.phones.count == 1 && f.service.snapshot.airPods != nil }
        f.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
        await settle()
        XCTAssertEqual(f.access.phones.count, 1)
        f.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await eventually { f.access.phones.count == 2 }
        f.access.resolve(84)
        await eventually { f.service.snapshot.iPhone == 84 && f.service.snapshot.iPhoneUsesBLE }
    }

    func testSmokeModeCannotCreateBLEEvenWithSavedEnabledSelections() async {
        let f = fixture(enabled: false)
        f.service.setPreviewVisible(true)
        f.service.ble.discover()
        f.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await settle()
        XCTAssertEqual(f.environment.backendCreations, 0)
        for source in BatterySource.allCases {
            let count = await f.provider.count(source)
            XCTAssertEqual(count, 0)
        }
        XCTAssertEqual(f.service.snapshot, BatterySnapshot())
    }
}
