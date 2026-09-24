import Foundation
import XCTest
@testable import ClockyCore

final class ClockPreferencesTests: XCTestCase {
    func testDefaults() {
        let preferences = ClockPreferences()
        XCTAssertTrue(preferences.isVisible)
        XCTAssertFalse(preferences.showsSeconds)
        XCTAssertEqual(preferences.timeFormat, .system)
        XCTAssertNil(preferences.fontName)
        XCTAssertEqual(preferences.fontSize, 28)
        XCTAssertEqual(preferences.textColor, .white)
        XCTAssertEqual(preferences.backgroundColor, .black)
        XCTAssertEqual(preferences.backgroundOpacity, 0.65)
        XCTAssertTrue(preferences.positions.isEmpty)
        XCTAssertEqual(preferences.sanitized(), preferences)
        XCTAssertEqual(DisplayPosition.topRight, DisplayPosition(x: 1, y: 1))
    }

    func testTimeFormatsHaveStableUniqueIdentitiesAndTitles() throws {
        XCTAssertEqual(TimeFormat.allCases, [.system, .twelveHour, .twentyFourHour])
        XCTAssertEqual(Set(TimeFormat.allCases.map(\.id)).count, 3)
        for format in TimeFormat.allCases {
            XCTAssertEqual(format.id, format.rawValue)
            XCTAssertFalse(format.title.isEmpty)
            XCTAssertEqual(try JSONDecoder().decode(TimeFormat.self, from: JSONEncoder().encode(format)), format)
        }
    }

