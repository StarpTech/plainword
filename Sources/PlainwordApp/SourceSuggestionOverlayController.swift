import AppKit

enum SourceSuggestionMarkStyle: Equatable {
    case deletion
    case rewrite
}

struct SourceSuggestionMark: Equatable {
    let rect: CGRect
    let style: SourceSuggestionMarkStyle
}

struct SourceSuggestionGeometry: Equatable {
    let marks: [SourceSuggestionMark]

    var anchor: CGRect {
        marks.first?.rect ?? .zero
    }
}

@MainActor
final class SourceSuggestionOverlayController {
    private let panel: SourceSuggestionOverlayPanel
    private let overlayView = SourceSuggestionOverlayView(frame: .zero)

    init() {
        panel = SourceSuggestionOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // Match the proposal's floating layer so source marks stay visible when the
        // active editor reorders its normal-level windows. The cross-app controller
        // removes this overlay whenever the proposal is suspended.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = overlayView
        overlayView.autoresizingMask = [.width, .height]
    }

    func show(_ geometry: SourceSuggestionGeometry, below windowNumber: Int) {
        guard !geometry.marks.isEmpty else {
            dismiss()
            return
        }

        let globalFrame = geometry.marks.reduce(CGRect.null) { partial, mark in
            partial.union(mark.rect)
        }.insetBy(dx: -3, dy: -3).integral
        guard !globalFrame.isNull,
              globalFrame.width > 0,
              globalFrame.height > 0 else {
            dismiss()
            return
        }

        overlayView.marks = geometry.marks.map { mark in
            SourceSuggestionMark(
                rect: mark.rect.offsetBy(
                    dx: -globalFrame.minX,
                    dy: -globalFrame.minY
                ),
                style: mark.style
            )
        }
        panel.setFrame(globalFrame, display: true)
        // This view starts at zero size. Set it explicitly instead of relying on
        // a deferred borderless panel to resize its content view on first show.
        overlayView.frame = CGRect(origin: .zero, size: globalFrame.size)
        overlayView.needsDisplay = true
        // The source marks and proposal are separate same-level windows. Order
        // the marks relative to the proposal so geometry refreshes cannot put an
        // underline or highlight over the proposal surface.
        panel.order(.below, relativeTo: windowNumber)
    }

    func dismiss() {
        overlayView.marks = []
        panel.orderOut(nil)
    }
}

private final class SourceSuggestionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SourceSuggestionOverlayView: NSView {
    var marks: [SourceSuggestionMark] = [] {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for mark in marks where mark.rect.intersects(dirtyRect) {
            switch mark.style {
            case .deletion:
                drawDeletion(in: mark.rect)
            case .rewrite:
                drawRewrite(in: mark.rect)
            }
        }
    }

    private func drawDeletion(in rect: CGRect) {
        let color = Self.dangerColor
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: -1, dy: 0),
            xRadius: 3,
            yRadius: 3
        ).fill()

        color.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 2.5
        line.lineCapStyle = .round
        let y = floor(rect.midY) + 0.5
        line.move(to: CGPoint(x: rect.minX, y: y))
        line.line(to: CGPoint(x: rect.maxX, y: y))
        line.stroke()
    }

    private func drawRewrite(in rect: CGRect) {
        let color = Self.rewriteColor
        color.withAlphaComponent(0.11).setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: -1, dy: 0),
            xRadius: 3,
            yRadius: 3
        ).fill()

        color.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 2
        let y = floor(rect.minY + 1) + 0.5
        line.move(to: CGPoint(x: rect.minX, y: y))
        line.line(to: CGPoint(x: rect.maxX, y: y))
        line.stroke()
    }

    private static let dangerColor = adaptiveColor(
        light: 0xC83945,
        dark: 0xFF7D88
    )
    private static let rewriteColor = adaptiveColor(
        light: 0x99601D,
        dark: 0xEDB864
    )

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
            return NSColor(
                calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
