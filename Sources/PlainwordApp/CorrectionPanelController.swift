import AppKit
import PlainwordCore
import SwiftUI
import os

enum SuggestionPresentationMode: Equatable {
    case sourceOverlay
    case fallback
}

private enum CorrectionPresentationMetrics {
    static let maximumChipCount = 6
    static let chipSpacing: CGFloat = 7
    static let previewHeaderHeight: CGFloat = 22
}

/// Geometry of the expanded context receipt.
///
/// The panel reserves its height before SwiftUI lays it out, so both sides measure it
/// from here and the section is pinned to the same value when it renders.
private enum ContextReceiptMetrics {
    static let verticalPadding: CGFloat = 10
    static let rowHeight: CGFloat = 22
    static let rowSpacing: CGFloat = 3
    static let captionHeight: CGFloat = 14
    static let controlRowHeight: CGFloat = 22
    static let sectionSpacing: CGFloat = 7

    /// Depends only on how much was found, never on the switch — so flipping it moves
    /// nothing on screen.
    static func height(forItemCount count: Int) -> CGFloat {
        var height = verticalPadding * 2 + controlRowHeight
        if count > 0 {
            height += sectionSpacing + 1 + sectionSpacing
                + CGFloat(count) * rowHeight
                + CGFloat(count - 1) * rowSpacing
        }
        return height
    }
}

private enum SuggestionPreviewMode: Equatable {
    case revised
    case changes
}

private enum TransformShortcut: String, CaseIterable, Identifiable {
    case shorten
    case friendlier
    case moreFormal

    var id: Self { self }

    var title: String {
        switch self {
        case .shorten: "Shorten"
        case .friendlier: "Friendlier"
        case .moreFormal: "More formal"
        }
    }

    var instruction: String {
        switch self {
        case .shorten: "Make this shorter without losing its meaning."
        case .friendlier: "Make the tone friendlier."
        case .moreFormal: "Make the tone more formal."
        }
    }
}

private struct WrappingHStackLayout: Layout {
    private struct Placement {
        let origin: CGPoint
        let size: CGSize
    }

    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        let result = arrangement(for: subviews, maximumWidth: maximumWidth)
        return CGSize(
            width: proposal.width ?? result.size.width,
            height: result.size.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrangement(for: subviews, maximumWidth: bounds.width)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func arrangement(
        for subviews: Subviews,
        maximumWidth: CGFloat
    ) -> (placements: [Placement], size: CGSize) {
        guard !subviews.isEmpty else { return ([], .zero) }

        let availableWidth = max(maximumWidth, 1)
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let idealSize = subview.sizeThatFits(.unspecified)
            let size = idealSize.width > availableWidth
                ? subview.sizeThatFits(
                    ProposedViewSize(width: availableWidth, height: nil)
                )
                : idealSize
            let itemWidth = min(size.width, availableWidth)

            if x > 0, x + horizontalSpacing + itemWidth > availableWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if x > 0 {
                x += horizontalSpacing
            }

            placements.append(Placement(
                origin: CGPoint(x: x, y: y),
                size: CGSize(width: itemWidth, height: size.height)
            ))
            x += itemWidth
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x)
        }

        return (
            placements,
            CGSize(width: usedWidth, height: y + rowHeight)
        )
    }
}

private enum ProposalPointerEdge: Equatable {
    case top
    case bottom
}

@MainActor
private final class CorrectionPanelModel: ObservableObject {
    private struct State {
        var correctedText = ""
        var promptText = ""
        var suggestion: WritingSuggestion?
        var presentation: SuggestionPresentationMode = .fallback
        var previewMode: SuggestionPreviewMode = .changes
        var pointerEdge: ProposalPointerEdge = .top
        var phase: Phase = .processing
        var contentGeneration = 0
        var contentRequiresScrolling = false
        var showsPromptButton = false
        var showsPromptBackButton = false
        var showsSuggestionBackButton = false
        var promptTitle = "Transform selection"
        /// The prompt writes new text rather than changing text that is already there.
        var isComposing = false
        var contextReceipt: [ReadOnlyContextReceiptItem] = []
        var isContextReceiptExpanded = false
        var contextApplicationName = ""
        var isContextSendingEnabled = false
        var contextWasSentWithSuggestion = false
    }

    enum Phase: Equatable {
        case promptTrigger
        case promptTriggerLoading
        case prompting
        case processing
        case streaming
        case ready
        case unchanged
        case failure(String)
    }

    @Published private var state = State()

    var correctedText: String { state.correctedText }
    var promptText: String { state.promptText }
    var suggestion: WritingSuggestion? { state.suggestion }
    var presentation: SuggestionPresentationMode { state.presentation }
    var previewMode: SuggestionPreviewMode { state.previewMode }
    var pointerEdge: ProposalPointerEdge { state.pointerEdge }
    var phase: Phase { state.phase }
    var contentGeneration: Int { state.contentGeneration }
    var contentRequiresScrolling: Bool { state.contentRequiresScrolling }
    var showsPromptButton: Bool { state.showsPromptButton }
    var showsPromptBackButton: Bool { state.showsPromptBackButton }
    var promptTitle: String { state.promptTitle }
    var isComposing: Bool { state.isComposing }
    var contextReceipt: [ReadOnlyContextReceiptItem] { state.contextReceipt }
    var isContextReceiptExpanded: Bool { state.isContextReceiptExpanded }
    var contextApplicationName: String { state.contextApplicationName }
    var isContextSendingEnabled: Bool { state.isContextSendingEnabled }
    var contextWasSentWithSuggestion: Bool { state.contextWasSentWithSuggestion }
    var contextReceiptHeight: CGFloat {
        ContextReceiptMetrics.height(forItemCount: state.contextReceipt.count)
    }
    /// The receipt describes what a finished suggestion was given, so it only makes
    /// sense once there is a suggestion on screen.
    ///
    /// It stays available when nothing was read, because that is the only place the
    /// switch below it lives — hiding it would make turning reading back on impossible
    /// without a trip to Settings.
    var showsContextReceipt: Bool {
        !state.contextApplicationName.isEmpty
            && (state.phase == .ready || state.phase == .streaming)
    }
    var showsBackButton: Bool {
        state.showsPromptBackButton || state.showsSuggestionBackButton
    }
    var isWorking: Bool { phase == .processing || phase == .streaming }
    var canSubmitPrompt: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func begin(
        pointerEdge: ProposalPointerEdge,
        showsPromptButton: Bool = false,
        showsBackButton: Bool = false
    ) {
        state = State(
            pointerEdge: pointerEdge,
            contentGeneration: state.contentGeneration &+ 1,
            showsPromptButton: showsPromptButton,
            showsSuggestionBackButton: showsBackButton
        )
    }

    /// Keeps the content that is already on screen while taking on the controls a
    /// finished suggestion needs, so a streamed answer is not torn down and rebuilt.
    func adopt(showsPromptButton: Bool, showsBackButton: Bool) {
        state.showsPromptButton = showsPromptButton
        state.showsSuggestionBackButton = showsBackButton
    }

    func beginPrompt(
        pointerEdge: ProposalPointerEdge,
        showsBackButton: Bool,
        title: String,
        isComposing: Bool = false
    ) {
        state = State(
            pointerEdge: pointerEdge,
            phase: .prompting,
            contentGeneration: state.contentGeneration &+ 1,
            showsPromptBackButton: showsBackButton,
            promptTitle: title,
            isComposing: isComposing
        )
    }

    func beginPromptTrigger(pointerEdge: ProposalPointerEdge) {
        state = State(
            pointerEdge: pointerEdge,
            phase: .promptTrigger,
            contentGeneration: state.contentGeneration &+ 1
        )
    }

