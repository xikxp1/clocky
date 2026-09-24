import ClockyCore
import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "clockPreferences.v1"
    private let defaults: UserDefaults
    @Published private(set) var preferences: ClockPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(ClockPreferences.self, from: data) {
            preferences = saved.sanitized()
        } else {
            preferences = ClockPreferences()
        }
    }

    func update(_ change: (inout ClockPreferences) -> Void) {
        var next = preferences
        change(&next)
        next = next.sanitized()
        guard next != preferences else { return }
        preferences = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func resetPositions() {
        update { $0.positions.removeAll() }
    }
}
