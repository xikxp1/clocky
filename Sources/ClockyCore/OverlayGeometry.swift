import CoreGraphics
import Foundation

public enum OverlayGeometry {
    /// Fits the overlay inside the visible screen, then positions it along its
    /// remaining travel. A margin larger than half a screen dimension collapses
    /// that usable dimension to its midpoint rather than producing a negative size.
    public static func frame(
        size: CGSize,
        visibleFrame: CGRect,
        position: DisplayPosition,
        margin: CGFloat = 12
    ) -> CGRect {
        let usable = usableFrame(visibleFrame, margin: margin)
        let fitted = fittedSize(size, in: usable)
        let position = position.sanitized()
        return CGRect(
            x: usable.minX + (usable.width - fitted.width) * CGFloat(position.x),
            y: usable.minY + (usable.height - fitted.height) * CGFloat(position.y),
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Converts a dragged frame back to normalized travel. On an axis with no
    /// travel, the top/right default is used because all positions are equivalent.
    public static func position(
        for frame: CGRect,
        in visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> DisplayPosition {
        let usable = usableFrame(visibleFrame, margin: margin)
        let fitted = fittedSize(frame.size, in: usable)
        let travelX = usable.width - fitted.width
        let travelY = usable.height - fitted.height
        return DisplayPosition(
            x: travelX > 0 ? Double((frame.origin.x - usable.minX) / travelX) : 1,
            y: travelY > 0 ? Double((frame.origin.y - usable.minY) / travelY) : 1
        ).sanitized()
    }

    private static func usableFrame(_ frame: CGRect, margin: CGFloat) -> CGRect {
        // Invalid geometry must not propagate NaN into a native window frame.
        let finiteFrame = CGRect(
            x: frame.origin.x.isFinite ? frame.origin.x : 0,
            y: frame.origin.y.isFinite ? frame.origin.y : 0,
            width: frame.size.width.isFinite ? frame.size.width : 0,
            height: frame.size.height.isFinite ? frame.size.height : 0
        ).standardized
        let margin = margin.isFinite ? max(0, margin) : 12
        let horizontal = min(margin, finiteFrame.width / 2)
        let vertical = min(margin, finiteFrame.height / 2)
        return CGRect(
            x: finiteFrame.minX + horizontal,
            y: finiteFrame.minY + vertical,
            width: max(0, finiteFrame.width - 2 * horizontal),
            height: max(0, finiteFrame.height - 2 * vertical)
        )
    }

    private static func fittedSize(_ size: CGSize, in frame: CGRect) -> CGSize {
        CGSize(
            width: min(frame.width, size.width.isFinite ? max(0, size.width) : 0),
            height: min(frame.height, size.height.isFinite ? max(0, size.height) : 0)
        )
    }
}
