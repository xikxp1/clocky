import Foundation
import XCTest
@testable import ClockyCore

final class ClockFormatterTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testForcedTwelveHourFormatAtMidnightNoonAndAfternoon() throws {
        for (timestamp, expected) in [
            ("2024-01-15T00:05:09Z", "12:05 AM"),
            ("2024-01-15T12:05:09Z", "12:05 PM"),
            ("2024-01-15T15:05:09Z", "3:05 PM")
        ] {
            XCTAssertEqual(normalized(ClockFormatter.string(at: try date(timestamp), format: .twelveHour, showsSeconds: false, locale: locale, timeZone: utc)), expected)
        }
    }

    func testForcedTwentyFourHourFormatPadsHours() throws {
        for (timestamp, expected) in [
            ("2024-01-15T00:05:09Z", "00:05"),
            ("2024-01-15T09:05:09Z", "09:05"),
            ("2024-01-15T12:05:09Z", "12:05"),
            ("2024-01-15T23:59:59Z", "23:59")
        ] {
            XCTAssertEqual(ClockFormatter.string(at: try date(timestamp), format: .twentyFourHour, showsSeconds: false, locale: locale, timeZone: utc), expected)
        }
    }

    func testSecondsAreIncludedOnlyWhenRequested() throws {
        let date = try date("2024-01-15T15:05:09Z")
        XCTAssertEqual(normalized(ClockFormatter.string(at: date, format: .twelveHour, showsSeconds: true, locale: locale, timeZone: utc)), "3:05:09 PM")
        XCTAssertEqual(ClockFormatter.string(at: date, format: .twentyFourHour, showsSeconds: true, locale: locale, timeZone: utc), "15:05:09")
    }

    func testExplicitFormatsOverrideLocaleHourCycle() throws {
        let date = try date("2024-01-15T15:05:09Z")
        XCTAssertEqual(ClockFormatter.string(at: date, format: .twentyFourHour, showsSeconds: false, locale: Locale(identifier: "en_US"), timeZone: utc), "15:05")
        XCTAssertEqual(normalized(ClockFormatter.string(at: date, format: .twelveHour, showsSeconds: false, locale: Locale(identifier: "en_GB"), timeZone: utc)).lowercased(), "3:05 pm")
    }

    func testSystemFormatUsesLocalizedHourCycle() throws {
        let date = try date("2024-01-15T15:05:09Z")
        XCTAssertEqual(normalized(ClockFormatter.string(at: date, format: .system, showsSeconds: false, locale: Locale(identifier: "en_US"), timeZone: utc)), "3:05 PM")
        XCTAssertEqual(ClockFormatter.string(at: date, format: .system, showsSeconds: false, locale: Locale(identifier: "de_DE"), timeZone: utc), "15:05")
        XCTAssertEqual(ClockFormatter.string(at: date, format: .system, showsSeconds: true, locale: Locale(identifier: "de_DE"), timeZone: utc), "15:05:09")
    }

    func testSystemFormatMatchesLocalizedTemplatesAcrossLocales() throws {
        let date = try date("2024-01-15T15:05:09Z")
        for identifier in ["en_US", "en_GB", "fr_FR", "ja_JP", "ar_EG"] {
            for seconds in [false, true] {
                let locale = Locale(identifier: identifier)
                let expected = DateFormatter()
                expected.locale = locale
                expected.timeZone = utc
                expected.setLocalizedDateFormatFromTemplate(seconds ? "jms" : "jm")
                XCTAssertEqual(ClockFormatter.string(at: date, format: .system, showsSeconds: seconds, locale: locale, timeZone: utc), expected.string(from: date))
            }
        }
    }

    func testTimeZoneIsAppliedIncludingFractionalHourOffsets() throws {
        let date = try date("2024-01-15T23:45:09Z")
        let india = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        XCTAssertEqual(ClockFormatter.string(at: date, format: .twentyFourHour, showsSeconds: true, locale: locale, timeZone: india), "05:15:09")
        XCTAssertEqual(ClockFormatter.string(at: date, format: .twentyFourHour, showsSeconds: true, locale: locale, timeZone: utc), "23:45:09")
    }

    func testDaylightSavingTransitionUsesActualDate() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let before = try date("2024-03-10T06:59:59Z")
        let after = ClockFormatter.nextUpdate(after: before, showsSeconds: true)
        XCTAssertEqual(ClockFormatter.string(at: before, format: .twentyFourHour, showsSeconds: true, locale: locale, timeZone: zone), "01:59:59")
        XCTAssertEqual(ClockFormatter.string(at: after, format: .twentyFourHour, showsSeconds: true, locale: locale, timeZone: zone), "03:00:00")
    }

    func testNextSecondStrictlyFollowsExactAndFractionalBoundaries() {
        for (input, expected) in [(0.0, 1.0), (0.25, 1.0), (59.75, 60.0), (60.0, 61.0), (-0.25, 0.0), (-1.0, 0.0), (-60.25, -60.0)] {
            let next = ClockFormatter.nextUpdate(after: Date(timeIntervalSinceReferenceDate: input), showsSeconds: true)
            XCTAssertEqual(next.timeIntervalSinceReferenceDate, expected)
            XCTAssertGreaterThan(next.timeIntervalSinceReferenceDate, input)
        }
    }

    func testNextMinuteStrictlyFollowsExactAndFractionalBoundaries() {
        for (input, expected) in [(0.0, 60.0), (0.25, 60.0), (59.75, 60.0), (60.0, 120.0), (119.75, 120.0), (-0.25, 0.0), (-60.0, 0.0), (-60.25, -60.0)] {
            let next = ClockFormatter.nextUpdate(after: Date(timeIntervalSinceReferenceDate: input), showsSeconds: false)
            XCTAssertEqual(next.timeIntervalSinceReferenceDate, expected)
            XCTAssertGreaterThan(next.timeIntervalSinceReferenceDate, input)
        }
    }

    func testRefreshCrossesMidnightAndYearBoundary() throws {
        let input = try date("2024-12-31T23:59:59Z").addingTimeInterval(0.75)
        let expected = try date("2025-01-01T00:00:00Z")
        XCTAssertEqual(ClockFormatter.nextUpdate(after: input, showsSeconds: true), expected)
        XCTAssertEqual(ClockFormatter.nextUpdate(after: input, showsSeconds: false), expected)
    }

    func testLateRefreshesRealignRatherThanAccumulateDrift() {
        for seconds in [false, true] {
            let interval = seconds ? 1.0 : 60.0
            var current = Date(timeIntervalSinceReferenceDate: 1_000_000.25)
            for _ in 0..<100 {
                let next = ClockFormatter.nextUpdate(after: current, showsSeconds: seconds)
                XCTAssertEqual(next.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: interval), 0)
                XCTAssertGreaterThan(next, current)
                XCTAssertLessThanOrEqual(next.timeIntervalSince(current), interval)
                current = next.addingTimeInterval(interval * 2 + 0.25)
            }
        }
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func normalized(_ value: String) -> String {
        value.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
