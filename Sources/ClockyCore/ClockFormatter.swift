import Foundation

public enum ClockFormatter {
    public static func string(
        at date: Date,
        format: TimeFormat,
        showsSeconds: Bool,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        // A local formatter avoids sharing mutable DateFormatter state across
        // displays or threads and picks up changed system locale preferences.
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch format {
        case .system:
            formatter.setLocalizedDateFormatFromTemplate(showsSeconds ? "jms" : "jm")
        case .twelveHour:
            formatter.dateFormat = showsSeconds ? "h:mm:ss a" : "h:mm a"
        case .twentyFourHour:
            formatter.dateFormat = showsSeconds ? "HH:mm:ss" : "HH:mm"
        }
        return formatter.string(from: date)
    }

    /// Aligns each refresh to wall-clock boundaries, not the previous timer fire.
    /// An exact boundary schedules the following boundary, never the same date.
    public static func nextUpdate(after date: Date, showsSeconds: Bool) -> Date {
        let interval: TimeInterval = showsSeconds ? 1 : 60
        let next = (floor(date.timeIntervalSinceReferenceDate / interval) + 1) * interval
        return Date(timeIntervalSinceReferenceDate: next)
    }
}
