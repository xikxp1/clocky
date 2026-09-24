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
                $0.fontSize = 40
                $0.positions["screen"] = DisplayPosition(x: 0, y: 0)
            }
            store.resetPositions()
            XCTAssertTrue(store.preferences.positions.isEmpty)
            XCTAssertTrue(store.preferences.showsSeconds)
            XCTAssertEqual(store.preferences.fontSize, 40)
            XCTAssertTrue(SettingsStore(defaults: defaults).preferences.positions.isEmpty)
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
            }
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
