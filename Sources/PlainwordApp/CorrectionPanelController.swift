import AppKit
import PlainwordCore
import SwiftUI

enum SuggestionPresentationMode: Equatable {
    case sourceOverlay
    case fallback
}

private enum CorrectionPresentationMetrics {
    static let maximumChipCount = 6
    static let chipSpacing: CGFloat = 7
    static let previewHeaderHeight: CGFloat = 22
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

    func beginPrompt(
        pointerEdge: ProposalPointerEdge,
        showsBackButton: Bool,
        title: String
    ) {
        state = State(
            pointerEdge: pointerEdge,
            phase: .prompting,
            contentGeneration: state.contentGeneration &+ 1,
            showsPromptBackButton: showsBackButton,
            promptTitle: title
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
        transition(to: .promptTriggerLoading)
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
            promptTitle: state.promptTitle
        )
        let changes = { self.state = nextState }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.smooth(duration: 0.18), changes)
        } else {
            changes()
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
        panel.contentView = hostingView
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
        near anchor: CGRect,
        onAccept: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onBack: (() -> Void)? = nil,
        onRequestPrompt: @escaping () -> Void
    ) {
        let shouldAnimateResize = panel.isVisible
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onBack = onBack
        self.onRequestPrompt = onRequestPrompt
        self.onSubmitPrompt = nil
        cancelScheduledStreamingResize()
        model.begin(
            pointerEdge: verticalPlacement.pointerEdge,
            showsPromptButton: true,
            showsBackButton: onBack != nil
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
            title: title
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

    func restoreVisibility() {
        visibilityGeneration += 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Removes the panel from the global window stack while preserving its state.
    func suspendVisibility() {
        visibilityGeneration += 1
        panel.alphaValue = 1
        panel.orderOut(nil)
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
            panel.setFrame(frame, display: true)
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

    private func constrainedOrigin(_ origin: NSPoint, for size: NSSize) -> NSPoint {
        let proposedFrame = NSRect(origin: origin, size: size)
        let mouseScreen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        }
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
        if reducesMotion {
            panel.alphaValue = 1
        } else if !panel.isVisible {
            panel.alphaValue = 0
        }

        // A global shortcut leaves the source application active. Unlike
        // makeKeyAndOrderFront, this can raise Plainword's panel above another
        // application's key window. Make it key separately so the prompt accepts
        // typing without activating Plainword or changing the window ordering.
        panel.orderFrontRegardless()
        if makeKey {
            panel.makeKey()
        }

        guard !reducesMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }
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
            contentHeight = 108
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
        let naturalHeight = pointerHeight + 43 + 1 + contentHeight + footerHeight
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
        case .correction, .rewrite:
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

private struct PlainwordLoadingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(
                colorScheme == .dark ? Color.white : Color.black.opacity(0.82),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: 0.72).repeatForever(autoreverses: false),
                value: isRotating
            )
            .frame(width: 14, height: 14)
            .onAppear { isRotating = !reduceMotion }
            .onChange(of: reduceMotion) { _, shouldReduceMotion in
                isRotating = !shouldReduceMotion
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
                        PlainwordLoadingSpinner()
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
                    PlainwordLoadingSpinner()
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
            Text(
                model.showsPromptBackButton
                    ? "How should this version change?"
                    : "How should this text change?"
            )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PlainwordTheme.textSecondary)

            TextField(
                "Make it shorter, friendlier, translate it…",
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
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.async { promptFocused = true }
        }
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

            footer
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var suggestionBody: some View {
        if let suggestion = model.suggestion {
            suggestionDetails(suggestion)
                .padding(13)
        } else {
            Text(model.correctedText + (model.phase == .streaming ? " ▍" : ""))
                .font(.system(size: 13))
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
                Text("↩ to transform")
                    .font(.system(size: 10))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                Spacer(minLength: 8)
                Button(
                    model.showsPromptBackButton ? "Back" : "Cancel",
                    action: model.showsPromptBackButton ? onBack : onDismiss
                )
                    .buttonStyle(PlainwordButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Transform") {
                    onSubmitPrompt(model.promptText)
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
                Text("⌘↩ to apply")
                    .font(.system(size: 10))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                Spacer(minLength: 8)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(PlainwordButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if model.phase == .ready, model.showsBackButton {
                    Button("Back", action: onBack)
                        .buttonStyle(PlainwordButtonStyle())
                }
                if model.phase == .ready {
                    Button(acceptTitle, action: onAccept)
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
