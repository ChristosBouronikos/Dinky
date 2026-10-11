import AppKit
import DinkyLayout

// While a tiled window is dragged: a quiet outline of the tile it came from, and an accent-coloured one over the
// tile it would swap with. Two borderless panels that never take focus or clicks, kept just below the dragged
// window so they never cover it. They snap between tiles; nothing reflows until the drop.
final class DragPlaceholders {
    private lazy var home = Self.panel(PlaceholderView(tint: .secondaryLabelColor, fill: 0.06, stroke: 0.45))
    private lazy var target = Self.panel(PlaceholderView(tint: .controlAccentColor, fill: 0.2, stroke: 0.9))

    /// Show the outlines for a window being dragged: `home` is its tile, `target` the tile it would swap with.
    /// Rects are top-left global, as tiles are.
    func show(dragged: WindowID, home homeRect: CGRect, target targetRect: CGRect?, cornerRadius: CGFloat) {
        place(home, at: homeRect, below: dragged, cornerRadius: cornerRadius)
        if let targetRect { place(target, at: targetRect, below: dragged, cornerRadius: cornerRadius) } else { target.orderOut(nil) }
    }

    func hide() {
        home.orderOut(nil)
        target.orderOut(nil)
    }

    private func place(_ panel: NSPanel, at rect: CGRect, below window: WindowID, cornerRadius: CGFloat) {
        (panel.contentView as! PlaceholderView).cornerRadius = cornerRadius
        let frame = Self.appKitFrame(rect)
        // Asked on every frame of the drag, but an outline only moves when its tile changes.
        guard !panel.isVisible || panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        panel.order(.below, relativeTo: Int(window))
    }

    private static func panel(_ view: PlaceholderView) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.contentView = view
        return panel
    }

    /// Top-left global to AppKit's bottom-left, flipped around the primary screen.
    private static func appKitFrame(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

private final class PlaceholderView: NSView {
    private let tint: NSColor
    private let fill: CGFloat
    private let stroke: CGFloat
    var cornerRadius: CGFloat = 10 { didSet { if cornerRadius != oldValue { needsDisplay = true } } }

    init(tint: NSColor, fill: CGFloat, stroke: CGFloat) {
        self.tint = tint
        self.fill = fill
        self.stroke = stroke
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: cornerRadius, yRadius: cornerRadius)
        tint.withAlphaComponent(fill).setFill()
        path.fill()
        path.lineWidth = 3
        tint.withAlphaComponent(stroke).setStroke()
        path.stroke()
    }
}
