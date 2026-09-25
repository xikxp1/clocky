import ClockyCore
import Foundation
import IOKit.ps
import XCTest

@testable import Clocky

final class SystemBatteryProviderTests: XCTestCase {
    private struct Command: Hashable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private enum Reply: Sendable {
        case data(Data)
        case failure
        case cancelled
        case wait
        case timeout

        static func text(_ text: String) -> Reply { .data(Data(text.utf8)) }
    }

    private actor FixtureRunner: BatteryCommandRunning {
        struct Call: Sendable {
            let command: Command
            let timeout: TimeInterval
        }
        private(set) var calls: [Call] = []
        private var replies: [Command: Reply]
        private let onCall: @Sendable (Command) -> Void

        init(
            _ replies: [Command: Reply] = [:],
            onCall: @escaping @Sendable (Command) -> Void = { _ in }
        ) {
            self.replies = replies
            self.onCall = onCall
        }

        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
            -> Data
        {
            let command = Command(executable: executable, arguments: arguments)
            calls.append(Call(command: command, timeout: timeout))
            onCall(command)
            switch replies[command] ?? .failure {
            case .data(let data): return data
            case .failure: throw BatteryCommandError.nonZeroExit(1)
            case .cancelled: throw CancellationError()
            case .wait:
                try await Task.sleep(for: .seconds(10))
                throw BatteryCommandError.timedOut
            case .timeout:
                try await Task.sleep(for: .seconds(timeout))
                throw BatteryCommandError.timedOut
            }
        }

        func clearReplies() { replies.removeAll() }
    }

    private static let profiler = Command(
        executable: "/usr/sbin/system_profiler",
        arguments: ["SPBluetoothDataType", "-json", "-timeout", "5"]
    )
    private static let pairedList = Command(executable: "/fixture/idevicepair", arguments: ["list"])
    private static let savedHostID = "01234567-89AB-CDEF-0123-456789ABCDEF"
    private static let usbList = Command(executable: "/fixture/idevice_id", arguments: ["-l"])
    private static let networkList = Command(executable: "/fixture/idevice_id", arguments: ["-n"])
    private static let pods = Data(
        #"{"SPBluetoothDataType":[{"device_connected":[{"AirPods Pro":{"device_batteryLevelLeft":"81%","device_batteryLevelRight":"76%"}}]}]}"#
            .utf8)

    private static func hostID(_ udid: String, network: Bool = false) -> Command {
        Command(
            executable: "/fixture/idevicepair",
            arguments: ["-u", udid] + (network ? ["-n"] : []) + ["hostid"]
        )
    }

    private static func product(_ udid: String, network: Bool = false) -> Command {
        Command(
            executable: "/fixture/ideviceinfo",
            arguments: ["-s", "-u", udid] + (network ? ["-n"] : []) + ["-k", "ProductType"]
        )
    }

    private static func validate(_ udid: String, network: Bool = false) -> Command {
        Command(
            executable: "/fixture/idevicepair",
            arguments: ["-u", udid] + (network ? ["-n"] : []) + ["validate"]
        )
    }

    private static func battery(_ udid: String, network: Bool = false) -> Command {
        Command(
            executable: "/fixture/ideviceinfo",
            arguments: ["-u", udid] + (network ? ["-n"] : []) + [
                "-x", "-q", "com.apple.mobile.battery",
            ]
        )
    }

    private static func level(_ value: Int) -> Reply {
        .text(
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>BatteryCurrentCapacity</key><integer>\(value)</integer></dict></plist>"
        )
    }

    private func provider(
        _ runner: FixtureRunner, maximumDeviceCandidates: Int = 4,
        helperTimeout: TimeInterval = 2, iPhoneSampleTimeout: TimeInterval = 8
    ) -> SystemBatteryProvider {
        SystemBatteryProvider(
            runner: runner, toolLocator: { "/fixture/" + $0 }, macReader: { nil },
            helperTimeout: helperTimeout, iPhoneSampleTimeout: iPhoneSampleTimeout,
            maximumDeviceCandidates: maximumDeviceCandidates
        )
    }

