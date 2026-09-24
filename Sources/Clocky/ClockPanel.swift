import AppKit
import ClockyCore
import SwiftUI

@MainActor
final class ClockPanel: NSPanel {
    private let hostingView: NSHostingView<ClockView>
    private let dragSurface = DragSurface()
    var onPositionChanged: ((CGRect) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(text: String, preferences: ClockPreferences) {
        hostingView = NSHostingView(rootView: ClockView(
            text: text, preferences: preferences, isPositioning: false
        ))
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Clocky Clock"
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        isMovable = false
        animationBehavior = .none
        // Stay above ordinary/floating app windows, without using screen-saver or
        // secure-system levels. Menus and protected system UI may still cover us.
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications,
            .stationary, .ignoresCycle
        ]
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        dragSurface.addSubview(hostingView)
        contentView = dragSurface
        dragSurface.onDragEnded = { [weak self] frame in self?.onPositionChanged?(frame) }
    }

    func render(text: String, preferences: ClockPreferences, positioning: Bool, visibleFrame: CGRect) {
        hostingView.rootView = ClockView(text: text, preferences: preferences, isPositioning: positioning)
        ignoresMouseEvents = !positioning
        dragSurface.isPositioning = positioning
        dragSurface.visibleFrame = visibleFrame
        dragSurface.toolTip = positioning ? "Drag to reposition. Lock positions using the Clocky menu." : nil
        invalidateCursorRects(for: dragSurface)
    }

    var isDragging: Bool { dragSurface.isDragging }

    static func preferredSize(text: String, preferences: ClockPreferences) -> CGSize {
        let font = ClockFont.resolve(preferences)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width) + 30, height: ceil(measured.height) + 22)
    }
}

/// Handles local mouse events only during explicit positioning mode. It never
/// requests accessibility permission, monitors other apps, or takes focus.
@MainActor
private final class DragSurface: NSView {
    var isPositioning = false
    var visibleFrame = CGRect.zero
    var onDragEnded: ((CGRect) -> Void)?
    private var pointerStart: CGPoint?
    private var frameStart: CGRect?
    var isDragging: Bool { pointerStart != nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isPositioning ? self : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isPositioning { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isPositioning, let window else { return }
        pointerStart = NSEvent.mouseLocation
        frameStart = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPositioning, let window, let pointerStart, let frameStart else { return }
        let pointer = NSEvent.mouseLocation
        let proposed = frameStart.offsetBy(dx: pointer.x - pointerStart.x, dy: pointer.y - pointerStart.y)
        let position = OverlayGeometry.position(for: proposed, in: visibleFrame)
        let clamped = OverlayGeometry.frame(size: window.frame.size, visibleFrame: visibleFrame, position: position)
        window.setFrame(clamped, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        pointerStart = nil
        frameStart = nil
        if let window { onDragEnded?(window.frame) }
    }
}