    func beginPromptTriggerLoading() {
        transition(to: .promptTriggerLoading, correctedText: "")
    }

    func setPromptText(_ promptText: String) {
        guard state.promptText != promptText else { return }
        state.promptText = String(promptText.prefix(500))
    }

    func transition(
        to phase: Phase,
        correctedText: String? = nil,
        suggestion: WritingSuggestion? = nil,
        presentation: SuggestionPresentationMode? = nil,
        previewMode: SuggestionPreviewMode? = nil,
        animated: Bool = true
    ) {
        let nextKind = contentKind(for: phase)
        let currentKind = contentKind(for: state.phase)
        let nextState = State(
            correctedText: correctedText ?? state.correctedText,
            promptText: state.promptText,
            suggestion: suggestion ?? state.suggestion,
            presentation: presentation ?? state.presentation,
            previewMode: previewMode ?? state.previewMode,
            pointerEdge: state.pointerEdge,
            phase: phase,
            contentGeneration: nextKind == currentKind
                ? state.contentGeneration
                : state.contentGeneration &+ 1,
            showsPromptButton: state.showsPromptButton,
            showsPromptBackButton: state.showsPromptBackButton,
            showsSuggestionBackButton: state.showsSuggestionBackButton,
            promptTitle: state.promptTitle,
            isComposing: state.isComposing,
            contextReceipt: state.contextReceipt,
            isContextReceiptExpanded: state.isContextReceiptExpanded,
            contextApplicationName: state.contextApplicationName,
            isContextSendingEnabled: state.isContextSendingEnabled,
            contextWasSentWithSuggestion: state.contextWasSentWithSuggestion
        )
        let changes = { self.state = nextState }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.smooth(duration: 0.18), changes)
        } else {
            changes()
        }
    }

    func setContextReceipt(
        _ contextReceipt: [ReadOnlyContextReceiptItem],
        applicationName: String,
        isSendingEnabled: Bool,
        wasSentWithSuggestion: Bool
    ) {
        state.contextReceipt = contextReceipt
        state.contextApplicationName = applicationName
        state.isContextSendingEnabled = isSendingEnabled
        state.contextWasSentWithSuggestion = wasSentWithSuggestion
        state.isContextReceiptExpanded = false
    }

    func setContextSendingEnabled(_ isEnabled: Bool) {
        guard state.isContextSendingEnabled != isEnabled else { return }
        let changes = { self.state.isContextSendingEnabled = isEnabled }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            changes()
        } else {
            withAnimation(.smooth(duration: 0.18), changes)
        }
    }

    func setContextReceiptExpanded(_ isExpanded: Bool) {
        guard state.isContextReceiptExpanded != isExpanded else { return }
        let changes = { self.state.isContextReceiptExpanded = isExpanded }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            changes()
        } else {
            withAnimation(.smooth(duration: 0.18), changes)
        }
    }

    func setPresentation(_ presentation: SuggestionPresentationMode) {
        guard state.presentation != presentation else { return }
        state.presentation = presentation
    }

    func setPreviewMode(_ previewMode: SuggestionPreviewMode) {
        guard state.previewMode != previewMode else { return }
        state.previewMode = previewMode
    }

    func setPointerEdge(_ pointerEdge: ProposalPointerEdge) {
        guard state.pointerEdge != pointerEdge else { return }
        state.pointerEdge = pointerEdge
    }

    func setContentRequiresScrolling(_ contentRequiresScrolling: Bool) {
        guard state.contentRequiresScrolling != contentRequiresScrolling else { return }
        state.contentRequiresScrolling = contentRequiresScrolling
    }

    private func contentKind(for phase: Phase) -> Int {
        switch phase {
        case .promptTrigger, .promptTriggerLoading: 0
        case .prompting: 1
        case .processing: 2
        case .streaming, .ready: 3
        case .unchanged: 4
        case .failure: 5
        }
    }
}

@MainActor
final class CorrectionPanelController {
    private enum VerticalPlacement: Equatable {
        case below
        case above

        var pointerEdge: ProposalPointerEdge {
            switch self {
            case .below: .top
            case .above: .bottom
            }
        }
    }

    private let model = CorrectionPanelModel()
    private let panel: CorrectionPanel
    private let compactPanelWidth: CGFloat = 286
    private let regularPanelWidth: CGFloat = 360
    private let maximumPanelWidth: CGFloat = 560
    private let maximumPanelHeight: CGFloat = 520
    private let pointerHeight: CGFloat = 7
    private var anchor = CGRect.zero
    private var targetScreen: NSScreen?
    private var verticalPlacement: VerticalPlacement = .below
    private var onAccept: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var onBack: (() -> Void)?
    private var onRequestPrompt: (() -> Void)?
    private var onSubmitPrompt: ((String) -> Void)?
    private var onSetContextSendingEnabled: ((Bool) -> Void)?
    private var targetFrame: NSRect?
    private var userPositionedOrigin: NSPoint?
    private var streamingResizeTask: Task<Void, Never>?
    private var visibilityGeneration = 0

    var windowNumber: Int { panel.windowNumber }
    var screenFrame: CGRect? { panel.screen?.frame ?? targetScreen?.frame }

    private lazy var hostingView: NSHostingView<AnyView> = {
        let view = NSHostingView(
            rootView: AnyView(
                CrossAppProposalView(
                    model: model,
                    onAccept: { [weak self] in self?.onAccept?() },
                    onDismiss: { [weak self] in self?.onDismiss?() },
                    onBack: { [weak self] in self?.onBack?() },
                    onRequestPrompt: { [weak self] in self?.onRequestPrompt?() },
                    onSubmitPrompt: { [weak self] prompt in
                        self?.onSubmitPrompt?(prompt)
                    },
                    onPreviewModeChange: { [weak self] previewMode in
                        self?.updatePreviewMode(previewMode)
                    },
                    onToggleContextReceipt: { [weak self] in
                        self?.toggleContextReceipt()
                    },
                    onSetContextSendingEnabled: { [weak self] isEnabled in
                        self?.setContextSendingEnabled(isEnabled)
                    },
                    onDrag: { [weak self] origin in
                        self?.movePanel(to: origin)
                    }
                )
            )
        )
        view.sizingOptions = []
        view.autoresizingMask = [.width, .height]
        return view
    }()

    init() {
        panel = CorrectionPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // The source application remains active while this nonactivating panel is
        // visible. Keep the proposal above that application's windows even when a
        // click causes it to reorder its own normal-level windows. The cross-app
        // controller suspends the panel when another app takes over this display.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        // Tooltips are driven by mouse-moved tracking. This panel floats over another
        // application while Plainword is in the background, so it has to opt in or the
        // pointer is only ever heard from on a click.
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hostingView
        // A zero-sized window proposes nothing to lay out against, so SwiftUI's first
        // pass measures the content at its ideal width, which for a line of text is far
        // wider than the panel ever becomes. Start at the ordinary proposal size so that
        // first pass is already close to what appears.
        panel.setContentSize(NSSize(width: regularPanelWidth, height: 200))
    }

