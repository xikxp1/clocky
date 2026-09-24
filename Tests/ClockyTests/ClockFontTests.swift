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
    }

    @MainActor
    func testMissingFontFallsBackWithoutDiscardingSavedSelection() async {
        var preferences = ClockPreferences()
        preferences.fontName = "Clocky-Missing-Test-Font-\(UUID().uuidString)"
        preferences.fontSize = 40
        XCTAssertFalse(ClockFont.isAvailable(preferences.fontName))
        XCTAssertEqual(ClockFont.resolve(preferences), NSFont.monospacedDigitSystemFont(ofSize: 40, weight: .medium))
        XCTAssertNotNil(preferences.fontName)
    }

    @MainActor
    func testPanelMeasuresSelectedFontAndFallback() async {
        for name in [nil, "Helvetica-Bold", "Clocky-Missing-Test-Font"] as [String?] {
            var preferences = ClockPreferences()
            preferences.fontName = name
            preferences.fontSize = 48
            let text = "12:59:59 PM"
            let expected = (text as NSString).size(withAttributes: [.font: ClockFont.resolve(preferences)])
            let size = ClockPanel.preferredSize(text: text, preferences: preferences)
            XCTAssertEqual(size.width, ceil(expected.width) + 30)
            XCTAssertEqual(size.height, ceil(expected.height) + 22)
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
