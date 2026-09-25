import Foundation
import XCTest
@testable import ClockyCore

final class BatteryDataParserTests: XCTestCase {
    func testPercentageAcceptsIntegralNumbersIncludingZero() {
        let examples: [(Any, Int)] = [
            (0, 0), (1, 1), (100, 100), (UInt8(84), 84), (Int64(73), 73),
            (Double(63), 63), (Float(50), 50), (NSNumber(value: 1), 1),
            (NSDecimalNumber(string: "84.0"), 84)
        ]
        for (input, expected) in examples {
            XCTAssertEqual(BatteryDataParser.percentage(input), expected, "\(input)")
        }
    }

    func testPercentageAcceptsOrdinaryAndNonbreakingWhitespace() {
        let examples = ["84", "84%", " 84 % ", "\t84\u{00A0}%\n", "\u{00A0}84\u{202F}%\u{00A0}"]
        for input in examples {
            XCTAssertEqual(BatteryDataParser.percentage(input), 84, input)
        }
        XCTAssertEqual(BatteryDataParser.percentage("0 %"), 0)
        XCTAssertEqual(BatteryDataParser.percentage("100 %"), 100)
    }

    func testPercentageRejectsBooleansFractionsOverflowAndGarbage() {
        let invalid: [Any] = [
            true, false, NSNumber(value: true), NSNumber(value: false), NSNull(),
            -1, 101, Int.min, Int.max, UInt64.max, 84.5, -0.5,
            Double.nan, Double.infinity, -Double.infinity,
            NSDecimalNumber(string: "84.00000000000000000001"),
            "", " ", "%", "84%%", "84% trailing", "8 4%", "84.5%", "84.0%",
            "-1%", "+84%", "101%", "1e2", "0x54", "N/A", "true", "８４%",
            "9999999999999999999999999999999999999999", [84], ["value": 84]
        ]
        XCTAssertNil(BatteryDataParser.percentage(nil))
        for input in invalid {
            XCTAssertNil(BatteryDataParser.percentage(input), "\(input)")
        }
    }