    func showProcessing(
        near anchor: CGRect,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onBack = nil
        self.onRequestPrompt = nil
        self.onSubmitPrompt = nil
        cancelScheduledStreamingResize()
        model.begin(pointerEdge: verticalPlacement.pointerEdge)
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: false)
        presentPanel()
    }

    func showSuggestion(
        _ suggestion: WritingSuggestion,
        presentation: SuggestionPresentationMode,
        contextReceipt: [ReadOnlyContextReceiptItem] = [],
        contextApplicationName: String = "",
        isContextSendingEnabled: Bool = false,
        contextWasSentWithSuggestion: Bool = false,
        near anchor: CGRect,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        onRequestPrompt: @escaping () -> Void,
        onSetContextSendingEnabled: ((Bool) -> Void)? = nil
    ) {
        let shouldAnimateResize = panel.isVisible
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onBack = onBack
        self.onRequestPrompt = onRequestPrompt
        self.onSubmitPrompt = nil
        self.onSetContextSendingEnabled = onSetContextSendingEnabled
        cancelScheduledStreamingResize()
        // Text that streamed in is already the answer. Settling it in place reads as the
        // same result gaining its controls, so it is adopted rather than replaced.
        if model.phase == .streaming {
            model.adopt(
                showsPromptButton: suggestion.kind != .composition,
                showsBackButton: onBack != nil
            )
        } else {
            model.begin(
                pointerEdge: verticalPlacement.pointerEdge,
                // A draft is not in the field yet, so there is nothing there to
                // transform. Once it is inserted the ordinary transform shortcut
                // reaches it.
                showsPromptButton: suggestion.kind != .composition,
                showsBackButton: onBack != nil
            )
        }
        model.setContextReceipt(
            contextReceipt,
            applicationName: contextApplicationName,
            isSendingEnabled: isContextSendingEnabled,
            wasSentWithSuggestion: contextWasSentWithSuggestion
        )
        model.transition(
            to: .ready,
            correctedText: suggestion.replacementText,
            suggestion: suggestion,
            presentation: presentation,
            previewMode: suggestion.kind == .rewrite ? .revised : .changes,
            animated: false
        )
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: shouldAnimateResize)
        presentPanel()
    }

    func showPrompt(
        near anchor: CGRect,
        title: String,
        isComposing: Bool = false,
        onSubmit: @escaping (String) -> Void,
        onBack: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.onAccept = nil
        self.onDismiss = onDismiss
        self.onBack = onBack
        self.onRequestPrompt = nil
        self.onSubmitPrompt = onSubmit
        cancelScheduledStreamingResize()
        model.beginPrompt(
            pointerEdge: verticalPlacement.pointerEdge,
            showsBackButton: onBack != nil,
            title: title,
            isComposing: isComposing
        )
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: panel.isVisible)
        presentPanel(makeKey: true)
    }

    func showPromptTrigger(
        near anchor: CGRect,
        onOpen: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onAccept = nil
        self.onDismiss = onDismiss
        self.onBack = nil
        self.onRequestPrompt = onOpen
        self.onSubmitPrompt = nil
        cancelScheduledStreamingResize()
        model.beginPromptTrigger(pointerEdge: verticalPlacement.pointerEdge)
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: panel.isVisible)
        presentPanel()
    }

    func showPromptTriggerLoading() {
        // A restarted review comes back here from whatever its predecessor had already
        // streamed, so the text it left goes with it rather than sizing the marker.
        cancelScheduledStreamingResize()
        model.beginPromptTriggerLoading()
        targetFrame = nil
        resizeForContent(animated: true)
    }

    func updateSuggestionPresentation(
        _ presentation: SuggestionPresentationMode,
        near anchor: CGRect,
        animated: Bool = true
    ) {
        model.setPresentation(presentation)
        reposition(near: anchor, animated: animated)
        targetFrame = nil
        resizeForContent(animated: animated)
    }

    private func updatePreviewMode(_ previewMode: SuggestionPreviewMode) {
        model.setPreviewMode(previewMode)
        targetFrame = nil
        resizeForContent(animated: true)
    }

    /// The switch records a preference. It issues no request, does not disturb the
    /// suggestion on screen, and does not change the panel's size — nothing moves.
    private func setContextSendingEnabled(_ isEnabled: Bool) {
        model.setContextSendingEnabled(isEnabled)
        onSetContextSendingEnabled?(isEnabled)
    }

    private func toggleContextReceipt() {
        model.setContextReceiptExpanded(!model.isContextReceiptExpanded)
        targetFrame = nil
        // Matches the 0.18s content animation in the model, so the panel and the section
        // inside it grow together instead of the frame snapping ahead of the rows.
        resizeForContent(animated: true)
    }

    func restoreVisibility() {
        visibilityGeneration += 1
        panel.alphaValue = 1
        // A suspended panel keeps answering resizes it cannot draw, so settle the
        // layout before it comes back rather than letting the stale size show.
        settleContentLayout()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    /// Removes the panel from the global window stack while preserving its state.
    func suspendVisibility() {
        visibilityGeneration += 1
        panel.alphaValue = 1
        panel.orderOut(nil)
    }

    /// Moves the panel with the source window it is anchored to.
    ///
    /// This is a translation rather than a re-anchor so it also carries a panel the user
    /// has dragged: the proposal keeps the place the user put it relative to the text.
    func translate(by delta: CGSize) {
        guard abs(delta.width) >= 1 || abs(delta.height) >= 1 else { return }

        anchor = anchor.offsetBy(dx: delta.width, dy: delta.height)
        targetScreen = screen(containing: anchor)
        let size = panel.frame.size
        let origin = constrainedOrigin(
            NSPoint(
                x: panel.frame.origin.x + delta.width,
                y: panel.frame.origin.y + delta.height
            ),
            for: size,
            preferringMouseScreen: false
        )
        if userPositionedOrigin != nil {
            userPositionedOrigin = origin
        }
        let frame = NSRect(origin: origin, size: size)
        guard targetFrame != frame else { return }
        targetFrame = frame
        // A window drag emits a continuous stream of moves. Animating each one would
        // leave the panel trailing behind the text it points at.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        CATransaction.commit()
    }

    func reposition(near anchor: CGRect, animated: Bool) {
        let nextAnchor = normalizedAnchor(resolvedAnchor(anchor))
        let nextScreen = screen(containing: nextAnchor)
        if nextScreen === targetScreen,
           abs(nextAnchor.midX - self.anchor.midX) < 3,
           abs(nextAnchor.midY - self.anchor.midY) < 3 {
            return
        }

        configurePlacement(near: nextAnchor, preservingPlacement: true)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: animated)
    }

    func updateStreamingText(_ text: String) {
        guard !text.isEmpty else { return }
        let isEnteringStreaming = model.phase != .streaming
        model.transition(
            to: .streaming,
            correctedText: text,
            animated: isEnteringStreaming
        )
        if isEnteringStreaming {
            // A review starts as a small marker, and a transform as a single line. The
            // side of the field that fit either one may not fit a growing answer, so the
            // panel picks its side again the moment text starts arriving.
            configurePlacement(near: anchor)
            model.setPointerEdge(verticalPlacement.pointerEdge)
            targetFrame = nil
            resizeForContent(animated: true)
        } else {
            scheduleStreamingResize()
        }
    }

    func showReady(_ text: String) {
        cancelScheduledStreamingResize()
        model.transition(to: .ready, correctedText: text)
        resizeForContent(animated: true)
    }

    func showUnchanged() {
        cancelScheduledStreamingResize()
        model.transition(to: .unchanged, correctedText: "")
        // The review starts as a tiny trigger, so its original above/below choice
        // may no longer fit once the full result appears. Re-evaluate placement with
        // the result's actual size, matching the transform prompt's behavior.
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: true)
    }

    func showFailure(_ message: String) {
        cancelScheduledStreamingResize()
        model.transition(to: .failure(message))
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: true)
    }

    func dismiss() {
        cancelScheduledStreamingResize()
        onAccept = nil
        onDismiss = nil
        onBack = nil
        onRequestPrompt = nil
        onSubmitPrompt = nil
        userPositionedOrigin = nil
        guard panel.isVisible else { return }

        visibilityGeneration += 1
        let generation = visibilityGeneration
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        }
    }

    private func configurePlacement(
        near candidate: CGRect,
        preservingPlacement: Bool = false
    ) {
        let previousScreen = targetScreen
        let previousPlacement = verticalPlacement
        anchor = normalizedAnchor(resolvedAnchor(candidate))
        targetScreen = screen(containing: anchor)

        if preservingPlacement,
           previousScreen === targetScreen,
           shouldKeep(
               previousPlacement,
               near: anchor,
               on: targetScreen
           ) {
            verticalPlacement = previousPlacement
        } else {
            verticalPlacement = placement(near: anchor, on: targetScreen)
        }
    }

    private func resizeForContent(animated: Bool) {
        let layout = targetLayout
        let size = layout.size
        model.setContentRequiresScrolling(layout.contentRequiresScrolling)
        let frameOrigin: NSPoint
        if let userPositionedOrigin {
            frameOrigin = constrainedOrigin(userPositionedOrigin, for: size)
            self.userPositionedOrigin = frameOrigin
        } else {
            frameOrigin = origin(for: size, near: anchor)
        }
        let frame = NSRect(origin: frameOrigin, size: size)
        guard targetFrame != frame else { return }
        targetFrame = frame

        if animated,
           panel.isVisible,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            // Frames set while the panel is hidden must not pick up an implicit layer
            // animation, or the resize plays out the moment the panel is ordered in.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(frame, display: true)
            CATransaction.commit()
        }
    }

    private func scheduleStreamingResize() {
        guard streamingResizeTask == nil else { return }
        streamingResizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            self.streamingResizeTask = nil
            self.resizeForContent(animated: true)
        }
    }

    private func cancelScheduledStreamingResize() {
        streamingResizeTask?.cancel()
        streamingResizeTask = nil
    }

    private func movePanel(to proposedOrigin: NSPoint) {
        let origin = constrainedOrigin(proposedOrigin, for: panel.frame.size)
        userPositionedOrigin = origin
        targetFrame = NSRect(origin: origin, size: panel.frame.size)
        panel.setFrameOrigin(origin)
    }

    private func constrainedOrigin(
        _ origin: NSPoint,
        for size: NSSize,
        preferringMouseScreen: Bool = true
    ) -> NSPoint {
        let proposedFrame = NSRect(origin: origin, size: size)
        // Following a window is driven by the window, not by the pointer, which may be
        // resting on another display and would otherwise pull the panel over to it.
        let mouseScreen = preferringMouseScreen
            ? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            : nil
        let frameScreen = NSScreen.screens.max { lhs, rhs in
            let lhsIntersection = lhs.frame.intersection(proposedFrame)
            let rhsIntersection = rhs.frame.intersection(proposedFrame)
            return lhsIntersection.width * lhsIntersection.height
                < rhsIntersection.width * rhsIntersection.height
        }
        guard let visibleFrame = (mouseScreen ?? frameScreen ?? targetScreen)?.visibleFrame
            .insetBy(dx: 10, dy: 10) else {
            return origin
        }

        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }

    private func presentPanel(makeKey: Bool = false) {
        visibilityGeneration += 1
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let isFirstAppearance = !panel.isVisible
        if reducesMotion {
            panel.alphaValue = 1
        } else if isFirstAppearance {
            panel.alphaValue = 0
        }

        if isFirstAppearance {
            settleContentLayout()
        }

        // A global shortcut leaves the source application active. Unlike
        // makeKeyAndOrderFront, this can raise Plainword's panel above another
        // application's key window. Make it key separately so the prompt accepts
        // typing without activating Plainword or changing the window ordering.
        panel.orderFrontRegardless()
        if makeKey {
            panel.makeKey()
        }
        // The shadow is traced from what the panel draws. Ordering in with a shadow
        // cached from an earlier size would show a larger shape around the panel.
        panel.invalidateShadow()

        guard !reducesMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            // Only the fade belongs to this group. Implicit animation here would also
            // catch the content's own first layout and play it out as a resize.
            panel.animator().alphaValue = 1
        }
    }

    /// Draws the content at its final size before the panel is ordered in.
    ///
    /// A hidden window lays out lazily, so the first frame after ordering in can still
    /// carry the geometry SwiftUI last settled on. Flushing layout and drawing while the
    /// panel is invisible means what appears is already the right shape, instead of a
    /// larger one shrinking into place.
    private func settleContentLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostingView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.commit()
    }

    private struct PanelLayout {
        let size: NSSize
        let contentRequiresScrolling: Bool
    }

    private var targetLayout: PanelLayout {
        if model.phase == .promptTrigger || model.phase == .promptTriggerLoading {
            return PanelLayout(
                size: NSSize(width: 48, height: 49),
                contentRequiresScrolling: false
            )
        }

        let contentHeight: CGFloat
        switch model.phase {
        case .promptTrigger, .promptTriggerLoading:
            contentHeight = 0
        case .prompting:
            // Composing drops the transform shortcuts, and with them their row.
            contentHeight = model.isComposing ? 86 : 108
        case .processing, .unchanged:
            contentHeight = 40
        case .streaming:
            contentHeight = 26 + measuredTextHeight(model.correctedText)
        case .failure(let message):
            contentHeight = 18 + measuredTextHeight(message, maximum: 72)
        case .ready:
            contentHeight = readyContentHeight
        }

        let footerHeight: CGFloat = model.phase == .prompting
            || model.phase == .processing
            || model.phase == .streaming
            || model.phase == .ready ? 53 : 0
        let naturalHeight = pointerHeight + 43 + 1
            + contentHeight
            + contextReceiptHeight
            + footerHeight
        let height = min(
            ceil(naturalHeight),
            maximumPanelHeight,
            availablePanelHeight
        )
        let canScroll = model.phase == .streaming || model.phase == .ready
        return PanelLayout(
            size: NSSize(width: panelWidth, height: height),
            contentRequiresScrolling: canScroll && naturalHeight > height + 0.5
        )
    }

    private var targetSize: NSSize {
        targetLayout.size
    }

    private var contextReceiptHeight: CGFloat {
        guard model.showsContextReceipt, model.isContextReceiptExpanded else { return 0 }
        // The separator above the section belongs to it, since both appear together.
        // Same expression the section renders itself at, so the two cannot disagree.
        return 1 + model.contextReceiptHeight
    }

    private var availablePanelHeight: CGFloat {
        guard let screen = targetScreen else { return maximumPanelHeight }
        let screenHeight = screen.visibleFrame.insetBy(dx: 10, dy: 10).height
        let anchorHeight = max(
            availableRoom(.above, near: anchor, on: screen),
            availableRoom(.below, near: anchor, on: screen)
        )
        return max(160, min(screenHeight, anchorHeight))
    }

    private var readyContentHeight: CGFloat {
        guard let suggestion = model.suggestion else { return 70 }
        switch suggestion.kind {
        case .correction:
            if model.presentation == .sourceOverlay {
                return inlineCorrectionContentHeight(for: suggestion)
            }
            return fallbackPreviewContentHeight(for: suggestion)
        case .completion:
            return 46 + measuredTextHeight(
                suggestion.changes.first?.replacement ?? suggestion.replacementText,
                font: .systemFont(ofSize: 14, weight: .medium),
                lineSpacing: 2
            )
        case .rewrite:
            return fallbackPreviewContentHeight(for: suggestion)
        case .composition:
            return 46 + measuredTextHeight(
                suggestion.replacementText,
                lineSpacing: 2
            )
        }
    }

    private func fallbackPreviewContentHeight(
        for suggestion: WritingSuggestion
    ) -> CGFloat {
        let text: String
        switch model.previewMode {
        case .revised:
            text = suggestion.replacementText
        case .changes:
            text = WritingDiffPlanner.make(
                original: suggestion.originalText,
                replacement: suggestion.replacementText
            ).map(\.text).joined()
        }
        return 26
            + CorrectionPresentationMetrics.previewHeaderHeight
            + 8
            + measuredTextHeight(text, lineSpacing: 2)
    }

    private func inlineCorrectionContentHeight(
        for suggestion: WritingSuggestion
    ) -> CGFloat {
        let phrases = replacementPhrases(for: suggestion)
        if phrases.count > CorrectionPresentationMetrics.maximumChipCount {
            return 46 + measuredTextHeight(
                suggestion.replacementText,
                font: .systemFont(ofSize: 14, weight: .medium),
                lineSpacing: 2
            )
        }

        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let availableWidth = max(panelWidth - 26, 1)
        let chipSizes = phrases.map { phrase -> CGSize in
            let naturalWidth = ceil(NSString(string: phrase).boundingRect(
                with: NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: 24
                ),
                options: [.usesFontLeading],
                attributes: [.font: font]
            ).width) + 16
            let width = min(naturalWidth, availableWidth)
            let height = naturalWidth <= availableWidth
                ? 32
                : measuredTextHeight(
                    phrase,
                    font: font,
                    width: availableWidth - 16
                ) + 12
            return CGSize(width: width, height: height)
        }

        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var chipsHeight: CGFloat = 0
        for size in chipSizes {
            let spacing = rowWidth > 0 ? CorrectionPresentationMetrics.chipSpacing : 0
            if rowWidth > 0, rowWidth + spacing + size.width > availableWidth {
                chipsHeight += rowHeight + CorrectionPresentationMetrics.chipSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        chipsHeight += rowHeight

        // 26 points of outer padding, a 12-point label, and the 8-point label gap.
        return 46 + chipsHeight
    }

    private var panelWidth: CGFloat {
        let availableWidth = max(
            compactPanelWidth,
            (targetScreen?.visibleFrame.width ?? maximumPanelWidth) - 20
        )
        guard let suggestion = model.suggestion else {
            return min(regularPanelWidth, availableWidth)
        }

        let minimumWidth: CGFloat
        let text: String
        switch suggestion.kind {
        case .correction where model.presentation == .sourceOverlay:
            minimumWidth = compactPanelWidth
            text = replacementPhrases(for: suggestion).joined(separator: "   ")
        case .completion:
            minimumWidth = compactPanelWidth
            text = suggestion.changes.first?.replacement ?? suggestion.replacementText
        case .correction, .rewrite, .composition:
            minimumWidth = regularPanelWidth
            text = suggestion.replacementText
        }

        let measuredWidth = NSString(string: text).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 24),
            options: [.usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]
        ).width
        let preferredWidth = min(
            maximumPanelWidth,
            max(minimumWidth, ceil(measuredWidth) + 28)
        )
        return min(preferredWidth, availableWidth)
    }

    private func measuredDiffHeight(_ suggestion: WritingSuggestion) -> CGFloat {
        let text = WritingDiffPlanner.make(
            original: suggestion.originalText,
            replacement: suggestion.replacementText
        ).map(\.text).joined()
        return measuredTextHeight(text, lineSpacing: 2)
    }

    private func measuredTextHeight(
        _ text: String,
        maximum: CGFloat = .greatestFiniteMagnitude,
        font: NSFont = .systemFont(ofSize: 13),
        width: CGFloat? = nil,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {
        guard !text.isEmpty else { return 20 }
        let bounds = NSString(string: text).boundingRect(
            with: NSSize(
                width: max(width ?? panelWidth - 28, 1),
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = max(ceil(font.boundingRectForFont.height), 1)
        let lineCount = max(ceil(bounds.height / lineHeight), 1)
        let measuredHeight = ceil(bounds.height)
            + CGFloat(lineCount - 1) * lineSpacing
        return min(max(measuredHeight, 20), maximum)
    }

    private func replacementPhrases(for suggestion: WritingSuggestion) -> [String] {
        let phrases = suggestion.changes.compactMap { change in
            let phrase = change.replacement
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return phrase.isEmpty ? nil : phrase
        }
        return phrases.isEmpty ? ["Delete marked text"] : phrases
    }

    private func resolvedAnchor(_ candidate: CGRect) -> CGRect {
        guard candidate != .zero else {
            let mouse = NSEvent.mouseLocation
            return CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        }
        return candidate
    }

    private func normalizedAnchor(_ anchor: CGRect) -> CGRect {
        CGRect(
            x: round(anchor.minX),
            y: round(anchor.minY),
            width: max(round(anchor.width), 1),
            height: max(round(anchor.height), 1)
        )
    }

    private func screen(containing anchor: CGRect) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func placement(near anchor: CGRect, on screen: NSScreen?) -> VerticalPlacement {
        guard let screen else { return .below }
        let roomBelow = availableRoom(.below, near: anchor, on: screen)
        let roomAbove = availableRoom(.above, near: anchor, on: screen)
        let requiredHeight = targetSize.height + 4
        if roomBelow >= requiredHeight { return .below }
        if roomAbove >= requiredHeight { return .above }
        return roomBelow >= roomAbove ? .below : .above
    }

    private func shouldKeep(
        _ placement: VerticalPlacement,
        near anchor: CGRect,
        on screen: NSScreen?
    ) -> Bool {
        guard let screen else { return true }
        let currentRoom = availableRoom(placement, near: anchor, on: screen)
        let otherPlacement: VerticalPlacement = placement == .below ? .above : .below
        let otherRoom = availableRoom(otherPlacement, near: anchor, on: screen)
        let requiredHeight = targetSize.height + 4

        if currentRoom >= requiredHeight { return true }
        // If neither side fits, require a meaningful improvement before flipping.
        return otherRoom < requiredHeight && otherRoom - currentRoom < 40
    }

    private func availableRoom(
        _ placement: VerticalPlacement,
        near anchor: CGRect,
        on screen: NSScreen
    ) -> CGFloat {
        let visibleFrame = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        switch placement {
        case .below:
            return anchor.minY - visibleFrame.minY - 4
        case .above:
            return visibleFrame.maxY - anchor.maxY - 4
        }
    }

    private func origin(for panelSize: NSSize, near anchor: CGRect) -> CGPoint {
        guard let screen = targetScreen else { return .zero }
        let visibleFrame = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let preferredX = model.phase == .promptTrigger
            || model.phase == .promptTriggerLoading
            ? anchor.midX - panelSize.width / 2
            : anchor.midX - 42
        let x = min(max(preferredX, visibleFrame.minX), visibleFrame.maxX - panelSize.width)

        let preferredY: CGFloat
        switch verticalPlacement {
        case .below:
            preferredY = anchor.minY - panelSize.height - 4
        case .above:
            preferredY = anchor.maxY + 4
        }
        let y = min(
            max(preferredY, visibleFrame.minY),
            visibleFrame.maxY - panelSize.height
        )
        return CGPoint(x: x, y: y)
    }
}

private final class CorrectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Text that draws itself in while the rest of it is still on its way.
///
/// Providers send an answer in uneven bursts, so text that appeared the instant each
/// burst landed would jump and then sit still. This reveals what has arrived at a pace
/// of its own, keeps the newest few characters fading up behind a pulsing cursor, and
/// catches up quickly whenever it falls behind, so the panel reads as writing rather
/// than as waiting.
private struct StreamingTextView: View {
    let text: String
    let isStreaming: Bool

    /// What the reveal is working towards.
    ///
    /// The ticker below keeps the view value it was created with, so it cannot see
    /// `text` grow: reading it there would freeze the reveal on the first fragment that
    /// arrived. State is read through shared storage instead, which stays current, so
    /// each arrival is carried across in here.
    private struct Pacing: Equatable {
        var targetCount = 0
        var isRevealing = false
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedCount = 0
    @State private var caretPhase: Double = 0
    @State private var pacing = Pacing()
    @State private var revealFrames = 0

    /// How many characters at the end are still fading up.
    private static let fadeLength = 5
    private static let frameInterval: Double = 1.0 / 30
    private static let caretPeriod: Double = 1.1

    var body: some View {
        rendered
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(
                of: Pacing(
                    targetCount: text.count,
                    isRevealing: isStreaming && !reduceMotion
                ),
                initial: true
            ) { _, next in
                pacing = next
                // Text that is not being drawn in, and text that shrank because a
                // request started over, is simply shown as it stands.
                if !next.isRevealing || revealedCount > next.targetCount {
                    revealedCount = next.targetCount
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.frameInterval))
                    advance()
                }
            }
            .accessibilityLabel(text)
    }

    private var rendered: Text {
        guard isStreaming else { return Text(text) }
        guard !reduceMotion else { return Text(text) + caret }

        let revealed = String(text.prefix(max(revealedCount, 0)))
        // The trail belongs to text that is still being drawn in. Once the panel has
        // caught up with what arrived, every character it shows is settled.
        guard revealed.count < text.count else { return Text(revealed) + caret }

        let fadeLength = min(Self.fadeLength, revealed.count)
        var composed = Text(String(revealed.dropLast(fadeLength)))
        for (offset, character) in revealed.suffix(fadeLength).enumerated() {
            let opacity = 1 - Double(offset + 1) / Double(fadeLength + 1)
            composed = composed + Text(String(character))
                .foregroundStyle(PlainwordTheme.textPrimary.opacity(opacity))
        }
        return composed + caret
    }

    private var caret: Text {
        let pulse = reduceMotion
            ? 1
            : 0.3 + 0.7 * (0.5 + 0.5 * cos(caretPhase * 2 * .pi / Self.caretPeriod))
        return Text(" \u{258D}")
            .foregroundStyle(PlainwordTheme.accent.opacity(pulse))
    }

    private func advance() {
        let pacing = self.pacing
        guard pacing.isRevealing else { return }
        // TEMPORARY reveal diagnostics.
        if revealedCount < pacing.targetCount {
            revealFrames += 1
        } else if revealFrames > 0 {
            os_log(
                "reveal caught up: %{public}d chars in %{public}d frames",
                revealedCount,
                revealFrames
            )
            revealFrames = 0
        }
        if revealedCount < pacing.targetCount {
            // A sixth of what is left each frame: quick when a large burst lands, and
            // gentle over the last few characters.
            revealedCount += max(1, (pacing.targetCount - revealedCount) / 6)
        }
        caretPhase = (caretPhase + Self.frameInterval)
            .truncatingRemainder(dividingBy: Self.caretPeriod)
    }
}

private struct PlainwordLoadingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var size: CGFloat = 22

    var body: some View {
        PlainwordBrandMark(size: size)
            .scaleEffect(reduceMotion ? 1 : (isAnimating ? 1 : 0.92))
            .shadow(
                color: PlainwordTheme.accent.opacity(isAnimating ? 0.55 : 0.2),
                radius: isAnimating ? size * 0.28 : size * 0.12
            )
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.82).repeatForever(autoreverses: true),
                value: isAnimating
            )
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.9), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: size * 0.32, height: size * 1.6)
                    .rotationEffect(.degrees(24))
                    .offset(x: isAnimating ? size * 1.25 : -size * 1.25)
                    .animation(
                        .linear(duration: 1.15).repeatForever(autoreverses: false),
                        value: isAnimating
                    )
                    .mask(PlainwordBrandMark(size: size))
                }
            }
            .frame(width: size, height: size)
            .onAppear { isAnimating = !reduceMotion }
            .onChange(of: reduceMotion) { _, shouldReduceMotion in
                isAnimating = !shouldReduceMotion
            }
            .accessibilityHidden(true)
    }
}

