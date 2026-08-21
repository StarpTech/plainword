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
    static let headerHeight: CGFloat = 42
    static let footerHeight: CGFloat = 48
    static let triggerSize = CGSize(width: 48, height: 48)
    static let appliedSize = CGSize(width: 104, height: 34)
    /// How long the applied chip stays before the panel gets out of the way.
    static let appliedDuration: Duration = .milliseconds(1900)
    /// Providers send text in uneven bursts, so resizes are held to a fixed cadence
    /// rather than following the bursts. The resize animation is exactly this long,
    /// so one step ends as the next begins.
    static let streamingResizeInterval: Double = 0.06
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
    static let actionRowHeight: CGFloat = 26
    static let sectionSpacing: CGFloat = 7

    /// Depends on how much was found, and on whether the switch now says something the
    /// suggestion on screen was not made under — the row offering to ask again is the
    /// one thing here that appears in answer to the switch.
    static func height(forItemCount count: Int, includesRerunAction: Bool) -> CGFloat {
        var height = verticalPadding * 2 + controlRowHeight
        if count > 0 {
            height += sectionSpacing + 1 + sectionSpacing
                + CGFloat(count) * rowHeight
                + CGFloat(count - 1) * rowSpacing
        }
        if includesRerunAction {
            height += sectionSpacing + actionRowHeight
        }
        return height
    }
}

