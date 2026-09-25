import AppKit
import ClockyCore
import XCTest
@testable import Clocky

final class ClockFontTests: XCTestCase {
    @MainActor
    func testDefaultFontKeepsSystemAppearance() async {
        let preferences = ClockPreferences()
        let expected = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        XCTAssertEqual(ClockFont.resolve(preferences), expected)
        XCTAssertTrue(ClockFont.isAvailable(nil))
    }

    @MainActor
    func testInstalledFontAndSizeAreResolvedExactly() async throws {
        var preferences = ClockPreferences()
        preferences.fontName = "Helvetica-Bold"
        preferences.fontSize = 48
        let expected = try XCTUnwrap(NSFont(name: "Helvetica-Bold", size: 48))
        XCTAssertTrue(ClockFont.isAvailable(preferences.fontName))
        XCTAssertEqual(ClockFont.resolve(preferences), expected)
        XCTAssertEqual(ClockFont.battery(preferences), NSFont(name: "Helvetica-Bold", size: 48 * 0.45))
    }

    @MainActor
    func testMissingFontFallsBackWithoutDiscardingSavedSelection() async {
        var preferences = ClockPreferences()
        preferences.fontName = "Clocky-Missing-Test-Font-\(UUID().uuidString)"
        preferences.fontSize = 40
        XCTAssertFalse(ClockFont.isAvailable(preferences.fontName))
        XCTAssertEqual(ClockFont.resolve(preferences), NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .medium))
        XCTAssertEqual(ClockFont.battery(preferences), NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .medium))
        XCTAssertNotNil(preferences.fontName)
    }

    @MainActor
    func testBatteryFontScalesWithReadableMinimum() async {
        for name in [nil, "Helvetica-Bold", "Clocky-Missing-Test-Font"] as [String?] {
            for fontSize in [14.0, 28, 48, 96] {
                var preferences = ClockPreferences()
                preferences.fontName = name
                preferences.fontSize = fontSize
                let expectedSize = max(10, fontSize * 0.45)
                let expected = name.flatMap { NSFont(name: $0, size: expectedSize) }
                    ?? NSFont.monospacedDigitSystemFont(ofSize: expectedSize, weight: .medium)
                XCTAssertEqual(ClockFont.battery(preferences), expected)
                XCTAssertEqual(ClockFont.battery(preferences).pointSize, expectedSize)
            }
        }
    }

    @MainActor
    func testPanelMeasuresClockAndColumnsWithSelectedFontAndFallback() async {
        let battery = BatterySnapshot()
        for name in [nil, "Helvetica-Bold", "Clocky-Missing-Test-Font"] as [String?] {
            for fontSize in [14.0, 28, 48, 96] {
                var preferences = ClockPreferences()
                preferences.fontName = name
                preferences.fontSize = fontSize
                let text = "12:59:59 PM"
                let measuredTime = (text as NSString).size(withAttributes: [.font: ClockFont.resolve(preferences)])
                let layout = ClockContentLayout(text: text, battery: battery, preferences: preferences)
                let columnWidth = layout.columns.reduce(0) { $0 + $1.size.width }
                let columnHeight = 2 * layout.rowHeight + ClockContentLayout.rowSpacing
                let size = ClockPanel.preferredSize(text: text, preferences: preferences, battery: battery)
                XCTAssertEqual(layout.clockFont, ClockFont.resolve(preferences))
                XCTAssertEqual(layout.clockSize, CGSize(width: ceil(measuredTime.width), height: ceil(measuredTime.height)))
                XCTAssertEqual(size.width, ceil(measuredTime.width) + columnWidth + 2 * ClockContentLayout.columnSpacing + 30)
                XCTAssertEqual(size.height, max(ceil(measuredTime.height), columnHeight) + 22)
                XCTAssertEqual(size, layout.panelSize)
                XCTAssertEqual(size, ClockPanel.preferredSize(text: text, preferences: preferences))
            }
        }
    }

    @MainActor
    func testPanelAddsColumnWidthsToBothShortAndLongClocks() async {
        let battery = BatterySnapshot()
        for name in [nil, "Helvetica-Bold"] as [String?] {
            var preferences = ClockPreferences()
            preferences.fontName = name
            let timeFont = ClockFont.resolve(preferences)
            for text in ["1:00", String(repeating: "12:59:59 PM ", count: 4)] {
                let layout = ClockContentLayout(text: text, battery: battery, preferences: preferences)
                let columnWidth = layout.columns.reduce(0) { $0 + $1.size.width }
                let timeWidth = (text as NSString).size(withAttributes: [.font: timeFont]).width
                XCTAssertEqual(
                    ClockPanel.preferredSize(text: text, preferences: preferences, battery: battery).width,
                    ceil(timeWidth) + columnWidth + 2 * ClockContentLayout.columnSpacing + 30
                )
            }
        }
    }

    @MainActor
    func testPanelMeasuresSuppliedBatterySnapshot() async {
        let battery = BatterySnapshot(
            mac: 100, iPhone: 100, airPods: AirPodsBattery(left: 100, right: 100, caseLevel: 100)
        )
        for name in [nil, "Helvetica-Bold"] as [String?] {
            var preferences = ClockPreferences()
            preferences.fontName = name
            let size = ClockPanel.preferredSize(text: "1:00", preferences: preferences, battery: battery)
            let layout = ClockContentLayout(text: "1:00", battery: battery, preferences: preferences)
            XCTAssertEqual(size.width, layout.clockSize.width + layout.columns.reduce(0) { $0 + $1.size.width }
                           + 2 * ClockContentLayout.columnSpacing + 30)
            XCTAssertGreaterThan(size.width, ClockPanel.preferredSize(text: "1:00", preferences: preferences).width)
        }
    }

    @MainActor
    func testColumnPanelRemainsScreenBoundedAtMinimumAndMaximumFontSizes() async {
        for fontSize in [14.0, 96] {
            var preferences = ClockPreferences()
            preferences.fontSize = fontSize
            let layout = ClockContentLayout(text: "12:59:59 PM", battery: BatterySnapshot(), preferences: preferences)
            let size = ClockPanel.preferredSize(text: "12:59:59 PM", preferences: preferences)
            for visibleFrame in [CGRect(x: 0, y: 0, width: 140, height: 80),
                                 CGRect(x: 0, y: 0, width: 60, height: 50),
                                 CGRect(x: -1440, y: 0, width: 1440, height: 900)] {
                let frame = OverlayGeometry.frame(size: size, visibleFrame: visibleFrame, position: .topRight)
                XCTAssertTrue(visibleFrame.contains(frame))
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                let contentSize = CGSize(width: max(0, frame.width - 2 * ClockContentLayout.horizontalPadding),
                                         height: max(0, frame.height - 2 * ClockContentLayout.verticalPadding))
                let scale = layout.scaleFactor(in: contentSize)
                XCTAssertLessThanOrEqual(layout.size.width * scale, contentSize.width + 0.0001)
                XCTAssertLessThanOrEqual(layout.size.height * scale, contentSize.height + 0.0001)
            }
        }
    }

    @MainActor
    func testAllReadingsDisabledRestoreTimeOnlySizeForEveryFont() async {
        for name in [nil, "Helvetica-Bold", "Clocky-Missing-Test-Font"] as [String?] {
            for fontSize in [14.0, 28, 96] {
                var preferences = ClockPreferences()
                preferences.fontName = name
                preferences.fontSize = fontSize
                preferences.showsMacBattery = false
                preferences.showsIPhoneBattery = false
                preferences.showsAirPodsBattery = false
                preferences.showsAirPodsCaseBattery = false
                let measured = ("1:00" as NSString).size(withAttributes: [.font: ClockFont.resolve(preferences)])
                let battery = BatterySnapshot(mac: 100, iPhone: 100, airPods: AirPodsBattery(left: 100, caseLevel: 100))
                let size = ClockPanel.preferredSize(text: "1:00", preferences: preferences, battery: battery)
                XCTAssertEqual(size, CGSize(width: ceil(measured.width) + 30, height: ceil(measured.height) + 22))
                XCTAssertEqual(size, ClockPanel.preferredSize(text: "1:00", preferences: preferences))
            }
        }
    }

    @MainActor
    func testCatalogExposesInstalledFamiliesAndFaces() async throws {
        let catalog = FontCatalog()
        XCTAssertFalse(catalog.families.isEmpty)
        XCTAssertEqual(Set(catalog.families).count, catalog.families.count)
        let family = try XCTUnwrap(catalog.family(for: "Helvetica-Bold"))
        let faces = catalog.faces(in: family)
        XCTAssertTrue(faces.contains { $0.name == "Helvetica-Bold" })
        XCTAssertEqual(Set(faces.map(\.id)).count, faces.count)
        let defaultName = try XCTUnwrap(catalog.defaultFace(in: family))
        XCTAssertTrue(faces.contains { $0.name == defaultName })
        XCTAssertTrue(ClockFont.isAvailable(defaultName))
        XCTAssertNil(catalog.family(for: nil))
        XCTAssertNil(catalog.family(for: "Clocky-Missing-Test-Font"))
    }

    @MainActor
    func testCatalogRefreshRetainsValidSelections() async throws {
        let catalog = FontCatalog()
        let family = try XCTUnwrap(catalog.family(for: "Helvetica-Bold"))
        let faces = catalog.faces(in: family)
        catalog.refresh()
        XCTAssertEqual(catalog.faces(in: family), faces)
        XCTAssertNil(catalog.defaultFace(in: "Clocky-Missing-Test-Family"))
    }
}