    func testRealSystemProfilerShapePrefersRichReadingsOverCaseOnlyDuplicate() {
        let data = Data("""
        {
          "SPBluetoothDataType": [{
            "device_connected": [
              {"Ivan’s AirPods": {
                "device_address": "00-00-00-00-00-01",
                "device_batteryLevelCase": "63\u{00A0}%",
                "device_services": "0x400000 < BLE >"
              }},
              {"Ivan’s AirPods": {
                "device_address": "00-00-00-00-00-02",
                "device_batteryLevelCase": "63\u{00A0}%",
                "device_batteryLevelLeft": "84\u{00A0}%",
                "device_batteryLevelRight": "73\u{00A0}%",
                "device_minorType": "Headphones",
                "device_productID": "0x201B",
                "device_vendorID": "0x004C"
              }}
            ],
            "device_not_connected": [
              {"Other AirPods": {
                "device_batteryLevelLeft": "100%",
                "device_batteryLevelRight": "100%",
                "device_batteryLevelCase": "100%"
              }},
              {"iPhone": {"device_batteryLevelMain": "99%"}}
            ]
          }]
        }
        """.utf8)
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(left: 84, right: 73, caseLevel: 63))
    }

    func testRenamedAirPodsAreRecognizedByKnownProductIDs() throws {
        for productID in ["0x2002", "0x200F", "0x2013", "0x2019", "0x201B", "0x200E", "0x2014", "0x2024", "0x2027", "0x200A", "0x201F"] {
            let data = try bluetoothData(connected: [["Morning commute": [
                "device_productID": productID,
                "device_vendorID": "0x004c",
                "device_batteryLevelCase": "63 %"
            ]]])
            XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(caseLevel: 63), productID)
        }
    }

    func testRenamedAirPodsWithOnlyOneSplitReadingNeedNoProductID() throws {
        for key in ["device_batteryLevelLeft", "device_batteryLevelRight"] {
            let data = try bluetoothData(connected: [["My earbuds": [key: "0 %"]]])
            let expected = key == "device_batteryLevelLeft" ? AirPodsBattery(left: 0) : AirPodsBattery(right: 0)
            XCTAssertEqual(BatteryDataParser.airPods(from: data), expected)
        }
    }

    func testNamedAirPodsMatchCaseInsensitively() throws {
        let data = try bluetoothData(connected: [["MY AIRPODS": ["device_batteryLevelCase": "42%"]]])
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(caseLevel: 42))
    }

    func testRenamedAirPodsMaxUsesMainBattery() throws {
        let data = try bluetoothData(connected: [["Studio headset": [
            "device_productID": "0X201F",
            "device_vendorID": "0x004C",
            "device_batteryLevelMain": "58\u{00A0}%",
            "device_minorType": "Headphones"
        ]]])
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(main: 58))
    }

    func testGenericMainBatteryKeyAndNumericIdentifiersAreSupported() throws {
        let data = try bluetoothData(connected: [["Studio headset": [
            "device_productID": 0x200A,
            "device_vendorID": 0x004C,
            "device_batteryLevel": 0
        ]]])
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(main: 0))
    }

    func testKnownProductIDWithoutVendorIsSupported() throws {
        let data = try bluetoothData(connected: [["My headphones": [
            "device_productID": "8202",
            "device_batteryLevelMain": 100
        ]]])
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(main: 100))
    }

    func testUnknownOrNonAppleProductIDIsNotEnoughToIdentifyAirPods() throws {
        let entries: [[String: Any]] = [
            ["Unknown headphones": ["device_productID": "0xFFFF", "device_vendorID": "0x004C", "device_batteryLevelMain": 80]],
            ["Other vendor": ["device_productID": "0x200A", "device_vendorID": "0x1234", "device_batteryLevelMain": 80]],
            ["Bad identifier": ["device_productID": true, "device_batteryLevelMain": 80]],
            ["Bad vendor": ["device_productID": "0x200A", "device_vendorID": true, "device_batteryLevelMain": 80]],
            ["Beats Studio Pro": ["device_productID": "0x2017", "device_vendorID": "0x004C", "device_batteryLevelMain": 80]]
        ]
        XCTAssertNil(BatteryDataParser.airPods(from: try bluetoothData(connected: entries)))
    }

    func testSplitReadingsDoNotOverrideContradictoryDeviceIdentity() throws {
        for details: [String: Any] in [
            ["device_vendorID": "0x1234"],
            ["device_vendorID": "0x004C", "device_productID": "0x2012"], // Beats Fit Pro
            ["device_vendorID": "0x004C", "device_productID": "0x200B"], // Powerbeats Pro
            ["device_productID": "0xFFFF"]
        ] {
            var details = details
            details["device_batteryLevelLeft"] = 90
            details["device_batteryLevelRight"] = 85
            let data = try bluetoothData(connected: [["Renamed earbuds": details]])
            XCTAssertNil(BatteryDataParser.airPods(from: data))
        }
        let beats = try bluetoothData(connected: [["Beats Fit Pro": ["device_batteryLevelLeft": 90]]])
        XCTAssertNil(BatteryDataParser.airPods(from: beats))
    }

    func testIgnoresUnrelatedMiceKeyboardsAndIPads() throws {
        let data = try bluetoothData(connected: [
            ["Magic Mouse": ["device_batteryLevelMain": 99, "device_minorType": "Mouse"]],
            ["Magic Keyboard": ["device_batteryLevelMain": 99, "device_minorType": "Keyboard"]],
            ["iPad": ["device_batteryLevelMain": 99, "device_vendorID": "0x004C", "device_productID": "0x0000"]],
            ["AirPods mouse": ["device_batteryLevelMain": 99, "device_minorType": "Mouse"]],
            ["AirPods computer": ["device_batteryLevelMain": 99, "device_majorType": "Computer"]]
        ])
        XCTAssertNil(BatteryDataParser.airPods(from: data))
    }

    func testDisconnectedAndTopLevelCachedReadingsAreNeverUsed() throws {
        let disconnected = ["AirPods": ["device_batteryLevelLeft": "84%"]]
        XCTAssertNil(BatteryDataParser.airPods(from: try bluetoothData(disconnected: [disconnected])))
        let cached = try JSONSerialization.data(withJSONObject: [
            "device_connected": [disconnected],
            "SPBluetoothDataType": [["device_not_connected": [disconnected]]]
        ])
        XCTAssertNil(BatteryDataParser.airPods(from: cached))
    }

    func testDisconnectedReadingsDoNotFillMissingConnectedComponents() throws {
        let data = try bluetoothData(
            connected: [["AirPods": ["device_address": "same", "device_batteryLevelLeft": 84]]],
            disconnected: [["AirPods": ["device_address": "same", "device_batteryLevelRight": 73, "device_batteryLevelCase": 63]]]
        )
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(left: 84))
    }

    func testNeverMergesDifferentConnectedDevices() throws {
        let entries: [[String: Any]] = [
            ["Alice’s AirPods": ["device_batteryLevelLeft": 90]],
            ["Zoe’s AirPods": ["device_batteryLevelRight": 73, "device_batteryLevelCase": 63]]
        ]
        for devices in [entries, Array(entries.reversed())] {
            XCTAssertEqual(BatteryDataParser.airPods(from: try bluetoothData(connected: devices)), AirPodsBattery(right: 73, caseLevel: 63))
        }
    }

    func testSingleHeadsetReadingIsPreferredToCaseOnlyCandidate() throws {
        let data = try bluetoothData(connected: [
            ["A AirPods": ["device_batteryLevelCase": 63]],
            ["Z AirPods Max": ["device_batteryLevelMain": 58]]
        ])
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(main: 58))
    }

    func testEqualRichnessUsesDeterministicNameAndAddressTieBreakers() throws {
        let entries: [[String: Any]] = [
            ["Z AirPods": ["device_address": "01", "device_batteryLevelLeft": 99]],
            ["A AirPods": ["device_address": "02", "device_batteryLevelRight": 73]],
            ["A AirPods": ["device_address": "01", "device_batteryLevelLeft": 84]]
        ]
        for devices in [entries, Array(entries.reversed())] {
            XCTAssertEqual(BatteryDataParser.airPods(from: try bluetoothData(connected: devices)), AirPodsBattery(left: 84))
        }
    }

    func testZeroReadingsAreValidAndInvalidComponentsBecomeUnavailable() throws {
        let data = try bluetoothData(connected: [["AirPods": [
            "device_batteryLevelLeft": "0 %",
            "device_batteryLevelRight": false,
            "device_batteryLevelCase": "101%",
            "device_batteryLevelMain": 40.5
        ]]])
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(left: 0))
    }

    func testMissingOrEntirelyInvalidAirPodsReadingsReturnNil() throws {
        for details: [String: Any] in [[:], [
            "device_batteryLevelLeft": NSNull(),
            "device_batteryLevelRight": true,
            "device_batteryLevelCase": "garbage",
            "device_batteryLevelMain": -1
        ]] {
            XCTAssertNil(BatteryDataParser.airPods(from: try bluetoothData(connected: [["AirPods": details]])))
        }
    }

    func testMalformedBluetoothDataReturnsNil() {
        for value in ["", "not JSON", "{", "[]", "null", "{}", "{\"SPBluetoothDataType\":{}}", "{\"SPBluetoothDataType\":[{\"device_connected\":{}}]}"] {
            XCTAssertNil(BatteryDataParser.airPods(from: Data(value.utf8)), value)
        }
    }

    func testMalformedEntriesDoNotHideValidDevicesOnAnotherController() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "SPBluetoothDataType": [
                NSNull(),
                ["device_connected": "invalid"],
                ["device_connected": [false, ["AirPods": 99]]],
                ["device_connected": [["AirPods": ["device_batteryLevelLeft": "84%"]]]]
            ] as [Any]
        ])
        XCTAssertEqual(BatteryDataParser.airPods(from: data), AirPodsBattery(left: 84))
    }

    func testIPhoneBatteryDomainXMLPlist() {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BatteryCurrentCapacity</key><integer>50</integer>
            <key>BatteryIsCharging</key><true/>
            <key>ExternalConnected</key><true/>
            <key>FullyCharged</key><false/>
        </dict>
        </plist>
        """.utf8)
        XCTAssertEqual(BatteryDataParser.iPhone(from: data), 50)
    }

    func testIPhoneAcceptsZeroHundredAndPercentageStringsInPlists() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            for (input, expected): (Any, Int) in [(0, 0), (100, 100), ("63\u{00A0}%", 63)] {
                let data = try PropertyListSerialization.data(fromPropertyList: ["BatteryCurrentCapacity": input], format: format, options: 0)
                XCTAssertEqual(BatteryDataParser.iPhone(from: data), expected)
            }
        }
    }

    func testIPhoneRejectsInvalidBatteryValues() throws {
        for value: Any in [true, false, -1, 101, 50.5, "invalid", [50], ["value": 50]] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["BatteryCurrentCapacity": value], format: .xml, options: 0)
            XCTAssertNil(BatteryDataParser.iPhone(from: data), "\(value)")
        }
    }

    func testIPhoneRequiresDirectBatteryDomainKeyAndDictionaryRoot() throws {
        let invalid: [Any] = [
            ["BatteryLevel": 50],
            ["com.apple.mobile.battery": ["BatteryCurrentCapacity": 50]],
            ["DeviceName": "iPhone", "OtherDomain": ["BatteryCurrentCapacity": 50]],
            [["BatteryCurrentCapacity": 50]],
            [:]
        ]
        for root in invalid {
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            XCTAssertNil(BatteryDataParser.iPhone(from: data))
        }
    }

    func testIPhoneRejectsMalformedPlistsAndJSON() {
        for value in ["", "<plist>", "not a plist", "{\"BatteryCurrentCapacity\":50}"] {
            XCTAssertNil(BatteryDataParser.iPhone(from: Data(value.utf8)))
        }
    }

    private func bluetoothData(connected: [[String: Any]] = [], disconnected: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "SPBluetoothDataType": [["device_connected": connected, "device_not_connected": disconnected]]
        ])
    }
}

final class BatterySnapshotTests: XCTestCase {
    func testDefaultsAreExplicitlyUnavailable() {
        let snapshot = BatterySnapshot()
        XCTAssertNil(snapshot.mac)
        XCTAssertNil(snapshot.iPhone)
        XCTAssertNil(snapshot.airPods)
        XCTAssertEqual(snapshot.text, "Mac N/A · iPhone N/A · AirPods N/A")
        XCTAssertEqual(snapshot.accessibilityText, "Mac unavailable, iPhone unavailable, AirPods unavailable")
    }

    func testFullSnapshotTextAndAccessibility() {
        let snapshot = BatterySnapshot(mac: 80, iPhone: 50, airPods: AirPodsBattery(left: 84, right: 73, caseLevel: 63))
        XCTAssertEqual(snapshot.text, "Mac 80% · iPhone 50% · AirPods L 84% R 73% C 63%")
        XCTAssertEqual(snapshot.accessibilityText, "Mac 80 percent, iPhone 50 percent, AirPods left 84 percent, right 73 percent, case 63 percent")
    }

    func testPartialEarbudReadingExplicitlyIncludesMissingRightAndCase() {
        let snapshot = BatterySnapshot(airPods: AirPodsBattery(left: 0))
        XCTAssertEqual(snapshot.text, "Mac N/A · iPhone N/A · AirPods L 0% R N/A C N/A")
        XCTAssertEqual(snapshot.accessibilityText, "Mac unavailable, iPhone unavailable, AirPods left 0 percent, right unavailable, case unavailable")
    }

    func testCaseOnlyReadingExplicitlyIncludesMissingEarbuds() {
        let snapshot = BatterySnapshot(airPods: AirPodsBattery(caseLevel: 63))
        XCTAssertEqual(snapshot.text, "Mac N/A · iPhone N/A · AirPods L N/A R N/A C 63%")
        XCTAssertEqual(snapshot.accessibilityText, "Mac unavailable, iPhone unavailable, AirPods left unavailable, right unavailable, case 63 percent")
    }

    func testMainOnlyAirPodsMaxDoesNotInventEarbudComponents() {
        let snapshot = BatterySnapshot(mac: 0, iPhone: 100, airPods: AirPodsBattery(main: 58))
        XCTAssertEqual(snapshot.text, "Mac 0% · iPhone 100% · AirPods 58%")
        XCTAssertEqual(snapshot.accessibilityText, "Mac 0 percent, iPhone 100 percent, AirPods 58 percent")
    }

    func testSplitReadingsTakePrecedenceOverGenericMainReading() {
        let snapshot = BatterySnapshot(airPods: AirPodsBattery(left: 84, right: 73, main: 80))
        XCTAssertEqual(snapshot.text, "Mac N/A · iPhone N/A · AirPods L 84% R 73% C N/A")
    }

    func testInvalidModelPercentagesBecomeNilInsteadOfClamping() {
        let battery = AirPodsBattery(left: -1, right: 101, caseLevel: Int.min, main: Int.max)
        XCTAssertEqual(battery, AirPodsBattery())
        let snapshot = BatterySnapshot(mac: -1, iPhone: 101, airPods: battery)
        XCTAssertNil(snapshot.mac)
        XCTAssertNil(snapshot.iPhone)
        XCTAssertEqual(snapshot.text, "Mac N/A · iPhone N/A · AirPods N/A")
        XCTAssertEqual(snapshot.accessibilityText, "Mac unavailable, iPhone unavailable, AirPods unavailable")
    }

    func testHeadsetSummaryUsesLowerAvailableEarbudNotAverageOrCase() {
        XCTAssertEqual(AirPodsBattery(left: 74, right: 56, caseLevel: 10).headsetPercentage, 56)
        XCTAssertEqual(AirPodsBattery(left: 56, right: 74, caseLevel: 100).headsetPercentage, 56)
        XCTAssertEqual(AirPodsBattery(left: 0, right: 100).headsetPercentage, 0)
        XCTAssertEqual(AirPodsBattery(left: 100, right: 100).headsetPercentage, 100)
        XCTAssertEqual(AirPodsBattery(left: 74, main: 90).headsetPercentage, 74)
    }

    func testHeadsetSummaryHandlesPartialMissingAndInvalidReadings() {
        XCTAssertEqual(AirPodsBattery(left: 74).headsetPercentage, 74)
        XCTAssertEqual(AirPodsBattery(right: 56).headsetPercentage, 56)
        XCTAssertEqual(AirPodsBattery(main: 80).headsetPercentage, 80)
        XCTAssertEqual(AirPodsBattery(left: -1, right: 56).headsetPercentage, 56)
        XCTAssertNil(AirPodsBattery(caseLevel: 63).headsetPercentage)
        XCTAssertNil(AirPodsBattery(left: -1, right: 101, main: 101).headsetPercentage)
        XCTAssertNil(AirPodsBattery().headsetPercentage)
    }

    func testEveryModelFieldPreservesBoundaryValues() {
        for value in [0, 100] {
            let battery = AirPodsBattery(left: value, right: value, caseLevel: value, main: value)
            let snapshot = BatterySnapshot(mac: value, iPhone: value, airPods: battery)
            XCTAssertEqual(snapshot.mac, value)
            XCTAssertEqual(snapshot.iPhone, value)
            XCTAssertEqual(snapshot.airPods?.left, value)
            XCTAssertEqual(snapshot.airPods?.right, value)
            XCTAssertEqual(snapshot.airPods?.caseLevel, value)
            XCTAssertEqual(snapshot.airPods?.main, value)
        }
    }
}
