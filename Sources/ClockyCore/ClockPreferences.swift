import Foundation

public enum TimeFormat: String, Codable, CaseIterable, Identifiable {
    case system
    case twelveHour
    case twentyFourHour

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }
}

/// RGB components in the range 0...1. Background alpha is stored separately.
public struct RGBAColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)

    fileprivate func sanitized(default fallback: RGBAColor) -> RGBAColor {
        RGBAColor(
            red: bounded(red, to: 0...1, default: fallback.red),
            green: bounded(green, to: 0...1, default: fallback.green),
            blue: bounded(blue, to: 0...1, default: fallback.blue)
        )
    }
}

/// A fraction of the overlay's available travel, with y increasing upward.
public struct DisplayPosition: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let topRight = DisplayPosition(x: 1, y: 1)

    func sanitized() -> DisplayPosition {
        DisplayPosition(
            x: bounded(x, to: 0...1, default: Self.topRight.x),
            y: bounded(y, to: 0...1, default: Self.topRight.y)
        )
    }
}

public struct ClockPreferences: Codable, Equatable {
    public var isVisible: Bool
    public var showsSeconds: Bool
    public var timeFormat: TimeFormat
    /// PostScript font name; nil retains the default system font.
    public var fontName: String?
    public var fontSize: Double
    public var textColor: RGBAColor
    public var backgroundColor: RGBAColor
    public var backgroundOpacity: Double
    public var positions: [String: DisplayPosition]

    public init() {
        isVisible = true
        showsSeconds = false
        timeFormat = .system
        fontName = nil
        fontSize = 28
        textColor = .white
        backgroundColor = .black
        backgroundOpacity = 0.65
        positions = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible, showsSeconds, timeFormat, fontName, fontSize, textColor
        case backgroundColor, backgroundOpacity, positions
    }

    /// Missing, null, or unrecognized fields retain their defaults. This allows
    /// older preferences and future enum values to be read without losing settings.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = (try? values.decode(Bool.self, forKey: .isVisible)) ?? isVisible
        showsSeconds = (try? values.decode(Bool.self, forKey: .showsSeconds)) ?? showsSeconds
        timeFormat = (try? values.decode(TimeFormat.self, forKey: .timeFormat)) ?? timeFormat
        fontName = try? values.decode(String.self, forKey: .fontName)
        fontSize = (try? values.decode(Double.self, forKey: .fontSize)) ?? fontSize
        textColor = (try? values.decode(RGBAColor.self, forKey: .textColor)) ?? textColor
        backgroundColor = (try? values.decode(RGBAColor.self, forKey: .backgroundColor)) ?? backgroundColor
        backgroundOpacity = (try? values.decode(Double.self, forKey: .backgroundOpacity)) ?? backgroundOpacity
        positions = (try? values.decode([String: DisplayPosition].self, forKey: .positions)) ?? positions
    }

    /// Finite out-of-range values are clamped; nonfinite values use defaults.
    public func sanitized() -> ClockPreferences {
        let defaults = ClockPreferences()
        var result = self
        let trimmedName = fontName?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.fontName = trimmedName?.isEmpty == false ? trimmedName : nil
        result.fontSize = bounded(fontSize, to: 14...96, default: defaults.fontSize)
        result.textColor = textColor.sanitized(default: defaults.textColor)
        result.backgroundColor = backgroundColor.sanitized(default: defaults.backgroundColor)
        result.backgroundOpacity = bounded(backgroundOpacity, to: 0...1, default: defaults.backgroundOpacity)
        result.positions = positions.mapValues { $0.sanitized() }
        return result
    }
}

private func bounded(_ value: Double, to range: ClosedRange<Double>, default fallback: Double) -> Double {
    guard value.isFinite else { return fallback }
    return min(range.upperBound, max(range.lowerBound, value))
}
