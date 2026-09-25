import ClockyCore
import SwiftUI

extension RGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    init(_ color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }
}

struct ClockView: View {
    let text: String
    let preferences: ClockPreferences
    let isPositioning: Bool
    let battery: BatterySnapshot

    init(
        text: String, preferences: ClockPreferences, isPositioning: Bool,
        battery: BatterySnapshot = BatterySnapshot()
    ) {
        self.text = text
        self.preferences = preferences
        self.isPositioning = isPositioning
        self.battery = battery
    }

    var body: some View {
        let layout = ClockContentLayout(text: text, battery: battery, preferences: preferences)
        ClockContent(layout: layout)
            .foregroundStyle(preferences.textColor.swiftUIColor)
            .padding(.horizontal, ClockContentLayout.horizontalPadding)
            .padding(.vertical, ClockContentLayout.verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                preferences.backgroundColor.swiftUIColor
                    .opacity(preferences.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                if isPositioning {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(layout.accessibilityLabel)
            .accessibilityValue(layout.accessibilityValue)
            .help(
                isPositioning
                    ? "Drag to reposition. Choose Lock Positions from the Clocky menu when done."
                    : (layout.columns.isEmpty
                        ? "Current time"
                        : "Battery icons: Mac above iPhone on the left; AirPods above its case on the right. AirPods shows the lower available earbud charge; '~' means approximate and '-' means unavailable. Full readings and optional Bluetooth fallback are in Settings.")
            )
    }
}
