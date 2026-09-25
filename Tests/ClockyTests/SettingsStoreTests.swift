import ClockyCore
import XCTest
@testable import Clocky

final class SettingsStoreTests: XCTestCase {
    @MainActor
    private func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let suite = "Clocky.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    @MainActor
    func testNewStoreUsesDefaults() async {
        withDefaults { defaults in
            XCTAssertEqual(SettingsStore(defaults: defaults).preferences, ClockPreferences())
        }
    }

    @MainActor
    func testUpdatesPersistAcrossStoreInstances() async {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.update {
                $0.isVisible = false
                $0.showsSeconds = true
                $0.showsMacBattery = false
                $0.showsIPhoneBattery = true
                $0.showsAirPodsBattery = false
                $0.showsAirPodsCaseBattery = true
                $0.timeFormat = .twentyFourHour
                $0.fontName = "Helvetica-Bold"
                $0.fontSize = 42
                $0.textColor = RGBAColor(red: 0.2, green: 0.4, blue: 0.6)
                $0.backgroundOpacity = 0.35
                $0.positions["test-screen"] = DisplayPosition(x: 0.25, y: 0.75)
            }
            XCTAssertEqual(SettingsStore(defaults: defaults).preferences, store.preferences)
        }
    }

    @MainActor
    func testEveryBatteryVisibilitySelectionPersistsAcrossStoreInstances() async throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            let fields: [WritableKeyPath<ClockPreferences, Bool>] = [
                \.showsMacBattery, \.showsIPhoneBattery, \.showsAirPodsBattery, \.showsAirPodsCaseBattery
            ]
            for selection in 0..<16 {
                var expected = ClockPreferences()
                for (index, field) in fields.enumerated() {
                    expected[keyPath: field] = selection & (1 << index) != 0
                }
                store.update { preferences in
                    for field in fields {
                        preferences[keyPath: field] = expected[keyPath: field]
                    }
                }
                XCTAssertEqual(store.preferences, expected, "Selection \(selection)")
                let persistedData = try XCTUnwrap(defaults.data(forKey: "clockPreferences.v1"))
                XCTAssertEqual(try JSONDecoder().decode(ClockPreferences.self, from: persistedData), expected)
                XCTAssertEqual(SettingsStore(defaults: defaults).preferences, expected)
            }
        }
    }

    @MainActor
    func testOlderSavedPreferencesEnableBatterySlotsWithoutDiscardingSettings() async {
        withDefaults { defaults in
            let json = #"{"isVisible":false,"showsSeconds":true,"fontName":"Helvetica-Bold","fontSize":40,"positions":{"screen":{"x":0.25,"y":0.75}}}"#
            defaults.set(Data(json.utf8), forKey: "clockPreferences.v1")
            var expected = ClockPreferences()
            expected.isVisible = false
            expected.showsSeconds = true
            expected.fontName = "Helvetica-Bold"
            expected.fontSize = 40
            expected.positions = ["screen": DisplayPosition(x: 0.25, y: 0.75)]
            let store = SettingsStore(defaults: defaults)
            XCTAssertEqual(store.preferences, expected)
            store.update { $0.showsAirPodsCaseBattery = false }
            expected.showsAirPodsCaseBattery = false
            XCTAssertEqual(SettingsStore(defaults: defaults).preferences, expected)
        }
    }

    @MainActor
    func testMalformedSavedBatteryFieldsDoNotDiscardOtherVisibilityChoices() async {
        withDefaults { defaults in
            let json = #"{"showsMacBattery":null,"showsIPhoneBattery":false,"showsAirPodsBattery":"false","showsAirPodsCaseBattery":false,"fontSize":40,"showsSeconds":true}"#
            defaults.set(Data(json.utf8), forKey: "clockPreferences.v1")
            var expected = ClockPreferences()
            expected.showsIPhoneBattery = false
            expected.showsAirPodsCaseBattery = false
            expected.fontSize = 40
            expected.showsSeconds = true
            XCTAssertEqual(SettingsStore(defaults: defaults).preferences, expected)
        }
    }

    @MainActor
    func testReturningToSystemFontPersistsNilSelection() async {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.update { $0.fontName = "Helvetica-Bold" }
            store.update { $0.fontName = nil }
            XCTAssertNil(SettingsStore(defaults: defaults).preferences.fontName)
        }
    }

    @MainActor
    func testResetPositionsPreservesOtherSettings() async {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.update {
                $0.showsSeconds = true
                $0.showsMacBattery = false
                $0.showsIPhoneBattery = false
                $0.showsAirPodsBattery = false
                $0.showsAirPodsCaseBattery = false
                $0.fontSize = 40
                $0.positions["screen"] = DisplayPosition(x: 0, y: 0)
            }
            var expected = store.preferences
            expected.positions = [:]
            store.resetPositions()
            XCTAssertTrue(store.preferences.positions.isEmpty)
            XCTAssertTrue(store.preferences.showsSeconds)
            XCTAssertFalse(store.preferences.showsAnyBattery)
            XCTAssertEqual(store.preferences.fontSize, 40)
            XCTAssertEqual(store.preferences, expected)
            XCTAssertEqual(SettingsStore(defaults: defaults).preferences, expected)
        }
    }

    @MainActor
    func testInvalidUpdatesAreSanitizedBeforePersistence() async {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.update {
                $0.fontSize = .nan
                $0.backgroundOpacity = -1
                $0.textColor.red = 12
                $0.showsMacBattery = false
                $0.showsAirPodsCaseBattery = false
            }
            XCTAssertFalse(store.preferences.showsMacBattery)
            XCTAssertTrue(store.preferences.showsIPhoneBattery)
            XCTAssertTrue(store.preferences.showsAirPodsBattery)
            XCTAssertFalse(store.preferences.showsAirPodsCaseBattery)
            XCTAssertEqual(store.preferences.fontSize, 28)
            XCTAssertEqual(store.preferences.backgroundOpacity, 0)
            XCTAssertEqual(store.preferences.textColor.red, 1)
            XCTAssertEqual(SettingsStore(defaults: defaults).preferences, store.preferences)
        }
    }

    @MainActor
    func testCorruptPreferencesRecoverToDefaults() async {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: "clockPreferences.v1")
            XCTAssertEqual(SettingsStore(defaults: defaults).preferences, ClockPreferences())
        }
    }

    @MainActor
    func testIdenticalUpdateDoesNotPublishAgain() async {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            var updates = 0
            let token = store.$preferences.dropFirst().sink { _ in updates += 1 }
            store.update { $0.fontSize = 28 }
            XCTAssertEqual(updates, 0)
            store.update { $0.fontSize = 32 }
            XCTAssertEqual(updates, 1)
            withExtendedLifetime(token) {}
        }
    }
}