private struct CrossAppProposalView: View {
    @ObservedObject var model: CorrectionPanelModel
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onBack: () -> Void
    let onRequestPrompt: () -> Void
    let onSubmitPrompt: (String) -> Void
    let onPreviewModeChange: (SuggestionPreviewMode) -> Void
    let onToggleContextReceipt: () -> Void
    let onSetContextSendingEnabled: (Bool) -> Void
    let onDrag: (NSPoint) -> Void
    @FocusState private var promptFocused: Bool
    @State private var hoveredTransformShortcut: TransformShortcut?

    @ViewBuilder
    var body: some View {
        if model.phase == .promptTrigger || model.phase == .promptTriggerLoading {
            promptTrigger
        } else {
            ZStack(alignment: model.pointerEdge == .top ? .topLeading : .bottomLeading) {
                proposalSurface
                    .padding(model.pointerEdge == .top ? .top : .bottom, 7)

                ProposalPointer(edge: model.pointerEdge)
                    .fill(PlainwordTheme.surface)
                    .overlay {
                        ProposalPointer(edge: model.pointerEdge)
                            .stroke(PlainwordTheme.strongSeparator, lineWidth: 1)
                    }
                    .frame(width: 13, height: 8)
                    .offset(x: 36)
            }
            .foregroundStyle(PlainwordTheme.textPrimary)
            .background(.clear)
            .onExitCommand {
                if model.phase == .prompting, model.showsPromptBackButton {
                    onBack()
                } else {
                    onDismiss()
                }
            }
            .onChange(of: model.phase) { _, phase in
                guard phase == .prompting else { return }
                DispatchQueue.main.async { promptFocused = true }
            }
        }
    }

