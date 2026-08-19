import AppKit
import SwiftUI

/// A hover hint for views that AppKit's own tooltips cannot reach.
///
/// `NSView.toolTip` — and so SwiftUI's `.help(_:)` — is tracked only while the owning
/// window is key or its application is active. Plainword's proposal panel is neither: it
/// is a nonactivating float shown by a background agent over whichever application the
/// author is writing in, deliberately left non-key so their typing is undisturbed. A
/// tooltip attached there is simply never delivered.
///
/// This does the same job with tracking that stays live regardless of activation, and
/// draws the hint in its own window so nothing in the panel moves or gets clipped.
@MainActor
private final class HoverTipPresenter {
    static let shared = HoverTipPresenter()

    private let maximumWidth: CGFloat = 320
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 5
    /// Roughly the pointer's height, so the hint clears the cursor it belongs to.
    private let pointerClearance: CGFloat = 20

    private lazy var label: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = maximumWidth - horizontalPadding * 2
        return label
    }()

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // Above the proposal panel, which already floats.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // The hint must never take the pointer away from what it describes.
        panel.ignoresMouseEvents = true

        let surface = NSVisualEffectView()
        surface.material = .toolTip
        surface.state = .active
        surface.blendingMode = .behindWindow
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 5
        surface.layer?.masksToBounds = true
        surface.addSubview(label)
        panel.contentView = surface
        return panel
    }()

    func show(_ text: String, near pointer: NSPoint) {
        guard !text.isEmpty else { return }
        label.stringValue = text

        let textSize = label.sizeThatFits(
            NSSize(width: maximumWidth - horizontalPadding * 2, height: .greatestFiniteMagnitude)
        )
        let size = NSSize(
            width: ceil(textSize.width) + horizontalPadding * 2,
            height: ceil(textSize.height) + verticalPadding * 2
        )
        label.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: size.width - horizontalPadding * 2,
            height: size.height - verticalPadding * 2
        )
        panel.setFrame(
            NSRect(origin: origin(for: size, near: pointer), size: size),
            display: false
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Below and to the right of the pointer, flipped or nudged when the screen runs out.
    private func origin(for size: NSSize, near pointer: NSPoint) -> NSPoint {
        var origin = NSPoint(
            x: pointer.x + 12,
            y: pointer.y - pointerClearance - size.height
        )
        guard let frame = (NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main)?.visibleFrame else {
            return origin
        }
        origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
        if origin.y < frame.minY + 4 {
            origin.y = pointer.y + pointerClearance
        }
        origin.y = min(origin.y, frame.maxY - size.height - 4)
        return origin
    }
}

/// Tracks the pointer over a view without taking its clicks.
private final class HoverTipTrackingView: NSView {
    var text = ""
    var delay: Duration = .milliseconds(450)
    private var pendingShow: Task<Void, Never>?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                // `activeAlways` is the whole point: the panel's application is in the
                // background while the author writes, and any narrower scope would stop
                // reporting exactly when the hint is needed.
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    /// Invisible to clicks, so the SwiftUI content underneath keeps its own behaviour.
    /// Tracking areas report the pointer independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        let text = text
        let delay = delay
        pendingShow?.cancel()
        pendingShow = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            HoverTipPresenter.shared.show(text, near: NSEvent.mouseLocation)
        }
    }

    override func mouseExited(with event: NSEvent) {
        dismiss()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismiss() }
    }

    private func dismiss() {
        pendingShow?.cancel()
        pendingShow = nil
        HoverTipPresenter.shared.hide()
    }
}

private struct HoverTipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = HoverTipTrackingView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HoverTipTrackingView)?.text = text
    }
}

extension View {
    /// Shows `text` after a short hover, for content that is truncated to fit.
    ///
    /// Prefer this over `.help(_:)` anywhere inside the proposal panel; see
    /// `HoverTipPresenter` for why the built-in tooltip cannot work there.
    func hoverTip(_ text: String) -> some View {
        overlay(HoverTipArea(text: text))
    }
}
