import Combine
import XCTest
@testable import Clocky

final class TimeServiceTests: XCTestCase {
    @MainActor
    func testHiddenClockDoesNotTickWithoutPreview() async {
        let suite = "Clocky.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.update { $0.isVisible = false; $0.showsSeconds = true }
        let time = TimeService(settings: store)
        defer { time.stop() }
        let update = expectation(description: "No hidden clock ticks")
        update.isInverted = true
        let token = time.$text.dropFirst().sink { _ in update.fulfill() }
        await fulfillment(of: [update], timeout: 1.2)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testVisiblePreviewTicksEvenWithHiddenOverlays() async {
        let suite = "Clocky.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.update { $0.isVisible = false; $0.showsSeconds = true }
        let time = TimeService(settings: store)
        defer { time.stop() }
        time.setPreviewVisible(true)
        let update = expectation(description: "Live preview updates")
        let token = time.$text.dropFirst().prefix(1).sink { _ in update.fulfill() }
        await fulfillment(of: [update], timeout: 2)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testClosingHiddenPreviewStopsTicks() async {
        let suite = "Clocky.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.update { $0.isVisible = false; $0.showsSeconds = true }
        let time = TimeService(settings: store)
        defer { time.stop() }
        time.setPreviewVisible(true)
        time.setPreviewVisible(false)
        let update = expectation(description: "Closing preview cancels ticks")
        update.isInverted = true
        let token = time.$text.dropFirst().sink { _ in update.fulfill() }
        await fulfillment(of: [update], timeout: 1.2)
        withExtendedLifetime(token) {}
    }
}
