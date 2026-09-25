import Foundation
import XCTest

@testable import ClockyCore

final class BLEPreferencesTests: XCTestCase {
    private let airPodsID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
    private let phoneID = UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")!

    func testDefaultsDisableBLEWithoutSelectingDevices() throws {
        XCTAssertEqual(BLEPreferences(), BLEPreferences(enabled: false, airPods: nil, iPhone: nil))
        XCTAssertEqual(ClockPreferences().ble, BLEPreferences())
        XCTAssertEqual(try decodeBLE([:]), BLEPreferences())
        XCTAssertEqual(try decodeClock([:]).ble, BLEPreferences())
    }

    func testSelectionUsesUUIDIdentityRatherThanDisplayName() {
        let first = BLEDeviceSelection(id: airPodsID, name: "My device")
        let other = BLEDeviceSelection(id: phoneID, name: "My device")
        XCTAssertEqual(first.id, airPodsID)
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(BLEDeviceSelection(id: first.id, name: "Renamed").id, first.id)
    }

    func testSelectionNamesAreTrimmedBoundedAndUnicodeSafe() throws {
        XCTAssertEqual(
            BLEDeviceSelection(id: airPodsID, name: "\n\t My AirPods \u{00A0}").name, "My AirPods")
        XCTAssertEqual(BLEDeviceSelection(id: airPodsID, name: " \n\t ").name, "")
        let glyph = "👩🏽‍💻"
        let longName = "  " + String(repeating: glyph, count: 160) + "  "
        let selection = BLEDeviceSelection(id: airPodsID, name: longName)
        XCTAssertEqual(selection.name, String(repeating: glyph, count: 128))
        XCTAssertEqual(selection.name.count, 128)
        // Truncation must not leave new trailing whitespace at the boundary.
        let boundary = String(repeating: "A", count: 127) + " B"
        XCTAssertEqual(
            BLEDeviceSelection(id: airPodsID, name: boundary).name,
            String(repeating: "A", count: 127))
        let decoded = try JSONDecoder().decode(
            BLEDeviceSelection.self,
            from: json([
                "id": airPodsID.uuidString, "name": longName,
            ]))
        XCTAssertEqual(decoded, selection)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "id": airPodsID.uuidString, "name": longName,
            ], format: .binary, options: 0)
        XCTAssertEqual(
            try PropertyListDecoder().decode(BLEDeviceSelection.self, from: plist), selection)
    }

    func testSelectionsAreRememberedWhileDisabledAndRoundTripAsJSONAndPlists() throws {
        for enabled in [false, true] {
            let preferences = BLEPreferences(
                enabled: enabled,
                airPods: BLEDeviceSelection(id: airPodsID, name: "AirPods"),
                iPhone: BLEDeviceSelection(id: phoneID, name: "iPhone")
            )
            let data = try JSONEncoder().encode(preferences)
            XCTAssertEqual(try JSONDecoder().decode(BLEPreferences.self, from: data), preferences)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(fields.keys), Set(["enabled", "airPods", "iPhone"]))
            let selection = try XCTUnwrap(fields["airPods"] as? [String: Any])
            XCTAssertEqual(Set(selection.keys), Set(["id", "name"]))
            XCTAssertEqual(selection["id"] as? String, airPodsID.uuidString)
            for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = format
                XCTAssertEqual(
                    try PropertyListDecoder().decode(
                        BLEPreferences.self, from: encoder.encode(preferences)), preferences)
            }
        }
    }

    func testMissingAndNullSelectionsDecodeAsNil() throws {
        XCTAssertEqual(try decodeBLE(["enabled": true]), BLEPreferences(enabled: true))
        XCTAssertEqual(
            try decodeBLE(["enabled": true, "airPods": NSNull(), "iPhone": NSNull()]),
            BLEPreferences(enabled: true))
        let data = try JSONEncoder().encode(BLEPreferences())
        XCTAssertEqual(try JSONDecoder().decode(BLEPreferences.self, from: data), BLEPreferences())
        XCTAssertEqual(
            try PropertyListDecoder().decode(
                BLEPreferences.self, from: PropertyListEncoder().encode(BLEPreferences())),
            BLEPreferences())
    }

    func testMalformedEnabledFieldNeverOptsInOrDiscardsValidSelections() throws {
        for invalid: Any in [NSNull(), "true", 1, 0, [], [:]] {
            let decoded = try decodeBLE([
                "enabled": invalid,
                "airPods": selectionDictionary(id: airPodsID),
                "iPhone": selectionDictionary(id: phoneID),
            ])
            XCTAssertFalse(decoded.enabled)
            XCTAssertEqual(decoded.airPods?.id, airPodsID)
            XCTAssertEqual(decoded.iPhone?.id, phoneID)
        }
        let missing = try decodeBLE(["airPods": selectionDictionary(id: airPodsID)])
        XCTAssertFalse(missing.enabled)
        XCTAssertEqual(missing.airPods?.id, airPodsID)
    }

    func testMalformedSelectionsAreDiscardedIndependentlyInJSON() throws {
        let invalidSelections: [Any] = [
            NSNull(), false, 42, "AirPods", [], [:],
            ["id": "not-a-uuid", "name": "AirPods"],
            ["id": 42, "name": "AirPods"],
            ["id": true, "name": "AirPods"],
            ["id": NSNull(), "name": "AirPods"],
            ["id": [airPodsID.uuidString], "name": "AirPods"],
            ["name": "AirPods"],
            ["id": airPodsID.uuidString],
            ["id": airPodsID.uuidString, "name": NSNull()],
            ["id": airPodsID.uuidString, "name": false],
            ["id": airPodsID.uuidString, "name": []],
        ]
        for invalid in invalidSelections {
            for damagedKey in ["airPods", "iPhone"] {
                var fields: [String: Any] = [
                    "enabled": true,
                    "airPods": selectionDictionary(id: airPodsID),
                    "iPhone": selectionDictionary(id: phoneID),
                ]
                fields[damagedKey] = invalid
                let preferences = try decodeBLE(fields)
                XCTAssertTrue(preferences.enabled)
                if damagedKey == "airPods" {
                    XCTAssertNil(preferences.airPods)
                    XCTAssertEqual(preferences.iPhone?.id, phoneID)
                } else {
                    XCTAssertEqual(preferences.airPods?.id, airPodsID)
                    XCTAssertNil(preferences.iPhone)
                }
            }
        }
    }

    func testMalformedSelectionDoesNotDiscardOtherFieldsInPlists() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let fields: [String: Any] = [
                "enabled": true,
                "airPods": ["id": "invalid", "name": "AirPods"],
                "iPhone": selectionDictionary(id: phoneID),
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: fields, format: format, options: 0)
            let decoded = try PropertyListDecoder().decode(BLEPreferences.self, from: data)
            XCTAssertTrue(decoded.enabled)
            XCTAssertNil(decoded.airPods)
            XCTAssertEqual(decoded.iPhone?.id, phoneID)
        }
    }

    func testStandaloneSelectionRequiresValidUUIDAndStringName() throws {
        for id: Any in ["not-a-uuid", "", true, 7, NSNull(), [], [:]] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    BLEDeviceSelection.self, from: json(["id": id, "name": "Device"])))
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(BLEDeviceSelection.self, from: json(["name": "Device"])))
        let lowercase = try JSONDecoder().decode(
            BLEDeviceSelection.self,
            from: json([
                "id": airPodsID.uuidString.lowercased(), "name": "Device",
            ]))
        XCTAssertEqual(lowercase.id, airPodsID)
    }

    func testOlderClockJSONAndPlistsKeepTheirSettingsAndDisableBLE() throws {
        let oldSettings: [String: Any] = [
            "showsSeconds": true, "fontSize": 42, "showsMacBattery": false,
            "showsIPhoneBattery": false, "fontName": "Helvetica-Bold",
        ]
        var expected = ClockPreferences()
        expected.showsSeconds = true
        expected.fontSize = 42
        expected.showsMacBattery = false
        expected.showsIPhoneBattery = false
        expected.fontName = "Helvetica-Bold"
        XCTAssertEqual(try decodeClock(oldSettings), expected)
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: oldSettings, format: format, options: 0)
            XCTAssertEqual(
                try PropertyListDecoder().decode(ClockPreferences.self, from: data), expected)
        }
    }

    func testClockRoundTripAndSanitizationPreserveBLESelections() throws {
        var preferences = ClockPreferences()
        preferences.fontSize = 42
        preferences.ble = BLEPreferences(
            enabled: true,
            airPods: BLEDeviceSelection(id: airPodsID, name: "My AirPods"),
            iPhone: BLEDeviceSelection(id: phoneID, name: "My iPhone")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ClockPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        XCTAssertEqual(
            try PropertyListDecoder().decode(
                ClockPreferences.self, from: PropertyListEncoder().encode(preferences)), preferences
        )
        XCTAssertEqual(preferences.sanitized(), preferences)
        preferences.fontSize = .infinity
        XCTAssertEqual(preferences.sanitized().ble, preferences.ble)
        preferences.ble.enabled = false
        XCTAssertEqual(preferences.sanitized().ble.airPods?.id, airPodsID)
        XCTAssertEqual(preferences.sanitized().ble.iPhone?.id, phoneID)
    }

    func testMalformedClockBLEFieldDoesNotDiscardUnrelatedSettings() throws {
        for invalid: Any in [NSNull(), false, "enabled", 1, []] {
            let preferences = try decodeClock([
                "ble": invalid, "fontSize": 40, "showsSeconds": true,
            ])
            XCTAssertEqual(preferences.ble, BLEPreferences())
            XCTAssertEqual(preferences.fontSize, 40)
            XCTAssertTrue(preferences.showsSeconds)
        }
        let partial = try decodeClock([
            "fontSize": 40,
            "ble": [
                "enabled": true, "airPods": ["id": "bad", "name": "AirPods"],
                "iPhone": selectionDictionary(id: phoneID),
            ],
        ])
        XCTAssertTrue(partial.ble.enabled)
        XCTAssertNil(partial.ble.airPods)
        XCTAssertEqual(partial.ble.iPhone?.id, phoneID)
        XCTAssertEqual(partial.fontSize, 40)
    }

    func testUnknownFieldsDoNotOptInAndInvalidRootStillThrows() throws {
        XCTAssertEqual(try decodeBLE(["futureSetting": true]), BLEPreferences())
        XCTAssertEqual(try decodeClock(["bluetoothEnabled": true]).ble, BLEPreferences())
        for document in ["[]", "null", "true", "42", "not JSON"] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(BLEPreferences.self, from: Data(document.utf8)))
        }
    }

    private func selectionDictionary(id: UUID) -> [String: Any] {
        ["id": id.uuidString, "name": "Local device"]
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func decodeBLE(_ value: [String: Any]) throws -> BLEPreferences {
        try JSONDecoder().decode(BLEPreferences.self, from: json(value))
    }

    private func decodeClock(_ value: [String: Any]) throws -> ClockPreferences {
        try JSONDecoder().decode(ClockPreferences.self, from: json(value))
    }
}