    func testMissingOptionalHelpersPreservesMacAndAirPods() async {
        let runner = FixtureRunner([Self.profiler: .data(Self.pods)])
        let provider = SystemBatteryProvider(
            runner: runner, toolLocator: { _ in nil }, macReader: { 55 })
        let snapshot = await provider.read()
        XCTAssertEqual(
            snapshot, BatterySnapshot(mac: 55, airPods: AirPodsBattery(left: 81, right: 76)))
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.command), [Self.profiler])
        XCTAssertEqual(calls.first?.timeout, 6)
    }

    func testIndependentMacReadDoesNotLaunchDeviceHelpers() async {
        let runner = FixtureRunner()
        let provider = SystemBatteryProvider(
            runner: runner,
            toolLocator: { _ in
                XCTFail("Mac sampling must not discover iPhone tools")
                return nil
            },
            macReader: { 72 }
        )
        let level = await provider.readMac()
        XCTAssertEqual(level, 72)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testIndependentAirPodsReadDoesNotReadMacOrIPhone() async {
        let runner = FixtureRunner([Self.profiler: .data(Self.pods)])
        let provider = SystemBatteryProvider(
            runner: runner,
            toolLocator: { _ in
                XCTFail("AirPods sampling must not discover iPhone tools")
                return nil
            },
            macReader: {
                XCTFail("AirPods sampling must not read the Mac")
                return nil
            }
        )
        let battery = await provider.readAirPods()
        XCTAssertEqual(battery, AirPodsBattery(left: 81, right: 76))
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.command), [Self.profiler])
    }

    func testIndependentIPhoneReadDoesNotLaunchProfilerOrReadMac() async {
        let runner = FixtureRunner([Self.usbList: .text(""), Self.networkList: .text("")])
        let provider = SystemBatteryProvider(
            runner: runner, toolLocator: { "/fixture/" + $0 },
            macReader: {
                XCTFail("iPhone sampling must not read the Mac")
                return nil
            }
        )
        let level = await provider.readIPhone()
        XCTAssertNil(level)
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.command), [Self.usbList, Self.networkList])
    }

    func testAllThreeOptionalHelpersAreRequiredWithoutLosingMacAndAirPods() async {
        for missing in ["idevice_id", "ideviceinfo", "idevicepair"] {
            let runner = FixtureRunner([Self.profiler: .data(Self.pods)])
            let provider = SystemBatteryProvider(
                runner: runner, toolLocator: { $0 == missing ? nil : "/fixture/" + $0 },
                macReader: { 55 }
            )
            let snapshot = await provider.read()
            XCTAssertEqual(
                snapshot, BatterySnapshot(mac: 55, airPods: AirPodsBattery(left: 81, right: 76)),
                missing)
            let calls = await runner.calls
            XCTAssertEqual(calls.map(\.command), [Self.profiler])
        }
    }

    func testAuthenticatedBatteryDoesNotRequireEnumerablePairingRecordsOnUSBAndWiFi() async {
        for network in [false, true] {
            // macOS can expose a saved record through usbmuxd even when disk enumeration is empty.
            for listReply in [nil, Reply.text(""), .failure] as [Reply?] {
                var replies: [Command: Reply] = [
                    Self.usbList: .text(network ? "" : "phone\n"),
                    Self.networkList: .text("phone\n"),
                    Self.hostID("phone", network: network): .text(" \t\(Self.savedHostID)\r\n"),
                    Self.product("phone", network: network): .text("iPhone16,1"),
                    Self.validate("phone", network: network): .text(""),
                    Self.battery("phone", network: network): Self.level(83),
                ]
                replies[Self.pairedList] = listReply
                let runner = FixtureRunner(replies)
                let snapshot = await provider(runner).read()
                XCTAssertEqual(snapshot.iPhone, 83)
                let calls = await runner.calls.filter { $0.command != Self.profiler }
                XCTAssertEqual(
                    calls.map(\.command),
                    [Self.usbList]
                        + (network ? [Self.networkList] : []) + [
                            Self.hostID("phone", network: network),
                            Self.product("phone", network: network),
                            Self.validate("phone", network: network),
                            Self.battery("phone", network: network),
                        ])
                XCTAssertFalse(calls.contains { $0.command == Self.pairedList })
                // ProductType stays simple; the battery domain must use an authenticated session.
                XCTAssertEqual(
                    calls.last?.command.arguments,
                    ["-u", "phone"] + (network ? ["-n"] : []) + [
                        "-x", "-q", "com.apple.mobile.battery",
                    ])
                XCTAssertTrue(calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 2 })
            }
        }
    }

    func testUnavailableHostIDBlocksAllFurtherDeviceQueriesOnUSBAndWiFi() async {
        let unavailable: [Reply?] = [
            nil, .failure, .timeout, .text(""), .text(" \t\n\r\n"), .text("(null)\n"),
            .text("not-a-uuid"), .data(Data([0xFF])), .text("01234567-89AB-CDEF-0123-456789ABCDE"),
            .text("ERROR: Could not read pairing record\n"),
            .text("\(Self.savedHostID)\nextra-output"),
        ]
        for network in [false, true] {
            for hostReply in unavailable {
                var replies: [Command: Reply] = [
                    Self.profiler: .data(Self.pods),
                    Self.usbList: .text(network ? "" : "phone"),
                    Self.networkList: .text(network ? "phone" : ""),
                    Self.product("phone", network: network): .text("iPhone16,1"),
                    Self.validate("phone", network: network): .text(""),
                    Self.battery("phone", network: network): Self.level(83),
                ]
                replies[Self.hostID("phone", network: network)] = hostReply
                let runner = FixtureRunner(replies)
                let provider = SystemBatteryProvider(
                    runner: runner, toolLocator: { "/fixture/" + $0 }, macReader: { 55 },
                    helperTimeout: 0.02
                )
                let snapshot = await provider.read()
                XCTAssertEqual(
                    snapshot, BatterySnapshot(mac: 55, airPods: AirPodsBattery(left: 81, right: 76))
                )
                let calls = await runner.calls.filter { $0.command != Self.profiler }
                XCTAssertEqual(
                    calls.map(\.command),
                    [Self.usbList]
                        + (network ? [Self.networkList] : []) + [
                            Self.hostID("phone", network: network)
                        ]
                        + (network ? [] : [Self.networkList]))
                XCTAssertTrue(calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 0.02 })
            }
        }
    }

    func testUnavailableHostIDSkipsDeviceAndTriesNextCandidateOnUSBAndWiFi() async {
        for network in [false, true] {
            for unavailable in [Reply.failure, .text("(null)"), .timeout] {
                let runner = FixtureRunner([
                    Self.usbList: .text(network ? "" : "b\na"), Self.networkList: .text("b\na"),
                    Self.hostID("a", network: network): unavailable,
                    Self.product("a", network: network): .text("iPhone16,1"),
                    Self.validate("a", network: network): .text(""),
                    Self.battery("a", network: network): Self.level(12),
                    Self.hostID("b", network: network): .text(Self.savedHostID),
                    Self.product("b", network: network): .text("iPhone16,1"),
                    Self.validate("b", network: network): .text(""),
                    Self.battery("b", network: network): Self.level(83),
                ])
                let snapshot = await provider(runner, helperTimeout: 0.02).read()
                XCTAssertEqual(snapshot.iPhone, 83)
                let calls = await runner.calls
                XCTAssertEqual(
                    calls.map(\.command).filter { $0 != Self.profiler },
                    [Self.usbList]
                        + (network ? [Self.networkList] : []) + [
                            Self.hostID("a", network: network), Self.hostID("b", network: network),
                            Self.product("b", network: network),
                            Self.validate("b", network: network),
                            Self.battery("b", network: network),
                        ])
            }
        }
    }

    func testSortedBoundedHostIDChecksIncludeUnpairedCandidatesOnUSBAndWiFi() async {
        for network in [false, true] {
            let discovered =
                "D-phone\nA-unpaired\n../unsafe\nC-phone\nB-unpaired\nA-unpaired\n\nERROR: failed\n"
                + String(repeating: "a", count: 129) + "\n"
            let runner = FixtureRunner([
                Self.usbList: .text(network ? "" : discovered), Self.networkList: .text(discovered),
                Self.hostID("A-unpaired", network: network): .failure,
                Self.hostID("B-unpaired", network: network): .text("(null)"),
                Self.hostID("C-phone", network: network): .text(Self.savedHostID),
                Self.product("C-phone", network: network): .text("iPhone16,1"),
                Self.validate("C-phone", network: network): .text(""),
                Self.battery("C-phone", network: network): Self.level(83),
            ])
            let snapshot = await provider(runner, maximumDeviceCandidates: 2).read()
            XCTAssertNil(snapshot.iPhone)
            let calls = await runner.calls
            XCTAssertEqual(
                calls.map(\.command).filter { $0 != Self.profiler },
                [Self.usbList]
                    + (network ? [Self.networkList] : []) + [
                        Self.hostID("A-unpaired", network: network),
                        Self.hostID("B-unpaired", network: network),
                    ])
        }
    }

    func testUSBIsSortedDeduplicatedAndIPadSkippedBeforeFirstReadableIPhone() async {
        let runner = FixtureRunner([
            Self.usbList: .text("C-phone\nB-phone\nA-ipad\nB-phone\n"),
            Self.hostID("A-ipad"): .text(Self.savedHostID),
            Self.product("A-ipad"): .text("iPad14,3\n"),
            Self.hostID("B-phone"): .text(Self.savedHostID),
            Self.product("B-phone"): .text("iPhone16,1\n"),
            Self.validate("B-phone"): .text(""), Self.battery("B-phone"): Self.level(63),
        ])
        let snapshot = await provider(runner).read()
        XCTAssertEqual(snapshot.iPhone, 63)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.map(\.command).filter { $0 != Self.profiler },
            [
                Self.usbList, Self.hostID("A-ipad"), Self.product("A-ipad"), Self.hostID("B-phone"),
                Self.product("B-phone"), Self.validate("B-phone"), Self.battery("B-phone"),
            ])
        XCTAssertTrue(
            calls.filter { $0.command != Self.profiler }.allSatisfy {
                $0.timeout > 0 && $0.timeout <= 2
            })
    }

    func testUnreadableUSBUsesAlreadyPairedWiFiForSameDevice() async {
        for unreadable in [
            Reply.failure, .text("invalid plist"), .text("<plist version=\"1.0\"><dict/></plist>"),
            Self.level(101),
        ] {
            let runner = FixtureRunner([
                Self.usbList: .text("phone\n"), Self.hostID("phone"): .text(Self.savedHostID),
                Self.product("phone"): .text("iPhone15,2"),
                Self.validate("phone"): .text(""), Self.battery("phone"): unreadable,
                Self.networkList: .text("phone\n"),
                Self.hostID("phone", network: true): .text(Self.savedHostID),
                Self.product("phone", network: true): .text("iPhone15,2"),
                Self.validate("phone", network: true): .text(""),
                Self.battery("phone", network: true): Self.level(47),
            ])
            let snapshot = await provider(runner).read()
            XCTAssertEqual(snapshot.iPhone, 47)
            let calls = await runner.calls
            XCTAssertEqual(
                calls.map(\.command).filter { $0 != Self.profiler },
                [
                    Self.usbList, Self.hostID("phone"), Self.product("phone"),
                    Self.validate("phone"),
                    Self.battery("phone"), Self.networkList, Self.hostID("phone", network: true),
                    Self.product("phone", network: true), Self.validate("phone", network: true),
                    Self.battery("phone", network: true),
                ])
        }
    }

    func testValidationFailureOrTimeoutPreventsBatteryRead() async {
        for network in [false, true] {
            for invalid in [Reply.failure, .timeout] {
                let runner = FixtureRunner([
                    Self.usbList: .text(network ? "" : "phone"),
                    Self.networkList: .text(network ? "phone" : ""),
                    Self.hostID("phone", network: network): .text(Self.savedHostID),
                    Self.product("phone", network: network): .text("iPhone16,1"),
                    Self.validate("phone", network: network): invalid,
                    Self.battery("phone", network: network): Self.level(83),
                ])
                let snapshot = await provider(runner, helperTimeout: 0.02).read()
                XCTAssertNil(snapshot.iPhone)
                let calls = await runner.calls.filter { $0.command != Self.profiler }
                XCTAssertEqual(
                    calls.map(\.command),
                    [Self.usbList]
                        + (network ? [Self.networkList] : []) + [
                            Self.hostID("phone", network: network),
                            Self.product("phone", network: network),
                            Self.validate("phone", network: network),
                        ] + (network ? [] : [Self.networkList]))
                XCTAssertTrue(calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 0.02 })
            }
        }
    }

    func testUSBValidationFailureAllowsWiFiForSameDevice() async {
        for invalid in [Reply.failure, .timeout] {
            let runner = FixtureRunner([
                Self.usbList: .text("phone"), Self.hostID("phone"): .text(Self.savedHostID),
                Self.product("phone"): .text("iPhone16,1"), Self.validate("phone"): invalid,
                Self.battery("phone"): Self.level(12), Self.networkList: .text("phone"),
                Self.hostID("phone", network: true): .text(Self.savedHostID),
                Self.product("phone", network: true): .text("iPhone16,1"),
                Self.validate("phone", network: true): .text(""),
                Self.battery("phone", network: true): Self.level(83),
            ])
            let snapshot = await provider(runner, helperTimeout: 0.02).read()
            XCTAssertEqual(snapshot.iPhone, 83)
            let calls = await runner.calls
            XCTAssertEqual(
                calls.map(\.command).filter { $0 != Self.profiler },
                [
                    Self.usbList, Self.hostID("phone"), Self.product("phone"),
                    Self.validate("phone"), Self.networkList,
                    Self.hostID("phone", network: true), Self.product("phone", network: true),
                    Self.validate("phone", network: true), Self.battery("phone", network: true),
                ])
        }
    }

    func testFailedUSBDiscoveryStillTriesNetwork() async {
        for unreadable in [Reply.failure, .data(Data([0xFF])), .text("")] {
            let runner = FixtureRunner([
                Self.usbList: unreadable, Self.networkList: .text("wifi\n"),
                Self.hostID("wifi", network: true): .text(Self.savedHostID),
                Self.product("wifi", network: true): .text("iPhone16,2"),
                Self.validate("wifi", network: true): .text(""),
                Self.battery("wifi", network: true): Self.level(0),
            ])
            let snapshot = await provider(runner).read()
            XCTAssertEqual(snapshot.iPhone, 0)
            let calls = await runner.calls
            XCTAssertEqual(
                calls.map(\.command).filter { $0 != Self.profiler },
                [
                    Self.usbList, Self.networkList, Self.hostID("wifi", network: true),
                    Self.product("wifi", network: true), Self.validate("wifi", network: true),
                    Self.battery("wifi", network: true),
                ])
        }
    }

    func testInvalidProductTypesAreNeverValidatedOrLabeledIPhoneOnUSBAndWiFi() async {
        for network in [false, true] {
            let runner = FixtureRunner([
                Self.usbList: .text(network ? "" : "a\nb\nc"),
                Self.networkList: .text(network ? "a\nb\nc" : ""),
                Self.hostID("a", network: network): .text(Self.savedHostID),
                Self.product("a", network: network): .text("iPad14,3"),
                Self.validate("a", network: network): .text(""),
                Self.battery("a", network: network): Self.level(83),
                Self.hostID("b", network: network): .text(Self.savedHostID),
                Self.product("b", network: network): .data(Data([0xFF])),
                Self.validate("b", network: network): .text(""),
                Self.battery("b", network: network): Self.level(83),
                Self.hostID("c", network: network): .text(Self.savedHostID),
                Self.product("c", network: network): .text(""),
                Self.validate("c", network: network): .text(""),
                Self.battery("c", network: network): Self.level(83),
            ])
            let snapshot = await provider(runner).read()
            XCTAssertNil(snapshot.iPhone)
            let calls = await runner.calls
            XCTAssertEqual(
                calls.map(\.command).filter { $0 != Self.profiler },
                [Self.usbList]
                    + (network ? [Self.networkList] : []) + [
                        Self.hostID("a", network: network), Self.product("a", network: network),
                        Self.hostID("b", network: network), Self.product("b", network: network),
                        Self.hostID("c", network: network), Self.product("c", network: network),
                    ] + (network ? [] : [Self.networkList]))
        }
    }

    func testNextUSBPhoneIsTriedAfterFirstBatteryFails() async {
        let runner = FixtureRunner([
            Self.usbList: .text("b\na\n"), Self.hostID("a"): .text(Self.savedHostID),
            Self.product("a"): .text("iPhone15,1"), Self.validate("a"): .text(""),
            Self.battery("a"): .failure,
            Self.hostID("b"): .text(Self.savedHostID), Self.product("b"): .text("iPhone16,1"),
            Self.validate("b"): .text(""), Self.battery("b"): Self.level(91),
        ])
        let snapshot = await provider(runner).read()
        XCTAssertEqual(snapshot.iPhone, 91)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.map(\.command).filter { $0 != Self.profiler },
            [
                Self.usbList, Self.hostID("a"), Self.product("a"), Self.validate("a"),
                Self.battery("a"),
                Self.hostID("b"), Self.product("b"), Self.validate("b"), Self.battery("b"),
            ])
    }

    func testFailuresDoNotReuseCachedBatteryLevels() async {
        let runner = FixtureRunner([
            Self.profiler: .data(Self.pods), Self.usbList: .text("phone"),
            Self.hostID("phone"): .text(Self.savedHostID),
            Self.product("phone"): .text("iPhone16,1"),
            Self.validate("phone"): .text(""), Self.battery("phone"): Self.level(50),
        ])
        let provider = provider(runner)
        let first = await provider.read()
        XCTAssertEqual(first.iPhone, 50)
        XCTAssertNotNil(first.airPods)
        await runner.clearReplies()
        let second = await provider.read()
        XCTAssertEqual(second, BatterySnapshot())
        let calls = await runner.calls
        XCTAssertEqual(
            calls.map(\.command).filter { $0 != Self.profiler },
            [
                Self.usbList, Self.hostID("phone"), Self.product("phone"), Self.validate("phone"),
                Self.battery("phone"),
                Self.usbList, Self.networkList,
            ])
    }

    func testMalformedProfilerDataDoesNotLoseValidOtherReadings() async {
        let runner = FixtureRunner([
            Self.profiler: .text("not json"), Self.usbList: .text("phone"),
            Self.hostID("phone"): .text(Self.savedHostID),
            Self.product("phone"): .text("iPhone16,1"),
            Self.validate("phone"): .text(""), Self.battery("phone"): Self.level(100),
        ])
        let provider = SystemBatteryProvider(
            runner: runner, toolLocator: { "/fixture/" + $0 }, macReader: { 0 })
        let snapshot = await provider.read()
        XCTAssertEqual(snapshot, BatterySnapshot(mac: 0, iPhone: 100))
    }

    func testDefaultFourCandidateBudgetIsSharedAcrossUSBAndWiFi() async {
        let runner = FixtureRunner([
            Self.usbList: .text("b\na"), Self.hostID("a"): .failure,
            Self.hostID("b"): .text("(null)"),
            Self.networkList: .text("e\nd\nc"),
            Self.hostID("c", network: true): .failure, Self.hostID("d", network: true): .text(""),
            Self.hostID("e", network: true): .text(Self.savedHostID),
            Self.product("e", network: true): .text("iPhone16,1"),
            Self.validate("e", network: true): .text(""),
            Self.battery("e", network: true): Self.level(83),
        ])
        let snapshot = await provider(runner).read()
        XCTAssertNil(snapshot.iPhone)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.map(\.command).filter { $0 != Self.profiler },
            [
                Self.usbList, Self.hostID("a"), Self.hostID("b"), Self.networkList,
                Self.hostID("c", network: true), Self.hostID("d", network: true),
            ])
    }

    func testOverallDeadlineLimitsEvenDiscoveryCommand() async {
        let runner = FixtureRunner([Self.usbList: .timeout])
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = await provider(runner, iPhoneSampleTimeout: 0.05).read()
        XCTAssertNil(snapshot.iPhone)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        let calls = await runner.calls.filter { $0.command != Self.profiler }
        XCTAssertEqual(calls.map(\.command), [Self.usbList])
        XCTAssertTrue(calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 0.05 })
    }

    func testOverallDeadlineLimitsHostIDAndStopsFurtherCommandsOnUSBAndWiFi() async {
        for network in [false, true] {
            let runner = FixtureRunner([
                Self.usbList: .text(network ? "" : "b\na"), Self.networkList: .text("b\na"),
                Self.hostID("a", network: network): .timeout,
                Self.product("a", network: network): .text("iPhone16,1"),
                Self.validate("a", network: network): .text(""),
                Self.battery("a", network: network): Self.level(83),
                Self.hostID("b", network: network): .text(Self.savedHostID),
            ])
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = await provider(runner, iPhoneSampleTimeout: 0.05).read()
            XCTAssertNil(snapshot.iPhone)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            let calls = await runner.calls.filter { $0.command != Self.profiler }
            XCTAssertEqual(
                calls.map(\.command),
                [Self.usbList]
                    + (network ? [Self.networkList] : []) + [Self.hostID("a", network: network)])
            XCTAssertTrue(calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 0.05 })
            for (previous, next) in zip(calls, calls.dropFirst()) {
                XCTAssertLessThanOrEqual(next.timeout, previous.timeout)
            }
        }
    }

    func testOverallDeadlineLimitsValidationAndStopsFurtherCommandsOnUSBAndWiFi() async {
        for network in [false, true] {
            let runner = FixtureRunner([
                Self.usbList: .text(network ? "" : "phone"), Self.networkList: .text("phone"),
                Self.hostID("phone", network: network): .text(Self.savedHostID),
                Self.product("phone", network: network): .text("iPhone16,1"),
                Self.validate("phone", network: network): .timeout,
                Self.battery("phone", network: network): Self.level(83),
            ])
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = await provider(runner, iPhoneSampleTimeout: 0.05).read()
            XCTAssertNil(snapshot.iPhone)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            let calls = await runner.calls.filter { $0.command != Self.profiler }
            XCTAssertEqual(
                calls.map(\.command),
                [Self.usbList]
                    + (network ? [Self.networkList] : []) + [
                        Self.hostID("phone", network: network),
                        Self.product("phone", network: network),
                        Self.validate("phone", network: network),
                    ])
            XCTAssertTrue(calls.allSatisfy { $0.timeout > 0 && $0.timeout <= 0.05 })
            for (previous, next) in zip(calls, calls.dropFirst()) {
                XCTAssertLessThanOrEqual(next.timeout, previous.timeout)
            }
        }
    }

    func testPreCancelledReadLaunchesNothing() async {
        let runner = FixtureRunner()
        let provider = SystemBatteryProvider(
            runner: runner,
            toolLocator: { _ in
                XCTFail("Discovery after cancellation")
                return nil
            },
            macReader: {
                XCTFail("Mac read after cancellation")
                return nil
            }
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await provider.read()
        }
        let snapshot = await task.value
        XCTAssertEqual(snapshot, BatterySnapshot())
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancellationPropagatesToParallelReadsAndStopsNewCommands() async {
        let started = expectation(description: "Both independent commands started")
        started.expectedFulfillmentCount = 2
        let runner = FixtureRunner([Self.usbList: .wait, Self.profiler: .wait]) { command in
            if command == Self.usbList || command == Self.profiler { started.fulfill() }
        }
        let provider = provider(runner)
        let task = Task { await provider.read() }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let snapshot = await task.value
        XCTAssertEqual(snapshot, BatterySnapshot())
        let calls = await runner.calls
        XCTAssertEqual(Set(calls.map(\.command)), [Self.usbList, Self.profiler])
    }

    func testCancellationDuringHostIDStopsAllFurtherCommandsOnUSBAndWiFi() async {
        for network in [false, true] {
            let started = expectation(description: "Host ID check started, network: \(network)")
            let runner = FixtureRunner([
                Self.usbList: .text(network ? "" : "b\na"), Self.networkList: .text("b\na"),
                Self.hostID("a", network: network): .wait,
                Self.product("a", network: network): .text("iPhone16,1"),
                Self.validate("a", network: network): .text(""),
                Self.battery("a", network: network): Self.level(83),
                Self.hostID("b", network: network): .text(Self.savedHostID),
                Self.product("b", network: network): .text("iPhone16,1"),
                Self.validate("b", network: network): .text(""),
                Self.battery("b", network: network): Self.level(90),
            ]) { command in
                if command == Self.hostID("a", network: network) { started.fulfill() }
            }
            let provider = provider(runner)
            let task = Task { await provider.read() }
            defer { task.cancel() }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            let snapshot = await task.value
            XCTAssertNil(snapshot.iPhone)
            let calls = await runner.calls
            XCTAssertEqual(
                calls.map(\.command).filter { $0 != Self.profiler },
                [Self.usbList]
                    + (network ? [Self.networkList] : []) + [Self.hostID("a", network: network)])
        }
    }

    func testCancellationDuringValidationStopsBatteryOtherCandidatesAndWiFi() async {
        for network in [false, true] {
            let started = expectation(
                description: "Pairing validation started, network: \(network)")
            let runner = FixtureRunner([
                Self.usbList: .text(network ? "" : "b\na"), Self.networkList: .text("b\na"),
                Self.hostID("a", network: network): .text(Self.savedHostID),
                Self.product("a", network: network): .text("iPhone16,1"),
                Self.validate("a", network: network): .wait,
                Self.battery("a", network: network): Self.level(83),
                Self.hostID("b", network: network): .text(Self.savedHostID),
                Self.product("b", network: network): .text("iPhone16,1"),
                Self.validate("b", network: network): .text(""),
                Self.battery("b", network: network): Self.level(90),
            ]) { command in
                if command == Self.validate("a", network: network) { started.fulfill() }
            }
            let provider = provider(runner)
            let task = Task { await provider.read() }
            defer { task.cancel() }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            let snapshot = await task.value
            XCTAssertNil(snapshot.iPhone)
            let calls = await runner.calls
            XCTAssertEqual(
                calls.map(\.command).filter { $0 != Self.profiler },
                [Self.usbList]
                    + (network ? [Self.networkList] : []) + [
                        Self.hostID("a", network: network), Self.product("a", network: network),
                        Self.validate("a", network: network),
                    ])
        }
    }

    func testCommandCancellationErrorDoesNotTriggerFallbackOnUSBAndWiFi() async {
        for network in [false, true] {
            let commands =
                [Self.usbList] + (network ? [Self.networkList] : []) + [
                    Self.hostID("phone", network: network), Self.product("phone", network: network),
                    Self.validate("phone", network: network),
                    Self.battery("phone", network: network),
                ]
            for (index, cancelledCommand) in commands.enumerated() {
                var replies: [Command: Reply] = [
                    Self.usbList: .text(network ? "" : "phone"), Self.networkList: .text("phone"),
                    Self.hostID("phone", network: network): .text(Self.savedHostID),
                    Self.product("phone", network: network): .text("iPhone16,1"),
                    Self.validate("phone", network: network): .text(""),
                    Self.battery("phone", network: network): Self.level(83),
                ]
                replies[cancelledCommand] = .cancelled
                let runner = FixtureRunner(replies)
                let snapshot = await provider(runner).read()
                XCTAssertNil(snapshot.iPhone)
                let calls = await runner.calls
                XCTAssertEqual(
                    calls.map(\.command).filter { $0 != Self.profiler },
                    Array(commands.prefix(index + 1)))
            }
        }
    }

    func testRelativeDiscoveredToolsAreRejected() async {
        for relative in ["idevice_id", "ideviceinfo", "idevicepair"] {
            let runner = FixtureRunner()
            let provider = SystemBatteryProvider(
                runner: runner, toolLocator: { $0 == relative ? $0 : "/fixture/" + $0 },
                macReader: { nil }
            )
            _ = await provider.read()
            let calls = await runner.calls
            XCTAssertEqual(calls.map(\.command), [Self.profiler], relative)
        }
    }

    @MainActor
    func testMacReadIsOffMainActor() async {
        let provider = SystemBatteryProvider(
            runner: FixtureRunner(), toolLocator: { _ in nil },
            macReader: {
                XCTAssertFalse(Thread.isMainThread)
                return 72
            }
        )
        let snapshot = await provider.read()
        XCTAssertEqual(snapshot.mac, 72)
    }

    func testToolDiscoveryIncludesCommonInstallLocationsWithoutPATH() {
        for tool in ["idevice_id", "ideviceinfo", "idevicepair"] {
            for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
                let expected = directory + "/" + tool
                XCTAssertEqual(
                    SystemBatteryProvider.findTool(
                        tool, path: nil, isExecutable: { $0 == expected }), expected)
            }
        }
    }

    func testToolDiscoveryUsesOnlyAbsolutePATHDirectoriesAndDeduplicates() {
        var inspected: [String] = []
        let found = SystemBatteryProvider.findTool(
            "idevice_id", path: ":.:relative/bin:/opt/homebrew/bin:/custom/bin:/custom/bin"
        ) { candidate in
            inspected.append(candidate)
            return candidate == "/custom/bin/idevice_id"
        }
        XCTAssertEqual(found, "/custom/bin/idevice_id")
        XCTAssertEqual(
            inspected,
            [
                "/opt/homebrew/bin/idevice_id", "/usr/local/bin/idevice_id",
                "/opt/local/bin/idevice_id", "/custom/bin/idevice_id",
            ])
        XCTAssertNil(
            SystemBatteryProvider.findTool(
                "../ideviceinfo", path: "/tmp", isExecutable: { _ in true }))
    }

    func testMacCapacityUsesInternalBatteryRatioOnly() {
        var description: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 2_500,
            kIOPSMaxCapacityKey: 5_000,
        ]
        XCTAssertEqual(SystemBatteryProvider.macPercentage(from: description), 50)
        description[kIOPSCurrentCapacityKey] = 0
        XCTAssertEqual(SystemBatteryProvider.macPercentage(from: description), 0)
        description[kIOPSCurrentCapacityKey] = 5_000
        XCTAssertEqual(SystemBatteryProvider.macPercentage(from: description), 100)
        description[kIOPSTypeKey] = "UPS"
        XCTAssertNil(SystemBatteryProvider.macPercentage(from: description))
        description[kIOPSTypeKey] = nil
        XCTAssertNil(SystemBatteryProvider.macPercentage(from: description))
        description[kIOPSTypeKey] = kIOPSInternalBatteryType
        description[kIOPSIsPresentKey] = false
        XCTAssertNil(SystemBatteryProvider.macPercentage(from: description))
    }

    func testInvalidMacCapacitiesAreUnavailable() {
        for (current, maximum) in [
            (-1, 100), (101, 100), (1, 0), (1, -100), (true, 100), (1, false),
            (Double.nan, 100), (1, Double.infinity), ("50", 100),
        ] as [(Any, Any)] {
            XCTAssertNil(
                SystemBatteryProvider.macPercentage(from: [
                    kIOPSTypeKey: kIOPSInternalBatteryType,
                    kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: maximum,
                ]))
        }
        XCTAssertNil(
            SystemBatteryProvider.macPercentage(from: [
                kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 50,
            ]))
    }
}
