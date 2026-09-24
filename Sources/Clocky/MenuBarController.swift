import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let settings: SettingsStore
    private let overlays: OverlayManager
    private let showSettings: () -> Void
    private let statusItem: NSStatusItem
    private let visibilityItem = NSMenuItem(title: "Show Clocks", action: #selector(toggleVisibility), keyEquivalent: "")
    private let positioningItem = NSMenuItem(title: "Move Clocks…", action: #selector(togglePositioning), keyEquivalent: "")

    init(settings: SettingsStore, overlays: OverlayManager, showSettings: @escaping () -> Void) {
        self.settings = settings
        self.overlays = overlays
        self.showSettings = showSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Clocky")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "C" }
            button.toolTip = "Clocky - clock overlay"
            button.setAccessibilityLabel("Clocky")
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for item in [visibilityItem, positioningItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(item("Reset Positions", action: #selector(resetPositions)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Clocky", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        visibilityItem.state = settings.preferences.isVisible ? .on : .off
        positioningItem.title = overlays.isPositioning ? "Lock Positions" : "Move Clocks…"
        positioningItem.state = overlays.isPositioning ? .on : .off
    }

    @objc private func toggleVisibility() { settings.update { $0.isVisible.toggle() } }
    @objc private func togglePositioning() { overlays.setPositioning(!overlays.isPositioning) }
    @objc private func resetPositions() { settings.resetPositions() }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func stop() { NSStatusBar.system.removeStatusItem(statusItem) }
}
