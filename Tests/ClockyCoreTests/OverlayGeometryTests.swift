import CoreGraphics
import Foundation
import XCTest
@testable import ClockyCore

final class OverlayGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 200, height: 80)

    func testDefaultMarginTopRight() {
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight),
            CGRect(x: 788, y: 708, width: 200, height: 80)
        )
    }

    func testBottomLeftAndCenterUseTravelRatherThanScreenFractions() {
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: DisplayPosition(x: 0, y: 0)),
            CGRect(x: 12, y: 12, width: 200, height: 80)
        )
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: DisplayPosition(x: 0.5, y: 0.5)),
            CGRect(x: 400, y: 360, width: 200, height: 80)
        )
    }

    func testNegativeScreenOriginsAndNonzeroMenuBarOffsets() {
        let screen = CGRect(x: -1920, y: -240, width: 1920, height: 1055)
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight),
            CGRect(x: -212, y: 723, width: 200, height: 80)
        )
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: DisplayPosition(x: 0, y: 0)),
            CGRect(x: -1908, y: -228, width: 200, height: 80)
        )
    }

    func testCustomAndZeroMargins() {
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight, margin: 30),
            CGRect(x: 770, y: 690, width: 200, height: 80)
        )
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight, margin: 0),
            CGRect(x: 800, y: 720, width: 200, height: 80)
        )
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight, margin: -10),
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight, margin: 0)
        )
    }

    func testOversizedOverlayIsClampedToUsableDimensions() {
        let frame = OverlayGeometry.frame(size: CGSize(width: 2000, height: 1000), visibleFrame: screen, position: .topRight)
        XCTAssertEqual(frame, CGRect(x: 12, y: 12, width: 976, height: 776))
        XCTAssertEqual(OverlayGeometry.position(for: frame, in: screen), .topRight)
    }

    func testOneOversizedDimensionStillAllowsTravelOnOtherAxis() {
        let frame = OverlayGeometry.frame(size: CGSize(width: 2000, height: 80), visibleFrame: screen, position: DisplayPosition(x: 0.2, y: 0.25))
        XCTAssertEqual(frame, CGRect(x: 12, y: 186, width: 976, height: 80))
        XCTAssertEqual(OverlayGeometry.position(for: frame, in: screen), DisplayPosition(x: 1, y: 0.25))
    }

    func testTinyAndEmptyScreensNeverProduceNegativeSizes() {
        let tiny = CGRect(x: -100, y: -50, width: 10, height: 20)
        let frame = OverlayGeometry.frame(size: size, visibleFrame: tiny, position: .topRight)
        XCTAssertEqual(frame, CGRect(x: -95, y: -40, width: 0, height: 0))
        XCTAssertEqual(OverlayGeometry.position(for: frame, in: tiny), .topRight)
        XCTAssertEqual(OverlayGeometry.frame(size: size, visibleFrame: .zero, position: .topRight), .zero)
    }

    func testTinyWidthDoesNotCollapseUsableHeight() {
        let screen = CGRect(x: 0, y: 0, width: 10, height: 800)
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight),
            CGRect(x: 5, y: 708, width: 0, height: 80)
        )
    }

    func testOutsidePositionsAndDraggedFramesAreClamped() {
        XCTAssertEqual(
            OverlayGeometry.frame(size: size, visibleFrame: screen, position: DisplayPosition(x: -2, y: 4)),
            CGRect(x: 12, y: 708, width: 200, height: 80)
        )
        XCTAssertEqual(
            OverlayGeometry.position(for: CGRect(x: -100, y: 900, width: 200, height: 80), in: screen),
            DisplayPosition(x: 0, y: 1)
        )
    }

    func testNonfinitePositionsFallBackToTopRight() {
        let frame = OverlayGeometry.frame(size: size, visibleFrame: screen, position: DisplayPosition(x: .nan, y: .infinity))
        XCTAssertEqual(frame, OverlayGeometry.frame(size: size, visibleFrame: screen, position: .topRight))
    }

    func testInvalidSizeAndMarginRemainFinite() {
        let frame = OverlayGeometry.frame(size: CGSize(width: CGFloat.nan, height: -20), visibleFrame: screen, position: .topRight, margin: .nan)
        XCTAssertEqual(frame, CGRect(x: 988, y: 788, width: 0, height: 0))
    }

    func testInverseAcrossScreensMarginsAndPositions() {
        let screens = [screen, CGRect(x: -1920, y: -1200, width: 1600, height: 900), CGRect(x: 500, y: 40, width: 600, height: 500)]
        for screen in screens {
            for margin: CGFloat in [0, 12, 33] {
                for x in [0.0, 0.1, 0.5, 0.9, 1.0] {
                    for y in [0.0, 0.25, 0.5, 1.0] {
                        let position = DisplayPosition(x: x, y: y)
                        let frame = OverlayGeometry.frame(size: size, visibleFrame: screen, position: position, margin: margin)
                        let restored = OverlayGeometry.position(for: frame, in: screen, margin: margin)
                        XCTAssertEqual(restored.x, x, accuracy: 1e-12)
                        XCTAssertEqual(restored.y, y, accuracy: 1e-12)
                        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX + margin)
                        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + margin)
                        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - margin)
                        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY - margin)
                    }
                }
            }
        }
    }

    func testPositionScalesWithChangedScreenSize() {
        let position = DisplayPosition(x: 0.25, y: 0.75)
        let first = OverlayGeometry.frame(size: size, visibleFrame: screen, position: position)
        let normalized = OverlayGeometry.position(for: first, in: screen)
        let secondScreen = CGRect(x: -1600, y: 100, width: 1600, height: 1000)
        let second = OverlayGeometry.frame(size: size, visibleFrame: secondScreen, position: normalized)
        XCTAssertEqual(second, CGRect(x: -1244, y: 784, width: 200, height: 80))
    }
}