private enum SuggestionPreviewMode: Hashable {
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
        var promptTitle = "Rewrite selection"
        /// The prompt writes new text rather than changing text that is already there.
        var isComposing = false
        var contextReceipt: [ReadOnlyContextReceiptItem] = []
        var isContextReceiptExpanded = false
        var contextApplicationName = ""
        var isContextSendingEnabled = false
        var contextWasSentWithSuggestion = false
        /// Whether there is a request behind the suggestion on screen that the panel
        /// can run again.
        var canRerunUnderCurrentContext = false
        var canRetry = false
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
        /// The edit landed. Nothing is being proposed any more — this is a receipt.
        case applied
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
    /// Whether what the list shows counts as attached: for a suggestion already made,
    /// whether it went with it; for a request still being written, whether it will.
    var contextIsAttached: Bool {
        state.phase == .prompting
            ? state.isContextSendingEnabled
            : state.contextWasSentWithSuggestion
    }
    /// Whether the switch now says something other than what the suggestion on screen
    /// was made under, with a request behind it that can be asked again.
    ///
    /// Flipping the switch cannot change a suggestion that has already been made. Left
    /// at that, acting on the decision would mean closing the panel and starting over,
    /// so the section offers to ask again under what the switch now says.
    var showsRerunAction: Bool {
        state.canRerunUnderCurrentContext
            && state.phase == .ready
            && state.isContextSendingEnabled != state.contextWasSentWithSuggestion
    }
    var contextReceiptHeight: CGFloat {
        ContextReceiptMetrics.height(
            forItemCount: state.contextReceipt.count,
            includesRerunAction: showsRerunAction
        )
    }
    /// The receipt accounts for what a request carries: what the suggestion on screen
    /// was given, or — at a prompt — what the request about to be sent will be given.
    ///
    /// A prompt is the only place that decision can still be made before the request
    /// goes, which matters most for a draft. An empty field has no earlier suggestion
    /// to have offered the switch, so without it here the first thing Plainword writes
    /// in an application could never be given its surroundings.
    ///
    /// It stays available when nothing was read, because that is the only place the
    /// switch below it lives — hiding it would make turning reading back on impossible
    /// without a trip to Settings.
    var showsContextReceipt: Bool {
        !state.contextApplicationName.isEmpty
            && (state.phase == .ready
                || state.phase == .streaming
                || state.phase == .prompting)
    }
    var showsBackButton: Bool {
        state.showsPromptBackButton || state.showsSuggestionBackButton
    }
    var isWorking: Bool { phase == .processing || phase == .streaming }
    /// Whether the failure on screen is one the panel can offer to run again.
    var canRetry: Bool { state.canRetry }
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
            contextWasSentWithSuggestion: state.contextWasSentWithSuggestion,
            canRerunUnderCurrentContext: state.canRerunUnderCurrentContext,
            canRetry: state.canRetry
        )
        let changes = { self.state = nextState }
        if animated, !PlainwordMotion.reducesMotion {
            withAnimation(PlainwordMotion.content, changes)
        } else {
            changes()
        }
    }

    func setContextReceipt(
        _ contextReceipt: [ReadOnlyContextReceiptItem],
        applicationName: String,
        isSendingEnabled: Bool,
        wasSentWithSuggestion: Bool,
        canRerunUnderCurrentContext: Bool = false
    ) {
        state.contextReceipt = contextReceipt
        state.contextApplicationName = applicationName
        state.isContextSendingEnabled = isSendingEnabled
        state.contextWasSentWithSuggestion = wasSentWithSuggestion
        state.canRerunUnderCurrentContext = canRerunUnderCurrentContext
        state.isContextReceiptExpanded = false
    }

    /// Replaces the list without collapsing the section around it.
    ///
    /// A prompt shows what is there before anything has been asked for, so its list is
    /// still being read from the interface while the author types — and may land under
    /// a receipt they have already opened.
    func updateContextReceipt(_ contextReceipt: [ReadOnlyContextReceiptItem]) {
        guard state.contextReceipt != contextReceipt else { return }
        let changes = { self.state.contextReceipt = contextReceipt }
        if PlainwordMotion.reducesMotion {
            changes()
        } else {
            withAnimation(PlainwordMotion.content, changes)
        }
    }

    func setContextSendingEnabled(_ isEnabled: Bool) {
        guard state.isContextSendingEnabled != isEnabled else { return }
        let changes = { self.state.isContextSendingEnabled = isEnabled }
        if PlainwordMotion.reducesMotion {
            changes()
        } else {
            withAnimation(PlainwordMotion.content, changes)
        }
    }

    func setContextReceiptExpanded(_ isExpanded: Bool) {
        guard state.isContextReceiptExpanded != isExpanded else { return }
        let changes = { self.state.isContextReceiptExpanded = isExpanded }
        if PlainwordMotion.reducesMotion {
            changes()
        } else {
            withAnimation(PlainwordMotion.content, changes)
        }
    }

    func setCanRetry(_ canRetry: Bool) {
        state.canRetry = canRetry
    }

    func setPresentation(_ presentation: SuggestionPresentationMode) {
        guard state.presentation != presentation else { return }
        state.presentation = presentation
    }

    func setPreviewMode(_ previewMode: SuggestionPreviewMode) {
        guard state.previewMode != previewMode else { return }
        let changes = { self.state.previewMode = previewMode }
        if PlainwordMotion.reducesMotion {
            changes()
        } else {
            withAnimation(PlainwordMotion.content, changes)
        }
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
        case .applied: 6
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
    private let compactPanelWidth: CGFloat = 300
    private let regularPanelWidth: CGFloat = 352
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
    private var onRetry: (() -> Void)?
    private var onSetContextSendingEnabled: ((Bool) -> Void)?
    private var onRerunUnderCurrentContext: (() -> Void)?
    private var targetFrame: NSRect?
    private var userPositionedOrigin: NSPoint?
    private var streamingResizeTask: Task<Void, Never>?
    /// The size the panel has already grown to for the stream in progress.
    private var streamingSizeFloor: NSSize?
    private var appliedDismissTask: Task<Void, Never>?
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
                    onRetry: { [weak self] in self?.onRetry?() },
                    onPreviewModeChange: { [weak self] previewMode in
                        self?.updatePreviewMode(previewMode)
                    },
                    onToggleContextReceipt: { [weak self] in
                        self?.toggleContextReceipt()
                    },
                    onSetContextSendingEnabled: { [weak self] isEnabled in
                        self?.setContextSendingEnabled(isEnabled)
                    },
                    onRerunUnderCurrentContext: { [weak self] in
                        self?.onRerunUnderCurrentContext?()
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
        self.onRerunUnderCurrentContext = nil
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
        onSetContextSendingEnabled: ((Bool) -> Void)? = nil,
        onRerunUnderCurrentContext: (() -> Void)? = nil
    ) {
        let shouldAnimateResize = panel.isVisible
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onBack = onBack
        self.onRequestPrompt = onRequestPrompt
        self.onSubmitPrompt = nil
        self.onSetContextSendingEnabled = onSetContextSendingEnabled
        self.onRerunUnderCurrentContext = onRerunUnderCurrentContext
        cancelScheduledStreamingResize()
        // Text that streamed in is already the answer. Settling it in place reads as the
        // same result gaining its controls, so it is adopted rather than replaced.
        if model.phase == .streaming {
            model.adopt(
                showsPromptButton: true,
                showsBackButton: onBack != nil
            )
        } else {
            model.begin(
                pointerEdge: verticalPlacement.pointerEdge,
                // Every result can be sent back for another pass, a draft included:
                // the prompt works on the text being proposed, not on the field.
                showsPromptButton: true,
                showsBackButton: onBack != nil
            )
        }
        model.setContextReceipt(
            contextReceipt,
            applicationName: contextApplicationName,
            isSendingEnabled: isContextSendingEnabled,
            wasSentWithSuggestion: contextWasSentWithSuggestion,
            canRerunUnderCurrentContext: onRerunUnderCurrentContext != nil
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

    /// Presents the prompt.
    ///
    /// A context receipt is offered here whenever the caller names an application for
    /// it. Nothing has been sent yet at a prompt, so the switch decides what this
    /// request will carry rather than what the last one did.
    func showPrompt(
        near anchor: CGRect,
        title: String,
        isComposing: Bool = false,
        contextReceipt: [ReadOnlyContextReceiptItem] = [],
        contextApplicationName: String = "",
        isContextSendingEnabled: Bool = false,
        onSubmit: @escaping (String) -> Void,
        onBack: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        onSetContextSendingEnabled: ((Bool) -> Void)? = nil
    ) {
        self.onAccept = nil
        self.onDismiss = onDismiss
        self.onBack = onBack
        self.onRequestPrompt = nil
        self.onSubmitPrompt = onSubmit
        self.onSetContextSendingEnabled = onSetContextSendingEnabled
        self.onRerunUnderCurrentContext = nil
        cancelScheduledStreamingResize()
        model.beginPrompt(
            pointerEdge: verticalPlacement.pointerEdge,
            showsBackButton: onBack != nil,
            title: title,
            isComposing: isComposing
        )
        model.setContextReceipt(
            contextReceipt,
            applicationName: contextApplicationName,
            isSendingEnabled: isContextSendingEnabled,
            wasSentWithSuggestion: false
        )
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: panel.isVisible)
        presentPanel(makeKey: true)
    }

    /// Reflects a decision made outside the panel — the setting behind the switch
    /// changing while the panel is open.
    ///
    /// The callback runs the other way, carrying what the author chose here back to
    /// the app, so it is deliberately not fired: this is the same news arriving.
    func updateContextSendingEnabled(_ isEnabled: Bool) {
        guard model.isContextSendingEnabled != isEnabled else { return }
        model.setContextSendingEnabled(isEnabled)
        targetFrame = nil
        resizeForContent(animated: true)
    }

    /// Hands the open prompt the context that was read while it was being typed into.
    func updateContextReceipt(_ contextReceipt: [ReadOnlyContextReceiptItem]) {
        model.updateContextReceipt(contextReceipt)
        targetFrame = nil
        resizeForContent(animated: true)
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
        self.onRerunUnderCurrentContext = nil
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

    /// The switch records a preference. It issues no request and leaves the suggestion
    /// on screen exactly as it was made; what it can change is the row underneath it,
    /// which offers to ask again under the setting it now holds.
    private func setContextSendingEnabled(_ isEnabled: Bool) {
        model.setContextSendingEnabled(isEnabled)
        onSetContextSendingEnabled?(isEnabled)
        targetFrame = nil
        // Matches the content animation in the model, so the section and the panel
        // around it take on the offered row together.
        resizeForContent(animated: true)
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
            // A review starts as a small marker, and a rewrite as a single line. The
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
        // the result's actual size, matching the rewrite prompt's behavior.
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: true)
    }

    func showFailure(_ message: String, onRetry: (() -> Void)? = nil) {
        cancelScheduledStreamingResize()
        self.onRetry = onRetry
        self.onRerunUnderCurrentContext = nil
        model.setCanRetry(onRetry != nil)
        model.transition(to: .failure(message))
        configurePlacement(near: anchor)
        model.setPointerEdge(verticalPlacement.pointerEdge)
        targetFrame = nil
        resizeForContent(animated: true)
    }

    /// Replaces the panel with a receipt, then gets out of the way.
    ///
    /// The edit is already in the field; leaving the proposal up long enough to read
    /// "Applied" is the whole point, and leaving it up any longer is in the way.
    func showApplied() {
        cancelScheduledStreamingResize()
        appliedDismissTask?.cancel()
        onAccept = nil
        onBack = nil
        onRequestPrompt = nil
        onSubmitPrompt = nil
        onRetry = nil
        onRerunUnderCurrentContext = nil
        userPositionedOrigin = nil
        guard panel.isVisible else {
            dismiss()
            return
        }

        model.transition(to: .applied, correctedText: "")
        targetFrame = nil
        resizeForContent(animated: true)
        appliedDismissTask = Task { [weak self] in
            try? await Task.sleep(for: CorrectionPresentationMetrics.appliedDuration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        cancelScheduledStreamingResize()
        appliedDismissTask?.cancel()
        appliedDismissTask = nil
        onRetry = nil
        onRerunUnderCurrentContext = nil
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

    /// How a resize is played out.
    private enum ResizeMotion {
        /// The app's one duration, eased out: a panel settling into a new shape.
        case settled
        /// Paced to the cadence of the arriving text, and even the whole way through.
        ///
        /// An eased 180 ms curve restarted every 60 ms never finishes: each arrival
        /// re-aims the frame from wherever the last curve had reached, so the panel
        /// accelerates and stalls by turns. A linear step the length of one arrival
        /// lands exactly as the next one begins, and consecutive steps read as one
        /// continuous movement.
        case streaming

        var duration: Double {
            switch self {
            case .settled: PlainwordMotion.duration
            case .streaming: CorrectionPresentationMetrics.streamingResizeInterval
            }
        }

        var timingFunction: CAMediaTimingFunction {
            switch self {
            // AppKit eases in and out by default. The content inside eases out, and
            // two curves over the same 180 ms read as the panel and its contents
            // coming apart.
            case .settled: CAMediaTimingFunction(name: .easeOut)
            case .streaming: CAMediaTimingFunction(name: .linear)
            }
        }

        /// Streamed text draws itself in at its own pace. Letting the frame animation
        /// catch the content as well cross-fades the text on every arrival, on top of
        /// the reveal already running through it.
        var animatesContent: Bool {
            switch self {
            case .settled: true
            case .streaming: false
            }
        }
    }

    private func resizeForContent(
        animated: Bool,
        motion: ResizeMotion = .settled
    ) {
        let layout = targetLayout
        var size = layout.size
        var contentRequiresScrolling = layout.contentRequiresScrolling
        if model.phase == .streaming {
            // Text that arrives mid-word rewraps, so a panel that answered every
            // measurement would shrink and grow again within a frame or two. A stream
            // only ever gains text, so the panel only ever grows with it.
            if let floor = streamingSizeFloor {
                size.width = max(size.width, floor.width)
                size.height = max(size.height, floor.height)
            }
            streamingSizeFloor = size
            contentRequiresScrolling = layout.naturalHeight > size.height + 0.5
        } else {
            streamingSizeFloor = nil
        }
        model.setContentRequiresScrolling(contentRequiresScrolling)
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
                context.duration = motion.duration
                context.timingFunction = motion.timingFunction
                context.allowsImplicitAnimation = motion.animatesContent
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
            try? await Task.sleep(
                for: .seconds(CorrectionPresentationMetrics.streamingResizeInterval)
            )
            guard !Task.isCancelled, let self else { return }
            self.streamingResizeTask = nil
            self.resizeForContent(animated: true, motion: .streaming)
        }
    }

    private func cancelScheduledStreamingResize() {
        streamingResizeTask?.cancel()
        streamingResizeTask = nil
        // A restarted request streams from nothing again, and must not be held to the
        // height its predecessor had reached.
        streamingSizeFloor = nil
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
        /// What the content asked for, before the screen and the maximum clamped it.
        /// Kept so a size raised by the streaming floor can re-decide whether the
        /// content still has to scroll.
        let naturalHeight: CGFloat
        let contentRequiresScrolling: Bool
    }

    private var targetLayout: PanelLayout {
        if model.phase == .promptTrigger || model.phase == .promptTriggerLoading {
            return PanelLayout(
                size: CorrectionPresentationMetrics.triggerSize,
                naturalHeight: CorrectionPresentationMetrics.triggerSize.height,
                contentRequiresScrolling: false
            )
        }
        if model.phase == .applied {
            return PanelLayout(
                size: CorrectionPresentationMetrics.appliedSize,
                naturalHeight: CorrectionPresentationMetrics.appliedSize.height,
                contentRequiresScrolling: false
            )
        }

        let contentHeight: CGFloat
        var showsFooter = true
        switch model.phase {
        case .promptTrigger, .promptTriggerLoading, .applied:
            contentHeight = 0
            showsFooter = false
        case .prompting:
            // Composing drops the rewrite shortcuts, and with them their row.
            contentHeight = model.isComposing ? 82 : 114
        case .processing:
            // The italic aside plus the ink line drawing itself under it.
            contentHeight = 52
        case .unchanged:
            contentHeight = 46
            showsFooter = false
        case .streaming:
            // The caret is drawn after the text and can carry the last word onto a
            // line of its own, so it is measured with it. Sizing without it leaves the
            // panel a line short exactly when the text is about to wrap, which turns
            // the scroll view on and off again with every few characters.
            contentHeight = Self.labelledContentInset
                + measuredTextHeight(
                    model.correctedText + Self.streamingCaret,
                    font: Self.suggestionFont,
                    lineSpacing: Self.suggestionLineSpacing
                )
        case .failure(let message):
            contentHeight = 26 + measuredTextHeight(
                message,
                maximum: 76,
                font: .systemFont(ofSize: 12.5),
                lineSpacing: 2
            )
        case .ready:
            contentHeight = readyContentHeight
        }

        let footerHeight = showsFooter ? CorrectionPresentationMetrics.footerHeight : 0
        let naturalHeight = pointerHeight + CorrectionPresentationMetrics.headerHeight + 1
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
            naturalHeight: canScroll ? ceil(naturalHeight) : height,
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

    /// The writing voice, which every measured suggestion is set in.
    private static let suggestionFont = PlainwordFont.serifNSFont(15)
    private static let suggestionLineSpacing: CGFloat = 4
    /// Padding, the mono section label, and the gap under it.
    ///
    /// Every labelled section — the streaming text, a draft, a proposed edit — uses the
    /// same header row, so text measured under one heading lands where it will sit
    /// under the next one. Streaming into a result changes the heading, not the layout.
    private static let labelledContentInset: CGFloat = 26
        + CorrectionPresentationMetrics.previewHeaderHeight
        + 7
    /// Drawn after streamed text, and measured with it.
    fileprivate static let streamingCaret = " \u{258D}"

    private var readyContentHeight: CGFloat {
        guard let suggestion = model.suggestion else { return 70 }
        switch suggestion.kind {
        case .correction:
            if model.presentation == .sourceOverlay {
                return inlineCorrectionContentHeight(for: suggestion)
            }
            return fallbackPreviewContentHeight(for: suggestion)
        case .completion:
            return Self.labelledContentInset + measuredTextHeight(
                suggestion.changes.first?.replacement ?? suggestion.replacementText,
                font: Self.suggestionFont,
                lineSpacing: Self.suggestionLineSpacing
            )
        case .rewrite:
            return fallbackPreviewContentHeight(for: suggestion)
        case .composition:
            return Self.labelledContentInset + measuredTextHeight(
                suggestion.replacementText,
                font: Self.suggestionFont,
                lineSpacing: Self.suggestionLineSpacing
            )
        }
    }

    private func fallbackPreviewContentHeight(
        for suggestion: WritingSuggestion
    ) -> CGFloat {
        let textHeight: CGFloat
        switch model.previewMode {
        case .revised:
            textHeight = measuredTextHeight(
                suggestion.replacementText,
                font: Self.suggestionFont,
                lineSpacing: Self.suggestionLineSpacing
            )
        case .changes:
            textHeight = measuredDiffHeight(for: suggestion)
        }
        return Self.labelledContentInset + textHeight
    }

    /// Measured with the weights the diff is actually drawn in.
    ///
    /// Insertions are set a step heavier, so measuring the whole diff as one regular
    /// run can lose a line at a wrap boundary — and a panel one line short both clips
    /// the suggestion and flips the scroll view on as the mode is toggled.
    private func measuredDiffHeight(for suggestion: WritingSuggestion) -> CGFloat {
        let insertedFont = PlainwordFont.serifNSFont(15, weight: .medium)
        let attributed = NSMutableAttributedString()
        for segment in WritingDiffPlanner.make(
            original: suggestion.originalText,
            replacement: suggestion.replacementText
        ) {
            let font: NSFont
            switch segment.kind {
            case .inserted: font = insertedFont
            case .unchanged, .removed: font = Self.suggestionFont
            }
            attributed.append(
                NSAttributedString(string: segment.text, attributes: [.font: font])
            )
        }
        guard attributed.length > 0 else { return 20 }

        let bounds = attributed.boundingRect(
            with: NSSize(width: max(panelWidth - 28, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = max(ceil(Self.suggestionFont.boundingRectForFont.height), 1)
        let lineCount = max(ceil(bounds.height / lineHeight), 1)
        return max(
            ceil(bounds.height) + CGFloat(lineCount - 1) * Self.suggestionLineSpacing,
            20
        )
    }

    private func inlineCorrectionContentHeight(
        for suggestion: WritingSuggestion
    ) -> CGFloat {
        let phrases = replacementPhrases(for: suggestion)
        if phrases.count > CorrectionPresentationMetrics.maximumChipCount {
            return Self.labelledContentInset + measuredTextHeight(
                suggestion.replacementText,
                font: Self.suggestionFont,
                lineSpacing: Self.suggestionLineSpacing
            )
        }

        let font = PlainwordFont.serifNSFont(15, weight: .medium)
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

        // Outer padding, the mono label, and the gap under it.
        return Self.labelledContentInset + chipsHeight
    }

    private var panelWidth: CGFloat {
        let availableWidth = max(
            compactPanelWidth,
            (targetScreen?.visibleFrame.width ?? maximumPanelWidth) - 20
        )
        guard let suggestion = model.suggestion else {
            // Streamed text is measured by the same rule the result will be measured
            // by, so the panel reaches its final width while the text is still
            // arriving instead of stepping out to it once the answer lands.
            guard model.phase == .streaming, !model.correctedText.isEmpty else {
                return min(regularPanelWidth, availableWidth)
            }
            return preferredWidth(
                for: model.correctedText,
                minimum: regularPanelWidth,
                available: availableWidth
            )
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

        return preferredWidth(
            for: text,
            minimum: minimumWidth,
            available: availableWidth
        )
    }

    /// The width a run of text asks for: what it needs unwrapped, within the panel's
    /// own bounds. Shared so streamed text and the result it becomes agree.
    private func preferredWidth(
        for text: String,
        minimum: CGFloat,
        available: CGFloat
    ) -> CGFloat {
        let measuredWidth = NSString(string: text).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 24),
            options: [.usesFontLeading],
            attributes: [.font: Self.suggestionFont]
        ).width
        let preferred = min(
            maximumPanelWidth,
            max(minimum, ceil(measuredWidth) + 28)
        )
        return min(preferred, available)
    }

    private func measuredTextHeight(
        _ text: String,
        maximum: CGFloat = .greatestFiniteMagnitude,
        font: NSFont = PlainwordFont.serifNSFont(15),
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
    @State private var revealAccumulator: Double = 0
    @State private var pacing = Pacing()

    /// How many characters at the end are still fading up.
    private static let fadeLength = 5
    /// The reveal keeps its own 55 ms cadence, a ninth of what is left each time.
    /// The ticker runs faster than that because the caret has to pulse smoothly.
    private static let revealInterval: Double = 0.055
    private static let revealDivisor: Double = 9
    private static let frameInterval: Double = 1.0 / 30
    private static let caretPeriod: Double = 1.1
    /// The caret breathes between these, never all the way out.
    private static let caretMinimumOpacity: Double = 0.25

    var body: some View {
        rendered
            .font(PlainwordFont.serif(15))
            .lineSpacing(4)
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
        // Dimmest as the cycle turns over and brightest halfway through it, easing
        // between the two — a raised cosine, which is what the cadence asks for.
        let pulse = reduceMotion
            ? 1
            : Self.caretMinimumOpacity
                + (1 - Self.caretMinimumOpacity)
                * (0.5 - 0.5 * cos(caretPhase * 2 * .pi / Self.caretPeriod))
        return Text(CorrectionPanelController.streamingCaret)
            .foregroundStyle(PlainwordTheme.accent.opacity(pulse))
    }

    private func advance() {
        let pacing = self.pacing
        // Nothing is drawing itself in, so nothing needs redrawing.
        guard pacing.isRevealing else { return }

        caretPhase = (caretPhase + Self.frameInterval)
            .truncatingRemainder(dividingBy: Self.caretPeriod)

        revealAccumulator += Self.frameInterval
        guard revealAccumulator >= Self.revealInterval else { return }
        revealAccumulator -= Self.revealInterval
        guard revealedCount < pacing.targetCount else { return }

        // A ninth of what is left, rounded up: quick when a large burst lands, and
        // one character at a time over the last few.
        let remaining = Double(pacing.targetCount - revealedCount)
        revealedCount += max(1, Int((remaining / Self.revealDivisor).rounded(.up)))
    }
}

/// An ink line drawing itself under an aside.
///
/// Thinking is not a spinner here. The line sweeps in from the left, then leaves the
/// same way, which reads as a hand working rather than as a machine waiting.
private struct DrawingUnderline: View {
    var thickness: CGFloat = 2
    /// Draws once and stays, rather than looping — for marks that announce rather
    /// than persist.
    var drawsOnce = false
    var period: Double = 1.3
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            if reduceMotion {
                line.frame(width: total)
            } else {
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    let segment = segment(at: elapsed)
                    line
                        .frame(width: max(segment.width * total, 0))
                        .offset(x: segment.leading * total)
                }
            }
        }
        .frame(height: thickness)
        .accessibilityHidden(true)
    }

    private var line: some View {
        Capsule()
            .fill(PlainwordTheme.accent)
            .frame(height: thickness)
    }

    private func segment(at elapsed: Double) -> (leading: CGFloat, width: CGFloat) {
        if drawsOnce {
            // Anchored to the view's own arrival, so the mark is drawn for the reader
            // rather than caught halfway through a loop that started without them.
            let progress = min(max((elapsed - start - delay) / period, 0), 1)
            return (0, CGFloat(eased(progress)))
        }

        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        if phase <= 0.45 {
            return (0, CGFloat(eased(phase / 0.45)))
        }
        let leading = eased((phase - 0.45) / 0.55)
        return (CGFloat(leading), CGFloat(1 - leading))
    }

    private func eased(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    @State private var start = Date.timeIntervalSinceReferenceDate
}

/// The trigger: a serif "p" whose full stop is drawn in green ink.
private struct PlainwordTriggerChip: View {
    let isWorking: Bool

    var body: some View {
        VStack(spacing: 3) {
            (
                Text(verbatim: "p").foregroundStyle(PlainwordTheme.textPrimary)
                    + Text(verbatim: ".").foregroundStyle(PlainwordTheme.accent)
            )
            .font(PlainwordFont.serif(16, weight: .medium))

            DrawingUnderline(
                thickness: 1.5,
                drawsOnce: !isWorking,
                period: isWorking ? 1.3 : 0.5,
                delay: isWorking ? 0 : 0.25
            )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }
}

private struct CrossAppProposalView: View {
    @ObservedObject var model: CorrectionPanelModel
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onBack: () -> Void
    let onRequestPrompt: () -> Void
    let onSubmitPrompt: (String) -> Void
    let onRetry: () -> Void
    let onPreviewModeChange: (SuggestionPreviewMode) -> Void
    let onToggleContextReceipt: () -> Void
    let onSetContextSendingEnabled: (Bool) -> Void
    let onRerunUnderCurrentContext: () -> Void
    let onDrag: (NSPoint) -> Void
    @FocusState private var promptFocused: Bool
    @State private var hoveredTransformShortcut: TransformShortcut?
    @State private var isHoveringRerunAction = false

    @ViewBuilder
    var body: some View {
        switch model.phase {
        case .promptTrigger, .promptTriggerLoading:
            promptTrigger
        case .applied:
            appliedChip
        default:
            ZStack(alignment: model.pointerEdge == .top ? .topLeading : .bottomLeading) {
                proposalSurface
                    .padding(model.pointerEdge == .top ? .top : .bottom, 7)

                pointer()
                    .offset(x: 34)
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

    /// The tab that ties the panel to the field it is talking about. It carries the
    /// panel's own border so the two read as one shape rather than two.
    ///
    /// A point taller than it looks, so its fill covers the panel's own border where
    /// the two meet and the tab grows out of the edge rather than sitting on it.
    private func pointer(width: CGFloat = 14) -> some View {
        ZStack {
            ProposalPointer(edge: model.pointerEdge)
                .fill(PlainwordTheme.surface)

            // Only the two slanted sides are drawn. Stroking the closed triangle
            // would also draw its base — the very edge the tab is meant to merge
            // into — and that line is what reads as a border around the tab.
            ProposalPointerOutline(edge: model.pointerEdge)
                .stroke(
                    PlainwordTheme.strongSeparator,
                    style: StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .miter)
                )
        }
        .frame(width: width, height: 8)
    }

    private var promptTrigger: some View {
        ZStack(alignment: model.pointerEdge == .top ? .top : .bottom) {
            Button {
                guard model.phase != .promptTriggerLoading else { return }
                onRequestPrompt()
            } label: {
                // No shadow drawn here: the panel is sized to the chip, so a soft
                // shadow has nowhere to fall and is cut off square at the window's
                // edge — which is seen as a hard line boxing the chip in. The panel
                // window casts its own shadow, outside its frame, as the proposal
                // panel does.
                PlainwordTriggerChip(isWorking: model.phase == .promptTriggerLoading)
                    .background(PlainwordTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(PlainwordTheme.strongSeparator, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(model.phase != .promptTriggerLoading)
            .help(model.phase == .promptTriggerLoading ? "Reviewing text" : "Review text")
            .accessibilityLabel(
                model.phase == .promptTriggerLoading ? "Reviewing text" : "Review text"
            )
            .padding(model.pointerEdge == .top ? .top : .bottom, 7)

            pointer(width: 12)
        }
        .frame(width: CorrectionPresentationMetrics.triggerSize.width,
               height: CorrectionPresentationMetrics.triggerSize.height)
        .background(.clear)
    }

    /// What replaces the panel once an edit lands: the smallest possible receipt,
    /// stated in the accent that did the work.
    private var appliedChip: some View {
        HStack(spacing: 7) {
            Text(verbatim: "\u{2713}")
                .font(PlainwordFont.ui(13, weight: .bold))
            Text("Applied")
                .font(PlainwordFont.ui(12, weight: .bold))
        }
        .foregroundStyle(PlainwordTheme.accentText)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            PlainwordTheme.accent,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .frame(
            width: CorrectionPresentationMetrics.appliedSize.width,
            height: CorrectionPresentationMetrics.appliedSize.height,
            alignment: model.pointerEdge == .top ? .topLeading : .bottomLeading
        )
        .accessibilityLabel("Applied")
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
                    .transition(PlainwordMotion.rise)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .background(PlainwordTheme.surface)
        .clipShape(
            RoundedRectangle(cornerRadius: PlainwordTheme.panelCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PlainwordTheme.panelCornerRadius, style: .continuous)
                .strokeBorder(PlainwordTheme.strongSeparator, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .promptTrigger, .promptTriggerLoading, .applied:
            EmptyView()
        case .prompting:
            promptingContent
        case .processing:
            processingContent
        case .unchanged:
            // An aside rather than a status line: nothing happened, and the panel
            // says so in the same voice it would have used to suggest something.
            Text("Looks good — nothing to change.")
                .font(PlainwordFont.serif(14, italic: true))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failure(let message):
            failureContent(message)
        case .streaming, .ready:
            suggestionContent
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.showsBackButton {
                PanelGlyphButton(
                    systemImage: "chevron.left",
                    help: "Back to previous suggestion",
                    action: onBack
                )
            }

            HStack(spacing: 8) {
                PlainwordBrandMark(size: 20)

                Text(headerTitle)
                    .font(PlainwordFont.serif(14.5, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .overlay {
                PanelDragArea(onDrag: onDrag)
            }

            if model.showsPromptButton {
                PanelGlyphButton(
                    systemImage: "wand.and.stars",
                    help: "Tell Plainword how to change this text",
                    accessibilityLabel: "Custom edit",
                    action: onRequestPrompt
                )
            }

            Text(headerDetail)
                .font(PlainwordFont.mono(10))
                .foregroundStyle(PlainwordTheme.textTertiary)
                .lineLimit(1)

            PanelGlyphButton(
                systemImage: "xmark",
                help: "Close",
                accessibilityLabel: "Close popover",
                action: onDismiss
            )
        }
        .padding(.horizontal, 12)
        .frame(height: CorrectionPresentationMetrics.headerHeight)
    }

    /// A label that names the section rather than saying something: machinery voice.
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(PlainwordFont.mono(9.5))
            .tracking(0.76)
            .foregroundStyle(PlainwordTheme.textTertiary)
    }

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel(promptCaption)

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
            .font(PlainwordFont.ui(13))
            .lineLimit(1)
            .focused($promptFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                PlainwordTheme.fieldSurface,
                in: RoundedRectangle(
                    cornerRadius: PlainwordTheme.controlCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PlainwordTheme.controlCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    promptFocused ? PlainwordTheme.accent : PlainwordTheme.strongSeparator,
                    lineWidth: 1
                )
            }
            .background {
                if promptFocused {
                    RoundedRectangle(
                        cornerRadius: PlainwordTheme.controlCornerRadius + 3,
                        style: .continuous
                    )
                    .fill(PlainwordTheme.accentMuted)
                    .padding(-3)
                }
            }
            .animation(PlainwordMotion.content, value: promptFocused)

            // The shortcuts change text that is already there, so composing has
            // nothing for them to act on.
            if !model.isComposing {
                HStack(spacing: 6) {
                    ForEach(TransformShortcut.allCases) { shortcut in
                        transformShortcutChip(shortcut)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            DispatchQueue.main.async { promptFocused = true }
        }
    }

    private func transformShortcutChip(_ shortcut: TransformShortcut) -> some View {
        let isHovering = hoveredTransformShortcut == shortcut
        return Button(shortcut.title) {
            onSubmitPrompt(shortcut.instruction)
        }
        .buttonStyle(.plain)
        .font(PlainwordFont.ui(11, weight: .bold))
        .foregroundStyle(
            isHovering ? PlainwordTheme.textPrimary : PlainwordTheme.textSecondary
        )
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            isHovering ? PlainwordTheme.raisedSurface : Color.clear,
            in: RoundedRectangle(
                cornerRadius: PlainwordTheme.smallCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: PlainwordTheme.smallCornerRadius, style: .continuous)
                .strokeBorder(PlainwordTheme.strongSeparator, lineWidth: 1)
        }
        .contentShape(
            RoundedRectangle(cornerRadius: PlainwordTheme.smallCornerRadius, style: .continuous)
        )
        .onHover { hoveredTransformShortcut = $0 ? shortcut : nil }
        .animation(PlainwordMotion.content, value: isHovering)
        .accessibilityHint("Rewrites the selected text immediately")
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

            if model.showsContextReceipt, model.isContextReceiptExpanded {
                Rectangle()
                    .fill(PlainwordTheme.separator)
                    .frame(height: 1)
                contextReceiptSection
            }

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var processingContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reading it over…")
                        .font(PlainwordFont.serif(14, italic: true))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                    DrawingUnderline()
                }
                .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.top, 14)
            .padding(.bottom, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Reading it over")

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func failureContent(_ message: String) -> some View {
        VStack(spacing: 0) {
            Text(message)
                .font(PlainwordFont.ui(12.5))
                .lineSpacing(2)
                .foregroundStyle(PlainwordTheme.danger)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var suggestionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One scroll view either way. Swapping it in and out when the content
            // crosses the panel's height rebuilds the body in the middle of the
            // resize, which is seen as the suggestion flickering.
            ScrollView(.vertical) {
                suggestionBody
            }
            .scrollIndicators(model.contentRequiresScrolling ? .automatic : .never)
            .scrollDisabled(!model.contentRequiresScrolling)
            .scrollBounceBehavior(.basedOnSize)

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
                // Dimmed when the request they belong to was not given them, so the
                // difference between "available" and "used" is visible rather than
                // explained.
                .opacity(model.contextIsAttached ? 1 : 0.45)
            }

            if model.showsRerunAction {
                rerunActionRow
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
        .transition(PlainwordMotion.rise)
    }

    /// At a prompt the switch decides what the request being written will carry. Under
    /// a suggestion it is too late for that one, so it decides for the next — and the
    /// row below it offers to make this one over again as one of those.
    private var contextSwitchTip: String {
        model.phase == .prompting
            ? "Attach what Plainword found here to this request."
            : "Attach what Plainword found here to your next suggestion, or ask again below to remake this one."
    }

    /// Turning the switch changes nothing about a suggestion that has already been
    /// made. This is how the author acts on the decision they just made without
    /// closing the panel and starting the request over from the field.
    private var rerunActionRow: some View {
        Button(action: onRerunUnderCurrentContext) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(PlainwordFont.ui(10, weight: .bold))
                Text(rerunActionTitle)
                    .font(PlainwordFont.ui(11.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(ContextActionButtonStyle(isHovering: isHoveringRerunAction))
        // The panel is never the key window, so the pointer has to be tracked the way
        // the hints are — see `onPointerHover`.
        .onPointerHover { isHoveringRerunAction = $0 }
        .transition(PlainwordMotion.rise)
        .hoverTip(
            model.isContextSendingEnabled
                ? """
                Ask again, this time sending what is listed above.
                The suggestion on screen was made without it.
                """
                : """
                Ask again without sending what is listed above.
                The suggestion on screen was made with it.
                """
        )
        .accessibilityLabel(rerunActionTitle)
        .accessibilityHint(
            model.isContextSendingEnabled
                ? "Runs the same request again with the text found around this field attached"
                : "Runs the same request again without the text found around this field attached"
        )
    }

    private var rerunActionTitle: String {
        model.isContextSendingEnabled
            ? "Try again with context"
            : "Try again without context"
    }

    /// Switching this sends nothing. Under a finished suggestion it changes nothing
    /// about it either; at a prompt it decides what that request is given.
    private var contextSendingSwitch: some View {
        Toggle(isOn: Binding(
            get: { model.isContextSendingEnabled },
            set: { onSetContextSendingEnabled($0) }
        )) {
            Text("Attach context from \(model.contextApplicationName)")
                .font(PlainwordFont.ui(11.5))
                .foregroundStyle(PlainwordTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(PlainwordTheme.accent)
        .frame(height: ContextReceiptMetrics.controlRowHeight)
        .hoverTip("""
        \(contextSwitchTip)
        Applies to \(model.contextApplicationName) only.
        """)
        .accessibilityHint(
            model.phase == .prompting
                ? "Decides whether this request has the text found around this field attached"
                : "Decides whether your next suggestion in this application has the text found around this field attached"
        )
    }

    private func receiptRow(_ item: ReadOnlyContextReceiptItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.title.uppercased())
                .font(PlainwordFont.mono(9.5))
                .foregroundStyle(PlainwordTheme.textTertiary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)

            Text(item.detail)
                .font(PlainwordFont.ui(11))
                .foregroundStyle(PlainwordTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(height: ContextReceiptMetrics.rowHeight)
        // The whole row answers the hover, not just the label in it.
        .contentShape(Rectangle())
        // A row shows one line; hovering shows the whole value it stands for.
        .hoverTip("\(item.title): \(item.detail)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title): \(item.detail)")
    }

    @ViewBuilder
    private var suggestionBody: some View {
        if let suggestion = model.suggestion {
            suggestionDetails(suggestion)
                .padding(.horizontal, 13)
                .padding(.top, 12)
                .padding(.bottom, 14)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("Suggested revision")
                    .frame(
                        height: CorrectionPresentationMetrics.previewHeaderHeight,
                        alignment: .leading
                    )
                StreamingTextView(
                    text: model.correctedText,
                    isStreaming: model.phase == .streaming
                )
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 14)
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
                text: suggestion.changes.first?.replacement ?? suggestion.replacementText
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
        return VStack(alignment: .leading, spacing: 7) {
            sectionLabel(usesFullText ? "Suggested text" : "Use instead")
                .frame(
                    height: CorrectionPresentationMetrics.previewHeaderHeight,
                    alignment: .leading
                )
            if usesFullText {
                Text(suggestion.replacementText)
                    .font(PlainwordFont.serif(15))
                    .lineSpacing(4)
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

    /// A word that goes in, drawn the way an insertion is drawn everywhere else:
    /// green ink on a green wash.
    private func replacementChip(_ text: String) -> some View {
        Text(text)
            .font(PlainwordFont.serif(15, weight: .medium))
            .foregroundStyle(PlainwordTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                PlainwordTheme.accentMuted,
                in: RoundedRectangle(
                    cornerRadius: PlainwordTheme.smallCornerRadius,
                    style: .continuous
                )
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labeledText(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel(label)
                // Every labelled section stands its heading in a row of this height,
                // so the text under it sits at the same place whichever section is
                // showing — streamed text becoming a result does not shift it.
                .frame(
                    height: CorrectionPresentationMetrics.previewHeaderHeight,
                    alignment: .leading
                )
            Text(text)
                .font(PlainwordFont.serif(15))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fallbackPreview(_ suggestion: WritingSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                sectionLabel("Proposed edit")
                Spacer(minLength: 8)
                previewModePicker
            }
            .frame(height: CorrectionPresentationMetrics.previewHeaderHeight)

            ZStack(alignment: .topLeading) {
                Group {
                    if model.previewMode == .revised {
                        Text(suggestion.replacementText)
                    } else {
                        Text(attributedDiff(suggestion))
                    }
                }
                .font(PlainwordFont.serif(15))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(model.previewMode)
                .transition(PlainwordMotion.rise)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewModePicker: some View {
        PlainwordSegmentedControl(
            segments: [
                PlainwordSegment(SuggestionPreviewMode.changes, "Changes"),
                PlainwordSegment(SuggestionPreviewMode.revised, "Revised")
            ],
            selection: Binding(
                get: { model.previewMode },
                set: { onPreviewModeChange($0) }
            ),
            accessibilityLabel: "Suggestion preview",
            compact: true
        )
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if model.phase == .prompting {
                if model.showsContextReceipt {
                    contextReceiptToggle
                }
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
                        model.isComposing ? "Write" : "Rewrite",
                        shortcut: "↩",
                        shortcutOpacity: 0.7
                    )
                }
                .buttonStyle(PlainwordButtonStyle(.primary))
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!model.canSubmitPrompt)
            } else if model.isWorking {
                // Only while text is arriving. The processing panel already says
                // "Reading it over…" a few points above this, and one wait does not
                // need two labels.
                if model.phase == .streaming {
                    Text("writing…")
                        .font(PlainwordFont.mono(10))
                        .foregroundStyle(PlainwordTheme.textTertiary)
                }
                Spacer()
                Button("Cancel", action: onDismiss)
                    .buttonStyle(PlainwordButtonStyle())
            } else if case .failure = model.phase {
                Spacer(minLength: 8)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(PlainwordButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if model.canRetry {
                    Button("Try again", action: onRetry)
                        .buttonStyle(PlainwordButtonStyle(.primary))
                }
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
                if model.phase == .ready {
                    Button(action: onAccept) {
                        PlainwordShortcutLabel(
                            acceptTitle,
                            shortcut: "⌘↩",
                            shortcutOpacity: 0.7
                        )
                    }
                        .buttonStyle(PlainwordButtonStyle(.primary))
                        .keyboardShortcut(.return, modifiers: [.command])
                        .accessibilityHint("Press Command-Return to apply")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .frame(height: CorrectionPresentationMetrics.footerHeight)
    }

    private var contextReceiptToggle: some View {
        Button(action: onToggleContextReceipt) {
            Image(systemName: "paperclip")
                .font(PlainwordFont.ui(11, weight: .medium))
                .rotationEffect(.degrees(model.isContextReceiptExpanded ? -20 : 0))
                .frame(width: 24, height: 24)
                .background(
                    model.isContextSendingEnabled
                        ? PlainwordTheme.accentMuted
                        : Color.clear,
                    in: RoundedRectangle(
                        cornerRadius: PlainwordTheme.smallCornerRadius,
                        style: .continuous
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            model.isContextSendingEnabled
                ? PlainwordTheme.accent
                : PlainwordTheme.textSecondary
        )
        .animation(PlainwordMotion.content, value: model.isContextReceiptExpanded)
        .hoverTip("""
        \(ReadOnlyContextReceipt.summary(
                forItemCount: model.contextReceipt.count,
                wasAttached: model.contextIsAttached
            ))
        Only this window. Never password fields.
        """)
        .accessibilityLabel("Attached context")
        .accessibilityValue(
            ReadOnlyContextReceipt.summary(
                forItemCount: model.contextReceipt.count,
                wasAttached: model.contextIsAttached
            )
        )
        .accessibilityHint("Shows what Plainword found around this field")
    }

    private var headerTitle: String {
        switch model.phase {
        case .promptTrigger, .promptTriggerLoading, .applied: ""
        case .prompting:
            model.showsPromptBackButton
                ? "Apply another rewrite"
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

    /// The editor's marks: red pencil through what goes, green ink under what arrives.
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
                fragment.backgroundColor = PlainwordTheme.dangerMuted
                fragment.strikethroughStyle = Text.LineStyle(
                    pattern: .solid,
                    color: PlainwordTheme.danger
                )
            case .inserted:
                fragment.foregroundColor = PlainwordTheme.accent
                fragment.backgroundColor = PlainwordTheme.accentMuted
                fragment.font = PlainwordFont.serif(15, weight: .medium)
            }
            result.append(fragment)
        }
        return result
    }
}

/// A full-width row inside the context receipt that offers to act on what the switch
/// above it now says.
///
/// It rests in the accent's muted tint rather than a fill of its own, so it does not
/// compete with the panel's primary action — and fills in properly under the pointer,
/// because a row that never answers the pointer reads as a label rather than a control.
private struct ContextActionButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isActive = isHovering || configuration.isPressed
        return configuration.label
            .foregroundStyle(
                isActive ? PlainwordTheme.accentText : PlainwordTheme.accent
            )
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ContextReceiptMetrics.actionRowHeight)
            .background(
                background(isPressed: configuration.isPressed),
                in: RoundedRectangle(
                    cornerRadius: PlainwordTheme.smallCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PlainwordTheme.smallCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    isActive ? .clear : PlainwordTheme.accent.opacity(0.4),
                    lineWidth: 1
                )
            }
            .contentShape(Rectangle())
            .animation(PlainwordMotion.content, value: isHovering)
            .animation(PlainwordMotion.content, value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed { return PlainwordTheme.accentStrong }
        return isHovering ? PlainwordTheme.accent : PlainwordTheme.accentMuted
    }
}

/// A borderless glyph in the panel's chrome: quiet until the pointer finds it.
private struct PanelGlyphButton: View {
    let systemImage: String
    let help: String
    var accessibilityLabel: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(PlainwordFont.ui(11, weight: .semibold))
                .foregroundStyle(
                    isHovering ? PlainwordTheme.textPrimary : PlainwordTheme.textSecondary
                )
                .frame(width: 22, height: 22)
                .background(
                    isHovering ? PlainwordTheme.raisedSurface : .clear,
                    in: RoundedRectangle(
                        cornerRadius: PlainwordTheme.smallCornerRadius,
                        style: .continuous
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PlainwordMotion.content, value: isHovering)
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? help)
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

/// The two slanted sides of the tab, as an open path.
///
/// Separate from the filled shape below because a triangle that is stroked as one
/// closed path also draws the base it is supposed to disappear into.
private struct ProposalPointerOutline: Shape {
    let edge: ProposalPointerEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return path
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
