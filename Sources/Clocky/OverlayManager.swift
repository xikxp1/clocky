import AppKit
import ClockyCore
import Combine

@MainActor
final class OverlayManager: ObservableObject {
    @Published private(set) var isPositioning = false
    private let settings: SettingsStore
    private let time: TimeService
    private var panels: [String: ClockPanel] = [:]
    private var screens: [String: NSScreen] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(settings: SettingsStore, time: TimeService) {
        self.settings = settings
        self.time = time
        settings.$preferences.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preferences in
                guard let self else { return }
                if !preferences.isVisible { self.isPositioning = false }
                self.refresh()
            }
            .store(in: &subscriptions)
        time.$text.dropFirst()
            // Main-queue delivery continues during menu/event tracking, unlike
            // scheduling in the main run loop's default mode.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)

        observe(NSApplication.didChangeScreenParametersNotification, center: .default, rebuild: true)
        observe(NSFont.fontSetChangedNotification, center: .default, rebuild: false)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace, rebuild: false)
        observe(NSWorkspace.didWakeNotification, center: workspace, rebuild: true)
        observe(NSWorkspace.screensDidWakeNotification, center: workspace, rebuild: true)
        rebuildPanels()
    }

    func setPositioning(_ enabled: Bool) {
        if enabled { settings.update { $0.isVisible = true } }
        isPositioning = enabled
        refresh()
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, rebuild: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if rebuild { self.rebuildPanels() }
                else { self.refresh(bringForward: true) }
            }
        }
        observers.append((center, token))
    }

    private func rebuildPanels() {
        var current: [String: NSScreen] = [:]
        let connected = Set(NSScreen.screens.compactMap(Self.displayID))
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(screen) else { continue }
            // Mirrored displays share a logical desktop. Do not stack duplicate
            // clocks if NSScreen happens to report both members of a mirror set.
            let mirrorSource = CGDisplayMirrorsDisplay(displayID)
            if mirrorSource != kCGNullDirectDisplay, connected.contains(mirrorSource) { continue }
            current[Self.identifier(displayID)] = screen
        }
        for key in Array(panels.keys) where current[key] == nil {
            panels.removeValue(forKey: key)?.close()
        }
        screens = current
        for (key, _) in screens where panels[key] == nil {
            let panel = ClockPanel(text: time.text, preferences: settings.preferences)
            panel.onPositionChanged = { [weak self] frame in
                guard let self, let screen = self.screens[key] else { return }
                let position = OverlayGeometry.position(for: frame, in: Self.usableFrame(screen))
                self.settings.update { $0.positions[key] = position }
            }
            panels[key] = panel
        }
        refresh(bringForward: true)
    }

    private func refresh(bringForward: Bool = false) {
        let preferences = settings.preferences
        let size = ClockPanel.preferredSize(text: time.text, preferences: preferences)
        for (key, panel) in panels {
            guard let screen = screens[key] else { continue }
            let usable = Self.usableFrame(screen)
            panel.render(text: time.text, preferences: preferences, positioning: isPositioning, visibleFrame: usable)
            // A tick must not snap a panel back to its saved position mid-drag.
            if !panel.isDragging {
                let frame = OverlayGeometry.frame(
                    size: size, visibleFrame: usable,
                    position: preferences.positions[key] ?? .topRight
                )
                if panel.frame != frame { panel.setFrame(frame, display: true) }
            }
            if preferences.isVisible {
                if bringForward || !panel.isVisible { panel.orderFrontRegardless() }
            } else {
                panel.orderOut(nil)
            }
        }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func identifier(_ displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) {
            return string as String
        }
        return "display-\(displayID)"
    }

    private static func usableFrame(_ screen: NSScreen) -> CGRect {
        // visibleFrame excludes the Dock and menu bar. Also respect safe areas
        // when the menu bar is automatically hidden on a notched display.
        let insets = screen.safeAreaInsets
        let safe = CGRect(
            x: screen.frame.minX + insets.left,
            y: screen.frame.minY + insets.bottom,
            width: max(0, screen.frame.width - insets.left - insets.right),
            height: max(0, screen.frame.height - insets.top - insets.bottom)
        )
        let intersection = screen.visibleFrame.intersection(safe)
        return intersection.isNull ? screen.visibleFrame : intersection
    }

    /// Local diagnostic only. Does not establish cross-app/full-screen behavior.
    func smokeCheck() -> Bool {
        !panels.isEmpty && panels.allSatisfy { key, panel in
            guard let screen = screens[key] else { return false }
            return panel.isVisible && panel.ignoresMouseEvents && !panel.canBecomeKey
                && !panel.canBecomeMain && !panel.hidesOnDeactivate
                && panel.collectionBehavior.contains(.canJoinAllApplications)
                && Self.usableFrame(screen).contains(panel.frame)
        }
    }

    func stop() {
        subscriptions.removeAll()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
}
