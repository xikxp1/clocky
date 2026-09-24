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

    var body: some View {
        Text(text)
            .font(Font(ClockFont.resolve(preferences)))
            .foregroundStyle(preferences.textColor.swiftUIColor)
            .lineLimit(1)
            .minimumScaleFactor(0.25)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
            .accessibilityLabel("Current time")
            .accessibilityValue(text)
            .help(isPositioning ? "Drag to reposition. Choose Lock Positions from the Clocky menu when done." : "Current time")
    }
}