    func testJSONRoundTripPreservesEverySetting() throws {
        var preferences = ClockPreferences()
        preferences.isVisible = false
        preferences.showsSeconds = true
        preferences.timeFormat = .twentyFourHour
        preferences.fontName = "Helvetica-Bold"
        preferences.fontSize = 42
        preferences.textColor = RGBAColor(red: 0.2, green: 0.4, blue: 0.6)
        preferences.backgroundColor = RGBAColor(red: 0.7, green: 0.8, blue: 0.9)
        preferences.backgroundOpacity = 0.25
        preferences.positions = ["display-1": DisplayPosition(x: 0.25, y: 0.75), "display-2": .topRight]
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(ClockPreferences.self, from: data), preferences)
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let color = try XCTUnwrap(dictionary["textColor"] as? [String: Any])
        XCTAssertEqual(Set(color.keys), Set(["red", "green", "blue"]))
    }

    func testPropertyListRoundTrip() throws {
        var preferences = ClockPreferences()
        preferences.positions = ["external": DisplayPosition(x: 0.3, y: 0.7)]
        let data = try PropertyListEncoder().encode(preferences)
        XCTAssertEqual(try PropertyListDecoder().decode(ClockPreferences.self, from: data), preferences)
    }

    func testEmptyAndPartialPreferencesUseDefaults() throws {
        XCTAssertEqual(try decode("{}"), ClockPreferences())
        var expected = ClockPreferences()
        expected.showsSeconds = true
        expected.fontSize = 36
        XCTAssertEqual(try decode(#"{"showsSeconds":true,"fontSize":36}"#), expected)
    }

    func testNullMalformedAndUnknownFieldsAreTolerated() throws {
        let json = #"{"isVisible":"yes","showsSeconds":null,"timeFormat":"futureFormat","fontSize":[],"textColor":{"red":1},"backgroundColor":false,"backgroundOpacity":"opaque","positions":[],"futureSetting":true}"#
        XCTAssertEqual(try decode(json), ClockPreferences())
    }

    func testInvalidFieldDoesNotDiscardOtherSettings() throws {
        let preferences = try decode(#"{"isVisible":false,"timeFormat":"unknown","fontSize":64,"positions":{"screen":{"x":0.4,"y":0.8}}}"#)
        XCTAssertFalse(preferences.isVisible)
        XCTAssertEqual(preferences.timeFormat, .system)
        XCTAssertEqual(preferences.fontSize, 64)
        XCTAssertEqual(preferences.positions["screen"], DisplayPosition(x: 0.4, y: 0.8))
    }

    func testMalformedDocumentStillThrows() {
        XCTAssertThrowsError(try decode("[1,2,3]"))
        XCTAssertThrowsError(try decode("not JSON"))
    }

    func testSanitizationClampsAllFiniteRangesWithoutMutatingOriginal() {
        var preferences = ClockPreferences()
        preferences.fontSize = 500
        preferences.backgroundOpacity = -1
        preferences.textColor = RGBAColor(red: -2, green: 0.3, blue: 7)
        preferences.backgroundColor = RGBAColor(red: 4, green: -1, blue: 0.6)
        preferences.positions = ["screen": DisplayPosition(x: -0.1, y: 1.2)]
        let result = preferences.sanitized()
        XCTAssertEqual(result.fontSize, 96)
        XCTAssertEqual(result.backgroundOpacity, 0)
        XCTAssertEqual(result.textColor, RGBAColor(red: 0, green: 0.3, blue: 1))
        XCTAssertEqual(result.backgroundColor, RGBAColor(red: 1, green: 0, blue: 0.6))
        XCTAssertEqual(result.positions["screen"], DisplayPosition(x: 0, y: 1))
        XCTAssertEqual(preferences.fontSize, 500)
        XCTAssertEqual(result.sanitized(), result)
        preferences.fontSize = -10
        preferences.backgroundOpacity = 8
        XCTAssertEqual(preferences.sanitized().fontSize, 14)
        XCTAssertEqual(preferences.sanitized().backgroundOpacity, 1)
    }

    func testNonfiniteValuesUseContextualDefaultsAndCanBeEncoded() throws {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var preferences = ClockPreferences()
            preferences.fontSize = invalid
            preferences.backgroundOpacity = invalid
            preferences.textColor = RGBAColor(red: invalid, green: invalid, blue: invalid)
            preferences.backgroundColor = RGBAColor(red: invalid, green: invalid, blue: invalid)
            preferences.positions = ["screen": DisplayPosition(x: invalid, y: invalid)]
            var expected = ClockPreferences()
            expected.positions = ["screen": .topRight]
            let result = preferences.sanitized()
            XCTAssertEqual(result, expected)
            XCTAssertNoThrow(try JSONEncoder().encode(result))
        }
    }

    func testSanitizationPreservesBoundaryValuesAndNonNumericSettings() {
        for fontSize in [14.0, 96.0] {
            for opacity in [0.0, 1.0] {
                var preferences = ClockPreferences()
                preferences.isVisible = false
                preferences.showsSeconds = true
                preferences.timeFormat = .twelveHour
                preferences.fontSize = fontSize
                preferences.backgroundOpacity = opacity
                preferences.textColor = .black
                preferences.backgroundColor = .white
                preferences.positions = ["screen": DisplayPosition(x: 0, y: 1)]
                XCTAssertEqual(preferences.sanitized(), preferences)
            }
        }
    }

    func testDecodedOutOfRangeValuesCanBeSanitized() throws {
        let preferences = try decode(#"{"fontSize":3,"backgroundOpacity":2,"positions":{"screen":{"x":-1,"y":2}}}"#).sanitized()
        XCTAssertEqual(preferences.fontSize, 14)
        XCTAssertEqual(preferences.backgroundOpacity, 1)
        XCTAssertEqual(preferences.positions["screen"], DisplayPosition(x: 0, y: 1))
    }

    func testOlderPreferencesRetainSystemFont() throws {
        let preferences = try decode(#"{"fontSize":40,"showsSeconds":true}"#)
        XCTAssertNil(preferences.fontName)
        XCTAssertEqual(preferences.fontSize, 40)
        XCTAssertTrue(preferences.showsSeconds)
    }

    func testMalformedFontNamesUseSystemFont() throws {
        for value in ["null", "42", "[]", "{}"] {
            XCTAssertNil(try decode("{\"fontName\":\(value)}").fontName)
        }
    }

    func testFontNameSanitizationPreservesUnknownInstalledNamesForFallback() {
        var preferences = ClockPreferences()
        preferences.fontName = " \n "
        XCTAssertNil(preferences.sanitized().fontName)
        preferences.fontName = " Custom-Font-Name "
        XCTAssertEqual(preferences.sanitized().fontName, "Custom-Font-Name")
    }

    private func decode(_ json: String) throws -> ClockPreferences {
        try JSONDecoder().decode(ClockPreferences.self, from: Data(json.utf8))
    }
}