    private var promptTrigger: some View {
        ZStack(alignment: model.pointerEdge == .top ? .top : .bottom) {
            Button {
                guard model.phase != .promptTriggerLoading else { return }
                onRequestPrompt()
            } label: {
                Group {
                    if model.phase == .promptTriggerLoading {
                        PlainwordLoadingMark(size: 24)
                    } else {
                        PlainwordBrandMark(size: 24)
                    }
                }
                    .frame(width: 42, height: 42)
                    .background(PlainwordTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(PlainwordTheme.strongSeparator, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(model.phase != .promptTriggerLoading)
            .help(model.phase == .promptTriggerLoading ? "Reviewing text" : "Review text")
            .accessibilityLabel(
                model.phase == .promptTriggerLoading ? "Reviewing text" : "Review text"
            )
            .padding(model.pointerEdge == .top ? .top : .bottom, 7)

            ProposalPointer(edge: model.pointerEdge)
                .fill(PlainwordTheme.surface)
                .overlay {
                    ProposalPointer(edge: model.pointerEdge)
                        .stroke(PlainwordTheme.strongSeparator, lineWidth: 1)
                }
                .frame(width: 13, height: 8)
        }
        .frame(width: 48, height: 49)
        .background(.clear)
    }

    private var proposalSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)

            ZStack(alignment: .topLeading) {
                phaseContent
                    .id(model.contentGeneration)
                    .zIndex(Double(model.contentGeneration))
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .background(PlainwordTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(PlainwordTheme.strongSeparator, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .promptTrigger, .promptTriggerLoading:
            EmptyView()
        case .prompting:
            promptingContent
        case .processing:
            processingContent
        case .unchanged:
            statusContent("No changes suggested.")
        case .failure(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(PlainwordTheme.danger)
                .lineLimit(4)
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .streaming, .ready:
            suggestionContent
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.showsBackButton {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 21, height: 21)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PlainwordTheme.textSecondary)
                .help("Back to previous suggestion")
                .accessibilityLabel("Back to previous suggestion")
            }

            HStack(spacing: 8) {
                if model.isWorking {
                    PlainwordLoadingMark(size: 21)
                        .frame(width: 21, height: 21)
                } else {
                    PlainwordBrandMark(size: 21)
                }

                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .overlay {
                PanelDragArea(onDrag: onDrag)
            }

            if model.showsPromptButton {
                Button(action: onRequestPrompt) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 21, height: 21)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PlainwordTheme.textSecondary)
                .help("Tell Plainword how to change this text")
                .accessibilityLabel("Custom edit")
            }

            Text(headerDetail)
                .font(.system(size: 11))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .lineLimit(1)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PlainwordTheme.textSecondary)
            .help("Close")
            .accessibilityLabel("Close popover")
        }
        .padding(.horizontal, 12)
        .frame(height: 43)
    }

