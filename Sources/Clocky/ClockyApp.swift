import AppKit

@main
struct ClockyApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Also applies when running the executable directly via swift run.
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var time: TimeService!
    private var battery: BatteryService!
    private var overlays: OverlayManager!
    private var login: LoginItemManager!
    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let smokeTest = CommandLine.arguments.contains("--smoke-test")
        // Diagnostics never read or overwrite the user's preferences.
        let defaults = smokeTest
            ? UserDefaults(suiteName: "Clocky.SmokeTest.\(UUID().uuidString)")!
            : UserDefaults.standard
        settings = SettingsStore(defaults: defaults)
        time = TimeService(settings: settings)
        battery = BatteryService(settings: settings, enabled: !smokeTest)
        overlays = OverlayManager(settings: settings, time: time, battery: battery)
        login = LoginItemManager()
        installMainMenu()
        menuBar = MenuBarController(settings: settings, overlays: overlays) { [weak self] in
            self?.showSettings()
        }
        if smokeTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { exit(EXIT_FAILURE) }
                let passed = self.overlays.smokeCheck()
                print(passed ? "Clocky smoke test passed: visible, bounded, nonactivating, click-through panels."
                             : "Clocky smoke test failed: no display or an invalid overlay panel.")
                self.shutdown()
                exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let battery else { return .terminateNow }
        shutdown()
        // Do not exit before an in-flight helper has been terminated and reaped.
        Task {
            await battery.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { shutdown() }

    private func shutdown() {
        settingsWindow?.close()
        overlays?.stop()
        time?.stop()
        battery?.stop()
        login?.stop()
        menuBar?.stop()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings, overlays: overlays, time: time, battery: battery, login: login
            )
        }
        settingsWindow?.present()
    }

    private func installMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Clocky")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Clocky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
