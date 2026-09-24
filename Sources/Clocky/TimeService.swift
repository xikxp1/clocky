import AppKit
import ClockyCore
import Combine

/// One wall-clock-aligned timer shared by every display and the settings preview.
/// No polling when all clocks are hidden or displays sleep; no accumulating counter.
@MainActor
final class TimeService: ObservableObject {
    @Published private(set) var text = ""
    private var preferences: ClockPreferences
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaysAsleep = false
    private var previewVisible = false

    init(settings: SettingsStore) {
        preferences = settings.preferences
        subscription = settings.$preferences
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in
                guard let self else { return }
                let changed = next.timeFormat != self.preferences.timeFormat
                    || next.showsSeconds != self.preferences.showsSeconds
                    || next.isVisible != self.preferences.isVisible
                self.preferences = next
                if changed { self.refresh() }
            }

        for name in [NSNotification.Name.NSSystemClockDidChange,
                     NSNotification.Name.NSSystemTimeZoneDidChange,
                     NSLocale.currentLocaleDidChangeNotification] {
            observe(name, center: .default) { $0.refresh() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(name, center: workspace) {
                $0.displaysAsleep = true
                $0.timer?.invalidate()
                $0.timer = nil
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(name, center: workspace) {
                $0.displaysAsleep = false
                $0.refresh()
            }
        }
        refresh()
    }

    private func observe(
        _ name: Notification.Name,
        center: NotificationCenter,
        action: @escaping @MainActor (TimeService) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        let now = Date()
        let nextText = ClockFormatter.string(
            at: now, format: preferences.timeFormat, showsSeconds: preferences.showsSeconds
        )
        if text != nextText { text = nextText }
        guard preferences.isVisible || previewVisible, !displaysAsleep else { return }
        // A small offset avoids an early timer fire formatting the previous second.
        let fireDate = ClockFormatter.nextUpdate(after: now, showsSeconds: preferences.showsSeconds)
            .addingTimeInterval(0.02)
        let nextTimer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        nextTimer.tolerance = preferences.showsSeconds ? 0.025 : 0.1
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }
        previewVisible = visible
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        subscription?.cancel()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }
}