    private func statusContent(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(PlainwordTheme.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(promptCaption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PlainwordTheme.textSecondary)

            TextField(
                model.isComposing
                    ? "A reply saying I am running late…"
                    : "Make it shorter, friendlier, translate it…",
                text: Binding(
                    get: { model.promptText },
                    set: { model.setPromptText($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1)
            .focused($promptFocused)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                PlainwordTheme.raisedSurface,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        promptFocused
                            ? PlainwordTheme.accent.opacity(0.8)
                            : PlainwordTheme.strongSeparator,
                        lineWidth: 1
                    )
            }

            // The shortcuts change text that is already there, so composing has
            // nothing for them to act on.
            if !model.isComposing {
                HStack(spacing: 5) {
                    ForEach(TransformShortcut.allCases) { shortcut in
                        Button(shortcut.title) {
                            onSubmitPrompt(shortcut.instruction)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            hoveredTransformShortcut == shortcut
                                ? PlainwordTheme.hoverSurface
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(PlainwordTheme.strongSeparator, lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .onHover { isHovering in
                            hoveredTransformShortcut = isHovering ? shortcut : nil
                        }
                        .accessibilityHint("Transforms the selected text immediately")
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.async { promptFocused = true }
        }
    }

    private var promptCaption: String {
        if model.isComposing {
            return "What should Plainword write?"
        }
        return model.showsPromptBackButton
            ? "How should this version change?"
            : "How should this text change?"
    }

    private var promptingContent: some View {
        VStack(spacing: 0) {
            promptContent
            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var processingContent: some View {
        VStack(spacing: 0) {
            statusContent("Checking clarity, correctness, and voice…")
            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var suggestionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.contentRequiresScrolling {
                ScrollView(.vertical) {
                    suggestionBody
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                suggestionBody
            }

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)

            if model.showsContextReceipt, model.isContextReceiptExpanded {
                contextReceiptSection
                Rectangle()
                    .fill(PlainwordTheme.separator)
                    .frame(height: 1)
            }

            footer
        }
        .frame(maxHeight: .infinity)
    }

    private var contextReceiptSection: some View {
        VStack(alignment: .leading, spacing: ContextReceiptMetrics.sectionSpacing) {
            // The decision comes first. The list below is what it decides about, which
            // makes it the explanation — so no sentence has to be one.
            contextSendingSwitch

            if !model.contextReceipt.isEmpty {
                Rectangle()
                    .fill(PlainwordTheme.separator)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: ContextReceiptMetrics.rowSpacing) {
                    ForEach(model.contextReceipt) { receiptRow($0) }
                }
                // Dimmed when this suggestion was not given them, so the difference
                // between "available" and "used" is visible rather than explained.
                .opacity(model.contextWasSentWithSuggestion ? 1 : 0.5)
            }

        }
        .padding(.horizontal, 13)
        .padding(.vertical, ContextReceiptMetrics.verticalPadding)
        // Pinned to the height the panel reserved, so the rows never spill out of the
        // frame while it animates open.
        .frame(
            maxWidth: .infinity,
            minHeight: model.contextReceiptHeight,
            maxHeight: model.contextReceiptHeight,
            alignment: .topLeading
        )
        .background(PlainwordTheme.raisedSurface)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    /// Switching this sends nothing and changes nothing about the suggestion on screen.
    /// It decides whether the next one is given what the list above shows.
    private var contextSendingSwitch: some View {
        Toggle(isOn: Binding(
            get: { model.isContextSendingEnabled },
            set: { onSetContextSendingEnabled($0) }
        )) {
            Text("Attach context from \(model.contextApplicationName)")
                .font(.system(size: 11))
                .foregroundStyle(PlainwordTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(PlainwordTheme.accent)
        .frame(height: ContextReceiptMetrics.controlRowHeight)
        .hoverTip("""
        Attach what Plainword found here to your next suggestion.
        Applies to \(model.contextApplicationName) only.
        """)
        .accessibilityHint(
            "Decides whether your next suggestion in this application has the text found around this field attached"
        )
    }

    private func receiptCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(PlainwordTheme.textSecondary)
            .lineLimit(1)
            .frame(height: ContextReceiptMetrics.captionHeight, alignment: .leading)
    }

    private func receiptRow(_ item: ReadOnlyContextReceiptItem) -> some View {
        HStack(spacing: 7) {
            Image(systemName: receiptSymbol(for: item.category))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .frame(width: 13)

            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)

            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(PlainwordTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(height: ContextReceiptMetrics.rowHeight)
        // The whole row answers the hover, not just the glyphs in it.
        .contentShape(Rectangle())
        // A row shows one line; hovering shows the whole value it stands for.
        .hoverTip("\(item.title): \(item.detail)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title): \(item.detail)")
    }

    private func receiptSymbol(
        for category: ReadOnlyContextReceiptItem.Category
    ) -> String {
        switch category {
        case .application: "app.dashed"
        case .field: "character.cursor.ibeam"
        case .document: "doc.text"
        case .nearbyText: "text.alignleft"
        case .surroundingText: "text.insert"
        }
    }

    @ViewBuilder
    private var suggestionBody: some View {
        if let suggestion = model.suggestion {
            suggestionDetails(suggestion)
                .padding(13)
        } else {
            StreamingTextView(
                text: model.correctedText,
                isStreaming: model.phase == .streaming
            )
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func suggestionDetails(_ suggestion: WritingSuggestion) -> some View {
        switch suggestion.kind {
        case .correction where model.presentation == .sourceOverlay:
            replacementPreview(suggestion)
        case .completion:
            labeledText(
                "Finish with",
                text: suggestion.changes.first?.replacement ?? suggestion.replacementText,
                emphasized: true
            )
        case .composition:
            // Nothing was replaced, so there is no diff to offer: the draft is the
            // whole result.
            labeledText("Draft", text: suggestion.replacementText)
        case .correction, .rewrite:
            fallbackPreview(suggestion)
        }
    }

    private func replacementPreview(_ suggestion: WritingSuggestion) -> some View {
        let phrases = replacementPhrases(for: suggestion)
        let usesFullText = phrases.count > CorrectionPresentationMetrics.maximumChipCount
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel(usesFullText ? "Suggested text" : "Use instead")
            if usesFullText {
                Text(suggestion.replacementText)
                    .font(.system(size: 14, weight: .medium))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                WrappingHStackLayout(
                    horizontalSpacing: CorrectionPresentationMetrics.chipSpacing,
                    verticalSpacing: CorrectionPresentationMetrics.chipSpacing
                ) {
                    ForEach(Array(phrases.enumerated()), id: \.offset) {
                        replacementChip($0.element)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func replacementChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PlainwordTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                PlainwordTheme.accentMuted,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labeledText(
        _ label: String,
        text: String,
        emphasized: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(label)
            Text(text)
                .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fallbackPreview(_ suggestion: WritingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("Proposed edit")
                Spacer(minLength: 8)
                previewModePicker
            }
            .frame(height: CorrectionPresentationMetrics.previewHeaderHeight)

            if model.previewMode == .revised {
                Text(suggestion.replacementText)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(attributedDiff(suggestion))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewModePicker: some View {
        Picker(
            "Preview",
            selection: Binding(
                get: { model.previewMode },
                set: { previewMode in
                    onPreviewModeChange(previewMode)
                }
            )
        ) {
            Text("Revised").tag(SuggestionPreviewMode.revised)
            Text("Changes").tag(SuggestionPreviewMode.changes)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Suggestion preview")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.55)
            .textCase(.uppercase)
            .foregroundStyle(PlainwordTheme.textSecondary)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.phase == .prompting {
                Spacer(minLength: 8)
                Button(action: model.showsPromptBackButton ? onBack : onDismiss) {
                    PlainwordShortcutLabel(
                        model.showsPromptBackButton ? "Back" : "Cancel",
                        shortcut: "esc"
                    )
                }
                    .buttonStyle(PlainwordButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    onSubmitPrompt(model.promptText)
                } label: {
                    PlainwordShortcutLabel(
                        model.isComposing ? "Write" : "Transform",
                        shortcut: "↩"
                    )
                }
                .buttonStyle(PlainwordButtonStyle(.primary))
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!model.canSubmitPrompt)
            } else if model.isWorking {
                Text(model.phase == .processing ? "Connecting…" : "Writing…")
                    .font(.system(size: 11))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                Spacer()
                Button("Cancel", action: onDismiss)
                    .buttonStyle(PlainwordButtonStyle())
            } else {
                if model.showsContextReceipt {
                    contextReceiptToggle
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    PlainwordShortcutLabel("Dismiss", shortcut: "esc")
                }
                    .buttonStyle(PlainwordButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if model.phase == .ready, model.showsBackButton {
                    Button("Back", action: onBack)
                        .buttonStyle(PlainwordButtonStyle())
                }
                if model.phase == .ready {
                    Button(action: onAccept) {
                        PlainwordShortcutLabel(acceptTitle, shortcut: "⌘↩")
                    }
                        .buttonStyle(PlainwordButtonStyle(.primary))
                        .keyboardShortcut(.return, modifiers: [.command])
                        .accessibilityHint("Press Command-Return to apply")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private var contextReceiptToggle: some View {
        Button(action: onToggleContextReceipt) {
            Image(systemName: "paperclip")
                .font(.system(size: 11, weight: .medium))
                .rotationEffect(.degrees(model.isContextReceiptExpanded ? -20 : 0))
                .frame(width: 22, height: 22)
                .background(
                    model.isContextSendingEnabled
                        ? PlainwordTheme.accentMuted
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            model.isContextSendingEnabled
                ? PlainwordTheme.accent
                : PlainwordTheme.textSecondary
        )
        .hoverTip("""
        \(ReadOnlyContextReceipt.summary(
                forItemCount: model.contextReceipt.count,
                wasAttached: model.contextWasSentWithSuggestion
            ))
        Only this window. Never password fields.
        """)
        .accessibilityLabel("Attached context")
        .accessibilityValue(
            ReadOnlyContextReceipt.summary(
                forItemCount: model.contextReceipt.count,
                wasAttached: model.contextWasSentWithSuggestion
            )
        )
        .accessibilityHint("Shows what Plainword found around this field")
    }

    private var headerTitle: String {
        switch model.phase {
        case .promptTrigger, .promptTriggerLoading: ""
        case .prompting:
            model.showsPromptBackButton
                ? "Apply another transformation"
                : model.promptTitle
        case .processing, .streaming: "Improving…"
        case .ready:
            switch model.suggestion?.kind {
            case .correction:
                (model.suggestion?.changes.count ?? 1) == 1
                    ? "Small correction"
                    : "Small corrections"
            case .completion: "Finish your thought"
            case .rewrite: "Clarity suggestion"
            case .composition: "Draft"
            case .none: "Suggestion"
            }
        case .unchanged: "Looks good"
        case .failure: "Couldn’t improve text"
        }
    }

    private var headerDetail: String {
        guard model.phase == .ready, let suggestion = model.suggestion else { return "" }
        switch suggestion.kind {
        case .correction:
            return "\(suggestion.changes.count) \(suggestion.changes.count == 1 ? "fix" : "fixes")"
        case .completion:
            return "Completion"
        case .rewrite:
            return "1 rewrite"
        case .composition:
            return "New text"
        }
    }

    private var acceptTitle: String {
        guard let suggestion = model.suggestion else { return "Apply" }
        switch suggestion.kind {
        case .correction:
            return suggestion.changes.count == 1
                ? "Apply fix"
                : "Apply \(suggestion.changes.count) fixes"
        case .completion:
            return "Finish"
        case .rewrite:
            return "Use suggestion"
        case .composition:
            return "Insert"
        }
    }

    private func replacementPhrases(for suggestion: WritingSuggestion) -> [String] {
        let phrases = suggestion.changes.compactMap { change in
            let phrase = change.replacement
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return phrase.isEmpty ? nil : phrase
        }
        return phrases.isEmpty ? ["Delete marked text"] : phrases
    }

    private func attributedDiff(_ suggestion: WritingSuggestion) -> AttributedString {
        var result = AttributedString()
        for segment in WritingDiffPlanner.make(
            original: suggestion.originalText,
            replacement: suggestion.replacementText
        ) {
            var fragment = AttributedString(segment.text)
            switch segment.kind {
            case .unchanged:
                fragment.foregroundColor = PlainwordTheme.textPrimary
            case .removed:
                fragment.foregroundColor = PlainwordTheme.danger
                fragment.backgroundColor = PlainwordTheme.danger.opacity(0.1)
                fragment.strikethroughStyle = Text.LineStyle(
                    pattern: .solid,
                    color: PlainwordTheme.danger
                )
            case .inserted:
                fragment.foregroundColor = PlainwordTheme.accent
                fragment.backgroundColor = PlainwordTheme.accentMuted
            }
            result.append(fragment)
        }
        return result
    }
}

private struct PanelDragArea: NSViewRepresentable {
    let onDrag: (NSPoint) -> Void

    func makeNSView(context: Context) -> PanelDragView {
        let view = PanelDragView()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ nsView: PanelDragView, context: Context) {
        nsView.onDrag = onDrag
    }
}

private final class PanelDragView: NSView {
    var onDrag: ((NSPoint) -> Void)?
    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialMouseLocation, let initialWindowOrigin else { return }
        let mouseLocation = NSEvent.mouseLocation
        onDrag?(NSPoint(
            x: initialWindowOrigin.x + mouseLocation.x - initialMouseLocation.x,
            y: initialWindowOrigin.y + mouseLocation.y - initialMouseLocation.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        initialMouseLocation = nil
        initialWindowOrigin = nil
    }
}

private struct ProposalPointer: Shape {
    let edge: ProposalPointerEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .top:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
