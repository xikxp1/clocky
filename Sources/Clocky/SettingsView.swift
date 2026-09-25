import ClockyCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var overlays: OverlayManager
    @ObservedObject var time: TimeService
    @ObservedObject var battery: BatteryService
    @ObservedObject var login: LoginItemManager
    @StateObject private var fonts = FontCatalog()

    private var familyBinding: Binding<String> {
        Binding(
            get: { fonts.family(for: settings.preferences.fontName) ?? "" },
            set: { family in
                settings.update {
                    $0.fontName = family.isEmpty ? nil : fonts.defaultFace(in: family)
                }
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ClockPreferences, Value>) -> Binding<
        Value
    > {
        Binding(
            get: { settings.preferences[keyPath: keyPath] },
            set: { value in settings.update { $0[keyPath: keyPath] = value } }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<ClockPreferences, RGBAColor>) -> Binding<
        Color
    > {
        Binding(
            get: { settings.preferences[keyPath: keyPath].swiftUIColor },
            set: { value in settings.update { $0[keyPath: keyPath] = RGBAColor(value) } }
        )
    }

    var body: some View {
        ScrollView {
            settingsContent
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460)
        .onAppear { fonts.refresh() }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "clock")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Clocky").font(.title2.bold())
                    Text("The time, always in sight.").foregroundStyle(.secondary)
                }
                Spacer()
            }

            ClockView(
                text: time.text, preferences: settings.preferences, isPositioning: false,
                battery: battery.snapshot
            )
            .frame(
                height: max(
                    120,
                    ClockPanel.preferredSize(
                        text: time.text, preferences: settings.preferences,
                        battery: battery.snapshot
                    ).height)
            )
            .padding(10)
            .background(
                Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 16)
            )
            .accessibilityLabel("Clock and battery preview")

            VStack(alignment: .leading, spacing: 6) {
                Text(battery.snapshot.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Detailed battery levels")
                    .accessibilityValue(battery.snapshot.accessibilityText)
                Text(
                    "Left of the clock: Mac above iPhone. Right: AirPods above their case. The AirPods percentage is the lower available earbud charge (or the headset charge for AirPods Max); case charge is separate. L/R/C above mean left, right, and case."
                )
                Text(
                    "A dash or N/A means unavailable. Primary iPhone readings need a trusted, paired device and the optional libimobiledevice helper. Optional Bluetooth fallback is configured below; ~ marks approximate AirPods readings."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Form {
                Toggle("Show clocks on all displays", isOn: binding(\.isVisible))
                Picker("Time format", selection: binding(\.timeFormat)) {
                    ForEach(TimeFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Toggle("Show seconds", isOn: binding(\.showsSeconds))
                fontControls
                HStack {
                    Slider(value: binding(\.fontSize), in: 14...96, step: 1) { Text("Text size") }
                    Text("\(Int(settings.preferences.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                ColorPicker(
                    "Text color", selection: colorBinding(\.textColor), supportsOpacity: false)
                ColorPicker(
                    "Background color", selection: colorBinding(\.backgroundColor),
                    supportsOpacity: false)
                HStack {
                    Slider(value: binding(\.backgroundOpacity), in: 0...1) {
                        Text("Background opacity")
                    }
                    Text("\(Int((settings.preferences.backgroundOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                Section {
                    Toggle("Mac battery (top left)", isOn: binding(\.showsMacBattery))
                    Toggle("iPhone battery (bottom left)", isOn: binding(\.showsIPhoneBattery))
                    Toggle(
                        "AirPods / headset battery (top right)",
                        isOn: binding(\.showsAirPodsBattery))
                    Toggle(
                        "AirPods case battery (bottom right)",
                        isOn: binding(\.showsAirPodsCaseBattery))
                } header: {
                    Text("Battery visibility")
                } footer: {
                    Text(
                        "These switches change only the clock display and preview, not the detailed readings above. Slots keep their positions; a column disappears when both its switches are off."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                BLESettingsView(settings: settings, ble: battery.ble)
            }

            Divider()
            loginControls
            Divider()
            HStack {
                Button(overlays.isPositioning ? "Lock Positions" : "Move Clocks") {
                    overlays.setPositioning(!overlays.isPositioning)
                }
                Button("Reset Positions") { settings.resetPositions() }
                Spacer()
            }
            Text(
                overlays.isPositioning
                    ? "Drag each clock on its display, then choose Lock Positions."
                    : "Clocks pass clicks through and never take keyboard focus. Use Move Clocks to reposition them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Secure system screens and some exclusive full-screen apps may cover the clock.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var fontControls: some View {
        Picker("Font family", selection: familyBinding) {
            Text("System Default").tag("")
            ForEach(fonts.families, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        if let family = fonts.family(for: settings.preferences.fontName) {
            Picker(
                "Font face",
                selection: Binding(
                    get: { settings.preferences.fontName ?? "" },
                    set: { name in settings.update { $0.fontName = name } }
                )
            ) {
                ForEach(fonts.faces(in: family)) { face in
                    Text(face.title).tag(face.name)
                }
            }
        }
        if let name = settings.preferences.fontName, !ClockFont.isAvailable(name) {
            Text("\(name) is unavailable. Using System Default until it is installed again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Start at Login",
                isOn: Binding(
                    get: { login.isRequested },
                    set: { login.setEnabled($0) }
                )
            )
            .disabled(!login.canConfigure)

            if let reason = login.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else {
                if login.requiresApproval {
                    Text(
                        "Approval required: allow Clocky in macOS Login Items before it can start automatically."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if login.isRequested {
                    Text("Clocky will start automatically when you sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Keep Clocky.app in a stable location, such as Applications, before enabling this option."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button("Manage Login Items…") { login.openSystemSettings() }
            }
            if let error = login.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let time: TimeService
    private let battery: BatteryService
    private let login: LoginItemManager

    init(
        settings: SettingsStore, overlays: OverlayManager, time: TimeService,
        battery: BatteryService, login: LoginItemManager
    ) {
        self.time = time
        self.battery = battery
        self.login = login
        let view = SettingsView(
            settings: settings, overlays: overlays, time: time, battery: battery, login: login)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Clocky Settings"
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        window.contentView = host
        window.contentMinSize = NSSize(width: 460, height: 420)
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        window.setContentSize(NSSize(width: 500, height: max(420, min(720, availableHeight))))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        guard let window else { return }
        login.refresh()
        setPreviewVisible(true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func setPreviewVisible(_ visible: Bool) {
        time.setPreviewVisible(visible)
        battery.setPreviewVisible(visible)
    }

    func windowWillClose(_ notification: Notification) { setPreviewVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { setPreviewVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { setPreviewVisible(true) }
}
