import AppKit
import Carbon.HIToolbox
import Combine
@preconcurrency import CoreGraphics
import PlainwordCore
import OSLog

struct ExcludedApplication: Identifiable, Equatable {
    let id: String
    let name: String
}

struct ActiveApplication: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?

    static func == (lhs: ActiveApplication, rhs: ActiveApplication) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

enum ApplicationExclusionError: LocalizedError {
    case invalidApplication
    case missingBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidApplication:
            "The selected item is not a valid macOS application."
        case .missingBundleIdentifier:
            "The selected application does not have a bundle identifier."
        }
    }
}

@MainActor
final class CrossAppCorrectionController: ObservableObject {
    enum ActivityState: Equatable {
        case permissionRequired
        case providerRequired
        case paused
        case excluded(String)
        case listening
        case waiting
        case correcting(String)
        case suggestion(String)
        case failure(String)

        var label: String {
            switch self {
            case .permissionRequired: "Accessibility needed"
            case .providerRequired: "Provider setup needed"
            case .paused: "Paused"
            case .excluded(let application): "Ignored in \(application)"
            case .listening: "Listening"
            case .waiting: "Ready to review"
            case .correcting(let application): "Improving in \(application)"
            case .suggestion(let application): "Suggestion for \(application)"
            case .failure: "Needs attention"
            }
        }
    }

    @Published private(set) var isAccessibilityTrusted = false
    @Published private(set) var isListeningEnabled: Bool
    @Published private(set) var activity: ActivityState = .permissionRequired
    @Published private(set) var activeApplication: ActiveApplication?
    @Published private(set) var excludedApplications: [ExcludedApplication]

    private let settings: SettingsStore
    private let defaults: UserDefaults
    private let accessibility = AccessibilityTextClient()
    private let accessibilityChanges = AccessibilityChangeObserver()
    private let proposalPanel = CorrectionPanelController()
    private let sourceOverlay = SourceSuggestionOverlayController()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.Plainword",
        category: "Correction"
    )
    private var excludedApplicationIdentifiers: Set<String>
    /// Applications the author has switched interface reading on for. Sending is off
    /// until asked for, so absence from this set is the default.
    private var contextEnabledApplicationIdentifiers: Set<String>
    /// What the surrounding interface offered for the suggestion on screen, whether or
    /// not it was sent. Finding happens on this machine; sending is the separate,
    /// switched decision below.
    private var pendingAvailableContext: TextEditContext?
    /// Whether the suggestion on screen was actually given that context.
    private var pendingRequestSentContext = false
    private var applicationActivationObserver: NSObjectProtocol?
    private var activeApplicationProcessIdentifier: pid_t?
    private var activeApplicationActivationScreenFrame: CGRect?
    private var keyMonitor: Any?
    private var applyShortcutEventTap: CFMachPort?
    private var applyShortcutEventTapSource: CFRunLoopSource?
    /// When the shortcut tap last saw a key press, on the uptime clock.
    ///
    /// A tap can report itself enabled and still be deaf, and that is the failure this
    /// exists to catch. The system knows when a key was last pressed anywhere in the
    /// session; a tap that did not see that press is not delivering, whatever it says
    /// about itself.
    private var lastTapKeyDownUptime: TimeInterval = 0
    private var lastEventDeliveryRebuildUptime: TimeInterval = 0
    private var systemWakeObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var permissionTask: Task<Void, Never>?
    /// Keeps App Nap from throttling the run loop that answers the shortcut tap.
    private var shortcutActivity: NSObjectProtocol?
    private var correctionTask: Task<Void, Never>?
    private var sourceOverlayTrackingTask: Task<Void, Never>?
    private var sourceWindowTrackingTask: Task<Void, Never>?
    private var proposalRevalidationTask: Task<Void, Never>?
    /// Reads the surroundings of an empty field while its prompt is being typed into,
    /// so the receipt can show what a draft would be given before it is asked for.
    private var contextPreviewTask: Task<Void, Never>?
    private var correctionGeneration = 0
    private var applicationTask: Task<Void, Never>?
    private var started = false
    private var isApplyingProposal = false
    private var isProposalVisible = false {
        didSet {
            guard isProposalVisible != oldValue else { return }
            if isProposalVisible {
                startSourceWindowTracking()
            } else {
                stopSourceWindowTracking()
            }
        }
    }
    private var isProposalSuspended = false
    private var isCustomPromptVisible = false
    private var isReviewTriggerVisible = false
    private var isSuggestionPromptTriggerVisible = false
    private var pendingSnapshot: FocusedTextSnapshot? {
        didSet {
            // The panel is anchored to text inside this window. Recording the frame the
            // anchor was measured against is what later movement is measured from.
            sourceWindowFrame = pendingSnapshot.flatMap {
                accessibility.sourceWindowFrame(for: $0)
            }
        }
    }
    private var pendingCorrectionText: String?
    private var pendingSuggestion: WritingSuggestion?
    private var suggestionHistory: [WritingSuggestion] = []
    private var preparedManualSnapshot: FocusedTextSnapshot?
    private var preparedManualSnapshotDate: Date?
    private var pendingPanelAnchor: CGRect?
    private var isPanelAnchorPinned = false
    /// The source window frame the current panel anchor was last reconciled against.
    private var sourceWindowFrame: CGRect?
    private var suggestionCache = CorrectionSuggestionCache()
    /// How recently someone must have typed for the tap's silence to mean anything.
    private static let deafTapObservationWindow: TimeInterval = 3
    /// Slack between the system's record of the last key press and the tap's own, so a
    /// press being handled at this very instant is never read as one that was missed.
    private static let deafTapTolerance: TimeInterval = 1.5
    /// A wrong diagnosis must not become a loop that tears delivery down every poll.
    private static let eventDeliveryRebuildInterval: TimeInterval = 15
    private var reviewShortcutGate = ShortcutInvocationGate(minimumInterval: 0.35)
    private var transformShortcutGate = ShortcutInvocationGate(minimumInterval: 0.35)
    /// The review that is currently running, if there is one.
    ///
    /// A second review press replaces it rather than waiting for it, so this marks the
    /// request to cancel and the panel to reuse when that happens.
    private var runningReviewGeneration: Int?

    init(settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        let storedApplications = defaults.dictionary(forKey: "excludedApplications") as? [String: String]
            ?? [:]
        excludedApplications = Self.sortedApplications(from: storedApplications)
        excludedApplicationIdentifiers = Set(storedApplications.keys)
        contextEnabledApplicationIdentifiers = Set(
            defaults.stringArray(forKey: "contextEnabledApplications") ?? []
        )
        isListeningEnabled = defaults.object(forKey: "assistantListeningEnabled") as? Bool ?? true
    }

    var isReady: Bool {
        isListeningEnabled && isAccessibilityTrusted && settings.isLLMConfigured
    }

    var isActiveApplicationExcluded: Bool {
        guard let activeApplication else { return false }
        return excludedApplicationIdentifiers.contains(activeApplication.id)
    }

    func start() {
        guard !started else { return }
        started = true
        // A menu bar app spends its life in the background, where App Nap is free to
        // throttle it. A throttled run loop answers the event tap too late, and macOS
        // switches shortcut delivery off for being slow.
        shortcutActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Answering global keyboard shortcuts"
        )
        startTrackingActiveApplication()
        startObservingSystemWake()
        refreshAccessibilityState()

        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshAccessibilityState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func requestAccessibilityAccess() {
        _ = accessibility.requestAccess()
        refreshAccessibilityState()
    }

    func setListeningEnabled(_ enabled: Bool) {
        guard enabled != isListeningEnabled else { return }
        isListeningEnabled = enabled
        defaults.set(enabled, forKey: "assistantListeningEnabled")

        if enabled {
            refreshAccessibilityState()
        } else {
            cancelPendingCorrection(dismissProposal: true)
            setEventMonitoringEnabled(false)
            activity = .paused
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func toggleExclusionForActiveApplication() {
        guard let activeApplication else { return }
        setApplication(
            identifier: activeApplication.id,
            name: activeApplication.name,
            isExcluded: !isActiveApplicationExcluded
        )
    }

    func prepareManualReview() {
        // Opening the menu moves focus away from the field, so whatever it offers has
        // to be captured now. An empty field offers its caret.
        guard isReady,
              !isActiveApplicationExcluded,
              let snapshot = accessibility.captureFocusedText(scope: .document)
                ?? accessibility.captureFocusedInsertionPoint() else {
            preparedManualSnapshot = nil
            preparedManualSnapshotDate = nil
            return
        }
        preparedManualSnapshot = snapshot
        preparedManualSnapshotDate = Date()
    }

    func reviewSelectionOrDocument() {
        cancelPendingCorrection(dismissProposal: true)
        guard isReady else {
            updateIdleActivity()
            return
        }

        let preparedSnapshotIsRecent = preparedManualSnapshotDate.map {
            Date().timeIntervalSince($0) <= 15
        } ?? false
        let preparedIsFresh = preparedSnapshotIsRecent
            && preparedManualSnapshot?.applicationIdentifier == activeApplication?.id
        let snapshot = preparedIsFresh
            ? preparedManualSnapshot
            : accessibility.captureFocusedText(scope: .document)
                ?? accessibility.captureFocusedInsertionPoint()
        preparedManualSnapshot = nil
        preparedManualSnapshotDate = nil

        guard let snapshot else {
            activity = .failure(
                "Select up to 1,600 characters or focus a text field containing up to 6,000 characters."
            )
            return
        }
        guard accessibility.snapshotState(snapshot) == .unchanged else {
            activity = .failure("The focused text changed before it could be reviewed.")
            return
        }
        // Nothing to review in an empty field, so write into it instead.
        if snapshot.context.targetKind == .insertionPoint {
            presentComposePrompt(for: snapshot)
            return
        }

        let generation = correctionGeneration
        activity = .waiting
        correctionTask = Task { [weak self] in
            await self?.requestCorrection(
                for: snapshot,
                generation: generation,
                compactPresentation: true
            )
        }
    }

    func transformSelectionOrDocument() {
        cancelPendingCorrection(dismissProposal: true)
        guard isReady else {
            updateIdleActivity()
            return
        }

        let snapshot = consumePreparedManualSnapshot()
            ?? accessibility.captureFocusedText(scope: .document)
            ?? accessibility.captureFocusedInsertionPoint()
        guard let snapshot else {
            activity = .failure(
                "Select up to 1,600 characters or focus a text field containing up to 6,000 characters."
            )
            return
        }
        guard accessibility.snapshotState(snapshot) == .unchanged else {
            activity = .failure("The focused text changed before it could be transformed.")
            return
        }
        // Nothing to transform in an empty field, so write into it instead.
        if snapshot.context.targetKind == .insertionPoint {
            presentComposePrompt(for: snapshot)
            return
        }

        presentCustomPrompt(for: snapshot)
    }

    private func consumePreparedManualSnapshot() -> FocusedTextSnapshot? {
        let preparedSnapshotIsRecent = preparedManualSnapshotDate.map {
            Date().timeIntervalSince($0) <= 15
        } ?? false
        let preparedIsFresh = preparedSnapshotIsRecent
            && preparedManualSnapshot?.applicationIdentifier == activeApplication?.id
        let snapshot = preparedIsFresh ? preparedManualSnapshot : nil
        preparedManualSnapshot = nil
        preparedManualSnapshotDate = nil
        return snapshot
    }

    func allowSuggestions(in application: ExcludedApplication) {
        setApplication(identifier: application.id, name: application.name, isExcluded: false)
    }

    func excludeApplication(at url: URL) throws {
        guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: url) else {
            throw ApplicationExclusionError.invalidApplication
        }
        guard let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            throw ApplicationExclusionError.missingBundleIdentifier
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let applicationName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? bundleName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? url.deletingPathExtension().lastPathComponent

        setApplication(identifier: identifier, name: applicationName, isExcluded: true)
    }

    func icon(for application: ExcludedApplication) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.id
        ) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func dismissProposal() {
        applicationTask?.cancel()
        applicationTask = nil
        isApplyingProposal = false
        correctionTask?.cancel()
        correctionTask = nil
        contextPreviewTask?.cancel()
        contextPreviewTask = nil
        runningReviewGeneration = nil
        pendingSnapshot = nil
        pendingCorrectionText = nil
        pendingSuggestion = nil
        pendingAvailableContext = nil
        pendingRequestSentContext = false
        suggestionHistory.removeAll()
        pendingPanelAnchor = nil
        isPanelAnchorPinned = false
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        dismissProposalUI()
        updateIdleActivity()
    }

    func stop() {
        applicationTask?.cancel()
        correctionTask?.cancel()
        contextPreviewTask?.cancel()
        runningReviewGeneration = nil
        permissionTask?.cancel()
        proposalRevalidationTask?.cancel()
        setEventMonitoringEnabled(false)
        accessibilityChanges.stop()
        stopObservingSystemWake()
        stopTrackingActiveApplication()
        dismissProposalUI()
        if let shortcutActivity {
            ProcessInfo.processInfo.endActivity(shortcutActivity)
        }
        shortcutActivity = nil
        started = false
    }

    private func handleGlobalKeyDown(_ event: NSEvent) {
        // Keyboard-based replacement posts an event to the source process. Its global
        // echo must not cancel the proposal while acceptance is being verified.
        if isApplyingProposal { return }
        if handleApplyShortcut(event) { return }
        if handleTransformShortcut(event) { return }
        if handleReviewShortcut(event) { return }
        if Self.isEscapeKey(event) {
            dismissProposal()
            return
        }
        // Keep an existing proposal open while the user types elsewhere. Escape
        // and the panel's close button are the explicit dismissal actions.
        guard !isProposalVisible else { return }
        // Ordinary typing only invalidates stale review state. Requests are started
        // explicitly by the review shortcut or menu command.
        cancelPendingCorrection(dismissProposal: true)
        updateIdleActivity()
    }

    private func requestCorrection(
        for capturedSnapshot: FocusedTextSnapshot,
        generation: Int,
        compactPresentation: Bool = true
    ) async {
        guard isCurrentCorrection(generation) else { return }
        guard isReady else {
            updateIdleActivity()
            return
        }
        if let identifier = capturedSnapshot.applicationIdentifier,
           excludedApplicationIdentifiers.contains(identifier) {
            activity = .excluded(capturedSnapshot.applicationName)
            return
        }
        guard capturedSnapshot.context.text
            .trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            updateIdleActivity()
            return
        }

        let contextualized = await contextualized(capturedSnapshot)
        guard isCurrentCorrection(generation) else { return }
        let snapshot = contextualized.sent
        pendingAvailableContext = contextualized.available
        pendingRequestSentContext = isContextSendingEnabled(
            forApplicationIdentifier: snapshot.applicationIdentifier
        )

        let promptLocaleIdentifier = promptLanguageIdentifier(for: snapshot.context)
        let intent = EditIntent.correct

        let cacheKey = correctionCacheKey(
            for: snapshot.context,
            intent: intent,
            locale: promptLocaleIdentifier
        )
        if let cached = suggestionCache.value(for: cacheKey) {
            logger.debug("Correction cache hit for intent \(intent.rawValue, privacy: .public)")
            switch cached {
            case .unchanged:
                finishReviewWithoutSuggestion(compactPresentation: compactPresentation)
            case .suggestion(let suggestion):
                guard accessibility.snapshotState(snapshot) == .unchanged else {
                    updateIdleActivity()
                    return
                }
                present(suggestion, for: snapshot, compact: compactPresentation)
            }
            return
        }

        activity = .correcting(snapshot.applicationName)
        pendingSnapshot = snapshot
        pendingCorrectionText = nil
        pendingSuggestion = nil
        let requestStartedAt = Date()
        logger.debug(
            "Starting \(intent.rawValue, privacy: .public) request with target UTF-16 length \((snapshot.context.text as NSString).length, privacy: .public) and application context length \((snapshot.context.applicationContext as NSString).length, privacy: .public)"
        )

        do {
            var correctionResponse: CorrectionResponse?
            let stream = try settings.streamCorrection(
                snapshot.context,
                intent: intent,
                locale: promptLocaleIdentifier
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .partialText(let text):
                    // The compact review shows nothing but a small marker until it has
                    // a result, so there is no panel there to write into.
                    guard !compactPresentation,
                          isCurrentCorrection(generation),
                          Self.hasDiverged(text, from: snapshot.context.text) else {
                        continue
                    }
                    proposalPanel.updateStreamingText(text)
                case .completed(let response):
                    correctionResponse = response
                }
            }
            guard let correctionResponse else {
                throw ChatCompletionsClientError.invalidResponse
            }
            guard isCurrentCorrection(generation) else { return }
            let elapsedMilliseconds = Int(Date().timeIntervalSince(requestStartedAt) * 1_000)
            logger.debug(
                "Correction request completed in \(elapsedMilliseconds, privacy: .public) ms"
            )

            // Chromium can temporarily stop answering AX range queries while its
            // accessibility tree is being updated. Only publish a proposal after the
            // original editor state is positively confirmed; an unavailable snapshot
            // would otherwise produce a panel whose action can never be applied.
            guard accessibility.snapshotState(snapshot) == .unchanged else {
                pendingSnapshot = nil
                pendingCorrectionText = nil
                pendingSuggestion = nil
                dismissProposalUI()
                updateIdleActivity()
                return
            }

            guard let suggestion = WritingSuggestionPlanner.make(
                originalText: snapshot.context.text,
                replacementText: correctionResponse.correctedText,
                completionIsAllowed: snapshot.context.completionIsAllowed,
                classifiedAs: correctionResponse.classification
            ) else {
                suggestionCache.insert(.unchanged, for: cacheKey)
                pendingSnapshot = nil
                pendingCorrectionText = nil
                pendingSuggestion = nil
                finishReviewWithoutSuggestion(compactPresentation: compactPresentation)
                return
            }

            suggestionCache.insert(.suggestion(suggestion), for: cacheKey)
            present(suggestion, for: snapshot, compact: compactPresentation)
        } catch is CancellationError {
            guard correctionGeneration == generation else { return }
            pendingSnapshot = nil
            pendingCorrectionText = nil
            pendingSuggestion = nil
            dismissProposalUI()
            updateIdleActivity()
        } catch {
            guard isCurrentCorrection(generation) else { return }
            pendingSnapshot = nil
            pendingCorrectionText = nil
            pendingSuggestion = nil
            activity = .failure(error.localizedDescription)
            if isProposalVisible {
                proposalPanel.showFailure(error.localizedDescription) { [weak self] in
                    self?.retryCorrection(
                        for: capturedSnapshot,
                        compactPresentation: compactPresentation
                    )
                }
            }
        }
    }

    private func presentCustomPrompt(for snapshot: FocusedTextSnapshot) {
        correctionGeneration &+= 1
        applicationTask?.cancel()
        applicationTask = nil
        correctionTask?.cancel()
        correctionTask = nil
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        stopSourceOverlay()

        let previousSuggestion = pendingSuggestion
        let editContext = snapshot.context.withEditableText(
            pendingCorrectionText ?? snapshot.context.text
        )
        let onBack: (() -> Void)?
        if let previousSuggestion {
            onBack = { [weak self] in
                self?.restoreSuggestion(previousSuggestion, for: snapshot)
            }
        } else {
            onBack = nil
        }

        pendingSnapshot = snapshot
        pendingCorrectionText = nil
        pendingSuggestion = nil
        isProposalVisible = true
        isProposalSuspended = false
        isCustomPromptVisible = true
        isReviewTriggerVisible = false
        activity = .waiting
        let anchor = pendingPanelAnchor ?? snapshot.anchor
        pendingPanelAnchor = anchor
        proposalPanel.showPrompt(
            near: anchor,
            title: Self.transformPromptTitle(
                for: snapshot,
                previousSuggestion: previousSuggestion
            ),
            onSubmit: { [weak self] prompt in
                self?.submitCustomPrompt(
                    prompt,
                    editing: editContext,
                    previousSuggestion: previousSuggestion
                )
            },
            onBack: onBack,
            onDismiss: { [weak self] in
                self?.dismissProposal()
            }
        )
    }

    /// A draft has not been inserted anywhere yet, so a transform of one is named by
    /// the text it acts on rather than by the empty field behind it.
    private static func transformPromptTitle(
        for snapshot: FocusedTextSnapshot,
        previousSuggestion: WritingSuggestion?
    ) -> String {
        if previousSuggestion?.kind == .composition {
            return "Transform draft"
        }
        return snapshot.context.targetKind == .document
            ? "Transform entire field"
            : "Transform selection"
    }

    /// Names what a transform is working on, so a failure reads the same way whether the
    /// text came from the field or from a draft waiting to be inserted.
    private static func transformSubject(previousSuggestion: WritingSuggestion?) -> String {
        previousSuggestion?.kind == .composition ? "draft" : "selected text"
    }

    private func presentComposePrompt(for snapshot: FocusedTextSnapshot) {
        correctionGeneration &+= 1
        let generation = correctionGeneration
        applicationTask?.cancel()
        applicationTask = nil
        correctionTask?.cancel()
        correctionTask = nil
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        contextPreviewTask?.cancel()
        contextPreviewTask = nil
        stopSourceOverlay()

        pendingSnapshot = snapshot
        pendingCorrectionText = nil
        pendingSuggestion = nil
        pendingAvailableContext = nil
        pendingRequestSentContext = false
        suggestionHistory.removeAll()
        isProposalVisible = true
        isProposalSuspended = false
        isCustomPromptVisible = true
        isReviewTriggerVisible = false
        activity = .waiting
        let anchor = pendingPanelAnchor ?? snapshot.anchor
        pendingPanelAnchor = anchor
        proposalPanel.showPrompt(
            near: anchor,
            title: "Write something",
            isComposing: true,
            // What the field itself offers — the application it belongs to, and
            // whatever the caret sits between. The interface around it takes a moment
            // longer to read and joins the list below.
            contextReceipt: ReadOnlyContextReceipt.items(for: snapshot.context),
            contextApplicationName: snapshot.applicationName,
            isContextSendingEnabled: isContextSendingEnabled(
                forApplicationIdentifier: snapshot.applicationIdentifier
            ),
            onSubmit: { [weak self] prompt in
                self?.submitComposePrompt(prompt)
            },
            onDismiss: { [weak self] in
                self?.dismissProposal()
            },
            onSetContextSendingEnabled: { [weak self] isEnabled in
                self?.setContextSendingEnabled(
                    isEnabled,
                    forApplicationIdentifier: snapshot.applicationIdentifier
                )
            }
        )
        previewContext(for: snapshot, generation: generation)
    }

    /// Reads the surrounding interface while the compose prompt is open, and shows the
    /// author what it found.
    ///
    /// A draft is written from nothing, so what the interface says around the field is
    /// most of what the request has to go on — and an empty field has never had a
    /// suggestion of its own to have offered the switch. Reading happens on this
    /// machine whatever the switch says, exactly as it does for a suggestion: the list
    /// is what the decision is about, and nothing leaves until the request does.
    private func previewContext(for snapshot: FocusedTextSnapshot, generation: Int) {
        contextPreviewTask = Task { [weak self] in
            guard let self else { return }
            let available = await accessibility.enriched(snapshot.context, for: snapshot)
            guard isCurrentCorrection(generation), isCustomPromptVisible else { return }
            pendingAvailableContext = available
            proposalPanel.updateContextReceipt(
                ReadOnlyContextReceipt.items(for: available)
            )
        }
    }

    private func submitComposePrompt(_ rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              prompt.count <= 500,
              let snapshot = pendingSnapshot else {
            return
        }
        guard accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            activity = .failure("The field changed before anything could be written.")
            return
        }

        correctionGeneration &+= 1
        let generation = correctionGeneration
        contextPreviewTask?.cancel()
        contextPreviewTask = nil
        isCustomPromptVisible = false
        activity = .correcting(snapshot.applicationName)
        proposalPanel.showProcessing(
            near: pendingPanelAnchor ?? snapshot.anchor,
            onAccept: {},
            onDismiss: { [weak self] in
                self?.dismissProposal()
            }
        )
        correctionTask = Task { [weak self] in
            await self?.requestComposition(
                prompt,
                for: snapshot,
                generation: generation
            )
        }
    }

    private func requestComposition(
        _ instruction: String,
        for snapshot: FocusedTextSnapshot,
        generation: Int
    ) async {
        let contextualized = await contextualized(snapshot.context, for: snapshot)
        guard isCurrentCorrection(generation) else { return }
        let requestContext = contextualized.sent
        pendingAvailableContext = contextualized.available
        pendingRequestSentContext = isContextSendingEnabled(
            forApplicationIdentifier: snapshot.applicationIdentifier
        )

        do {
            var correctionResponse: CorrectionResponse?
            let stream = try settings.streamCorrection(
                requestContext,
                intent: .compose,
                locale: promptLanguageIdentifier(forInstruction: instruction),
                instruction: instruction
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .partialText(let text):
                    guard isCurrentCorrection(generation),
                          Self.hasDiverged(text, from: requestContext.text) else {
                        continue
                    }
                    proposalPanel.updateStreamingText(text)
                case .completed(let response):
                    correctionResponse = response
                }
            }
            guard let correctionResponse else {
                throw ChatCompletionsClientError.invalidResponse
            }
            guard isCurrentCorrection(generation) else { return }
            guard accessibility.snapshotState(snapshot) == .unchanged else {
                pendingSnapshot = nil
                pendingCorrectionText = nil
                pendingSuggestion = nil
                dismissProposalUI()
                activity = .failure("The field changed before anything could be written.")
                return
            }
            guard let suggestion = WritingSuggestionPlanner.makeComposition(
                correctionResponse.correctedText
            ) else {
                dismissProposal()
                activity = .failure("That instruction did not produce any text.")
                return
            }
            present(suggestion, for: snapshot, compact: false)
        } catch is CancellationError {
            guard correctionGeneration == generation else { return }
            dismissProposal()
        } catch {
            guard isCurrentCorrection(generation) else { return }
            correctionTask = nil
            pendingCorrectionText = nil
            pendingSuggestion = nil
            activity = .failure(error.localizedDescription)
            proposalPanel.showFailure(error.localizedDescription) { [weak self] in
                self?.retryComposition(instruction, for: snapshot)
            }
        }
    }

    private func restoreSuggestion(
        _ suggestion: WritingSuggestion,
        for snapshot: FocusedTextSnapshot
    ) {
        guard accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            return
        }
        present(suggestion, for: snapshot, compact: false)
    }

    private func presentReviewTrigger(
        for snapshot: FocusedTextSnapshot,
        near anchorOverride: CGRect? = nil
    ) {
        correctionGeneration &+= 1
        correctionTask?.cancel()
        correctionTask = nil
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        stopSourceOverlay()

        pendingSnapshot = snapshot
        pendingCorrectionText = nil
        pendingSuggestion = nil
        suggestionHistory.removeAll()
        isProposalVisible = true
        isProposalSuspended = false
        isCustomPromptVisible = false
        isReviewTriggerVisible = true
        activity = .waiting
        let anchor = anchorOverride ?? snapshot.anchor
        pendingPanelAnchor = anchor
        isPanelAnchorPinned = true
        proposalPanel.showPromptTrigger(
            near: anchor,
            onOpen: { [weak self] in
                self?.reviewPendingText()
            },
            onDismiss: { [weak self] in
                self?.dismissProposal()
            }
        )
    }

    private func reviewPendingText() {
        guard let snapshot = pendingSnapshot,
              accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            return
        }
        startReview(for: snapshot)
    }

    /// Runs a review through the panel that is already on screen.
    private func startReview(for snapshot: FocusedTextSnapshot) {
        correctionGeneration &+= 1
        let generation = correctionGeneration
        runningReviewGeneration = generation
        isReviewTriggerVisible = false
        activity = .correcting(snapshot.applicationName)
        proposalPanel.showPromptTriggerLoading()
        correctionTask = Task { [weak self] in
            guard let self else { return }
            await self.requestCorrection(
                for: snapshot,
                generation: generation,
                compactPresentation: false
            )
            if self.runningReviewGeneration == generation {
                self.runningReviewGeneration = nil
            }
        }
    }

    /// Drops the review that is running and reviews whatever is focused now.
    ///
    /// The cancelled request's panel stays on screen and returns to its loading marker.
    /// Dismissing it and building a new one in the same pass leaves AppKit laying out a
    /// panel that is already gone, which is what made a second press unsafe before.
    private func restartRunningReview() {
        correctionGeneration &+= 1
        runningReviewGeneration = nil
        correctionTask?.cancel()
        correctionTask = nil
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        stopSourceOverlay()
        pendingCorrectionText = nil
        pendingSuggestion = nil
        pendingAvailableContext = nil
        pendingRequestSentContext = false
        suggestionHistory.removeAll()

        guard let snapshot = captureSnapshotForExplicitReview(),
              snapshot.context.text
                .trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            // Nothing left to review, so the cancelled request's panel has no result
            // coming and closing it is the only honest thing to do.
            dismissProposal()
            activity = .failure(
                "Select text or place the cursor in a paragraph to review it."
            )
            return
        }

        pendingSnapshot = snapshot
        pendingPanelAnchor = snapshot.anchor
        isPanelAnchorPinned = true
        proposalPanel.reposition(near: snapshot.anchor, animated: true)
        startReview(for: snapshot)
    }

    /// Whether streamed text has anything to show yet.
    ///
    /// The prompt tells the model to return text it found nothing wrong with unchanged,
    /// so a clean check arrives as the author's own sentence echoed back a character at
    /// a time. Drawing that grows the panel through the whole echo and then collapses it
    /// to "No changes": the review reads as though it wrote something and took it back.
    ///
    /// Text is held until it stops agreeing with the original. An edit shows from the
    /// word it changes, a completion from the point it runs past the end, a draft from
    /// its first character — there is no original for it to agree with — and an echo
    /// never shows at all, leaving the panel where it was until the verdict arrives.
    private static func hasDiverged(_ streamed: String, from original: String) -> Bool {
        !original.hasPrefix(streamed)
    }

    private func finishReviewWithoutSuggestion(compactPresentation: Bool) {
        updateIdleActivity()
        guard !compactPresentation else {
            dismissProposalUI()
            return
        }
        isProposalVisible = true
        isCustomPromptVisible = false
        isReviewTriggerVisible = false
        isSuggestionPromptTriggerVisible = false
        proposalPanel.showUnchanged()
    }

    private func showCustomPromptForPendingText() {
        guard let snapshot = pendingSnapshot,
              accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            return
        }
        presentCustomPrompt(for: snapshot)
    }

    private func submitCustomPrompt(
        _ rawPrompt: String,
        editing editContext: TextEditContext,
        previousSuggestion: WritingSuggestion?
    ) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              prompt.count <= 500,
              let snapshot = pendingSnapshot else {
            return
        }
        guard accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            let subject = Self.transformSubject(previousSuggestion: previousSuggestion)
            activity = .failure("The \(subject) changed before it could be transformed.")
            return
        }

        correctionGeneration &+= 1
        let generation = correctionGeneration
        isCustomPromptVisible = false
        activity = .correcting(snapshot.applicationName)
        proposalPanel.showProcessing(
            near: pendingPanelAnchor ?? snapshot.anchor,
            onAccept: {},
            onDismiss: { [weak self] in
                self?.dismissProposal()
            }
        )
        correctionTask = Task { [weak self] in
            await self?.requestCustomEdit(
                prompt,
                for: snapshot,
                editing: editContext,
                previousSuggestion: previousSuggestion,
                generation: generation
            )
        }
    }

    private func requestCustomEdit(
        _ instruction: String,
        for snapshot: FocusedTextSnapshot,
        editing capturedEditContext: TextEditContext,
        previousSuggestion: WritingSuggestion?,
        generation: Int
    ) async {
        let contextualized = await contextualized(capturedEditContext, for: snapshot)
        guard isCurrentCorrection(generation) else { return }
        let editContext = contextualized.sent
        pendingAvailableContext = contextualized.available
        pendingRequestSentContext = isContextSendingEnabled(
            forApplicationIdentifier: snapshot.applicationIdentifier
        )
        let locale = promptLanguageIdentifier(for: editContext)
        // Transforming a draft leaves it a draft: the field is still empty, so the
        // result has no original in it to diff against or mark up.
        let isDraft = previousSuggestion?.kind == .composition
        let subject = Self.transformSubject(previousSuggestion: previousSuggestion)

        do {
            var correctionResponse: CorrectionResponse?
            let stream = try settings.streamCorrection(
                editContext,
                intent: .correct,
                locale: locale,
                instruction: instruction
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .partialText(let text):
                    guard isCurrentCorrection(generation),
                          Self.hasDiverged(text, from: editContext.text) else {
                        continue
                    }
                    proposalPanel.updateStreamingText(text)
                case .completed(let response):
                    correctionResponse = response
                }
            }
            guard let correctionResponse else {
                throw ChatCompletionsClientError.invalidResponse
            }
            guard isCurrentCorrection(generation) else { return }
            guard accessibility.snapshotState(snapshot) == .unchanged else {
                pendingSnapshot = nil
                pendingCorrectionText = nil
                pendingSuggestion = nil
                dismissProposalUI()
                activity = .failure("The \(subject) changed before it could be transformed.")
                return
            }

            guard correctionResponse.correctedText != editContext.text else {
                dismissProposal()
                activity = .failure("That instruction did not change the \(subject).")
                return
            }

            let planned = isDraft
                ? WritingSuggestionPlanner.makeComposition(correctionResponse.correctedText)
                : WritingSuggestionPlanner.make(
                    originalText: snapshot.context.text,
                    replacementText: correctionResponse.correctedText,
                    completionIsAllowed: false,
                    classifiedAs: correctionResponse.classification
                )
            guard let suggestion = planned else {
                dismissProposal()
                activity = .failure("That instruction did not change the \(subject).")
                return
            }
            if let previousSuggestion {
                suggestionHistory.append(previousSuggestion)
            }
            present(suggestion, for: snapshot, compact: false)
        } catch is CancellationError {
            guard correctionGeneration == generation else { return }
            dismissProposal()
        } catch {
            guard isCurrentCorrection(generation) else { return }
            correctionTask = nil
            pendingCorrectionText = nil
            pendingSuggestion = nil
            activity = .failure(error.localizedDescription)
            proposalPanel.showFailure(error.localizedDescription) { [weak self] in
                self?.retryCustomEdit(
                    instruction,
                    for: snapshot,
                    editing: capturedEditContext,
                    previousSuggestion: previousSuggestion
                )
            }
        }
    }

    /// Runs a request again from the panel that reported it failed.
    ///
    /// The failure cleared everything pending, so each retry carries the same values
    /// its first attempt was given rather than reading state that is no longer there.
    private func retryCorrection(
        for snapshot: FocusedTextSnapshot,
        compactPresentation: Bool
    ) {
        let generation = beginRetry(for: snapshot)
        correctionTask = Task { [weak self] in
            await self?.requestCorrection(
                for: snapshot,
                generation: generation,
                compactPresentation: compactPresentation
            )
        }
    }

    private func retryComposition(
        _ instruction: String,
        for snapshot: FocusedTextSnapshot
    ) {
        let generation = beginRetry(for: snapshot)
        correctionTask = Task { [weak self] in
            await self?.requestComposition(
                instruction,
                for: snapshot,
                generation: generation
            )
        }
    }

    private func retryCustomEdit(
        _ instruction: String,
        for snapshot: FocusedTextSnapshot,
        editing editContext: TextEditContext,
        previousSuggestion: WritingSuggestion?
    ) {
        let generation = beginRetry(for: snapshot)
        correctionTask = Task { [weak self] in
            await self?.requestCustomEdit(
                instruction,
                for: snapshot,
                editing: editContext,
                previousSuggestion: previousSuggestion,
                generation: generation
            )
        }
    }

    private func beginRetry(for snapshot: FocusedTextSnapshot) -> Int {
        correctionGeneration &+= 1
        activity = .correcting(snapshot.applicationName)
        proposalPanel.showProcessing(
            near: pendingPanelAnchor ?? snapshot.anchor,
            onAccept: {},
            onDismiss: { [weak self] in
                self?.dismissProposal()
            }
        )
        isProposalVisible = true
        return correctionGeneration
    }

    func isContextSendingEnabled(forApplicationIdentifier identifier: String?) -> Bool {
        guard let identifier else { return false }
        return contextEnabledApplicationIdentifiers.contains(identifier)
    }

    /// Records whether the next suggestion in this application should be sent the
    /// surrounding interface.
    ///
    /// This issues no request. The suggestion on screen was already made under the
    /// previous setting and is left exactly as it is; only what the panel says about it
    /// changes.
    private func setContextSendingEnabled(
        _ isEnabled: Bool,
        forApplicationIdentifier identifier: String?
    ) {
        guard let identifier else { return }
        if isEnabled {
            contextEnabledApplicationIdentifiers.insert(identifier)
        } else {
            contextEnabledApplicationIdentifiers.remove(identifier)
            // Entries made while sending was on carry that context in their key, but
            // dropping them keeps a suggestion that was shaped by the interface from
            // reappearing once the author has asked for that to stop.
            suggestionCache = CorrectionSuggestionCache()
        }
        defaults.set(
            Array(contextEnabledApplicationIdentifiers).sorted(),
            forKey: "contextEnabledApplications"
        )
    }

    /// Reads the surrounding interface and returns both what it offered and what should
    /// actually be sent.
    ///
    /// Reading happens on this machine either way, so the panel can always show what is
    /// there; only the `sent` context leaves it. The author's own sentences on either
    /// side of the edit always travel with the request — those are the text being worked
    /// on, not something read from the interface.
    private func contextualized(
        _ snapshot: FocusedTextSnapshot
    ) async -> (sent: FocusedTextSnapshot, available: TextEditContext) {
        let enriched = await accessibility.enriched(snapshot)
        guard isContextSendingEnabled(
            forApplicationIdentifier: snapshot.applicationIdentifier
        ) else {
            return (
                enriched.withContext(enriched.context.withApplicationContext([])),
                enriched.context
            )
        }
        return (enriched, enriched.context)
    }

    private func contextualized(
        _ context: TextEditContext,
        for snapshot: FocusedTextSnapshot
    ) async -> (sent: TextEditContext, available: TextEditContext) {
        let enriched = await accessibility.enriched(context, for: snapshot)
        guard isContextSendingEnabled(
            forApplicationIdentifier: snapshot.applicationIdentifier
        ) else {
            return (enriched.withApplicationContext([]), enriched)
        }
        return (enriched, enriched)
    }

    private func promptLanguageIdentifier(for context: TextEditContext) -> String {
        promptLanguageIdentifier(
            detecting: TextLanguageDetector.dominantLanguageIdentifier(in: context)
        )
    }

    /// Composing has no text of its own yet, so the instruction is the only thing whose
    /// language the result can be expected to match.
    private func promptLanguageIdentifier(forInstruction instruction: String) -> String {
        promptLanguageIdentifier(
            detecting: TextLanguageDetector.dominantLanguageIdentifier(in: instruction)
        )
    }

    private func promptLanguageIdentifier(detecting detected: @autoclosure () -> String?) -> String {
        switch settings.spellingLanguageMode {
        case .fixed:
            return settings.fixedSpellingLanguageIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? "unspecified"
        case .automatic:
            return detected() ?? "unspecified"
        case .disabled:
            return "unspecified"
        }
    }

    private func correctionCacheKey(
        for context: TextEditContext,
        intent: EditIntent,
        locale: String
    ) -> CorrectionCacheKey {
        let llmSettings = settings.llmSettings
        return CorrectionCacheKey(
            endpoint: llmSettings.resolvedEndpoint
                .trimmingCharacters(in: .whitespacesAndNewlines),
            model: llmSettings.resolvedModel
                .trimmingCharacters(in: .whitespacesAndNewlines),
            locale: locale,
            tone: settings.tone.rawValue,
            style: settings.style.rawValue,
            thinkingMode: llmSettings.thinkingMode.rawValue,
            intent: intent,
            context: context
        )
    }

    private func present(
        _ suggestion: WritingSuggestion,
        for snapshot: FocusedTextSnapshot,
        compact: Bool = true
    ) {
        stopSourceOverlay()
        // The request can finish after the user has switched applications. Hide the
        // completed UI when another app took over its display, but keep it available
        // when the user is working independently on a different display.
        isProposalSuspended = shouldSuspendProposal(
            forSourceProcessIdentifier: snapshot.processIdentifier,
            sourceAnchor: snapshot.anchor
        )
        isCustomPromptVisible = false
        isReviewTriggerVisible = false
        isSuggestionPromptTriggerVisible = compact
        pendingSnapshot = snapshot
        pendingCorrectionText = suggestion.replacementText
        pendingSuggestion = suggestion
        activity = .suggestion(snapshot.applicationName)

        if compact {
            // Keep the compact action beside the reviewed target. A correction's source
            // geometry may point to an earlier line in browser editors and make the icon
            // appear detached from the user's text.
            let anchor = snapshot.anchor
            pendingPanelAnchor = anchor
            isPanelAnchorPinned = true
            proposalPanel.showPromptTrigger(
                near: anchor,
                onOpen: { [weak self] in
                    self?.expandPendingSuggestion()
                },
                onDismiss: { [weak self] in
                    self?.dismissProposal()
                }
            )
            if isProposalSuspended {
                proposalPanel.suspendVisibility()
            }
            isProposalVisible = true
            return
        }

        showExpandedSuggestion(suggestion, for: snapshot)
    }

    private func expandPendingSuggestion() {
        guard let snapshot = pendingSnapshot,
              let suggestion = pendingSuggestion,
              accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            return
        }
        isSuggestionPromptTriggerVisible = false
        showExpandedSuggestion(suggestion, for: snapshot)
    }

    private func showExpandedSuggestion(
        _ suggestion: WritingSuggestion,
        for snapshot: FocusedTextSnapshot
    ) {
        let geometry = accessibility.sourceSuggestionGeometry(
            for: snapshot,
            suggestion: suggestion
        )
        let presentation: SuggestionPresentationMode = geometry == nil
            ? .fallback
            : .sourceOverlay
        let anchor = pendingPanelAnchor ?? geometry?.anchor ?? snapshot.anchor
        pendingPanelAnchor = anchor
        let onBack: (() -> Void)? = suggestionHistory.isEmpty
            ? nil
            : { [weak self] in self?.restorePreviousSuggestion() }
        proposalPanel.showSuggestion(
            suggestion,
            presentation: presentation,
            contextReceipt: ReadOnlyContextReceipt.items(
                for: pendingAvailableContext ?? snapshot.context
            ),
            contextApplicationName: snapshot.applicationName,
            isContextSendingEnabled: isContextSendingEnabled(
                forApplicationIdentifier: snapshot.applicationIdentifier
            ),
            contextWasSentWithSuggestion: pendingRequestSentContext,
            near: anchor,
            onAccept: { [weak self] in
                self?.acceptProposal()
            },
            onDismiss: { [weak self] in
                self?.dismissProposal()
            },
            onBack: onBack,
            onRequestPrompt: { [weak self] in
                self?.showCustomPromptForPendingText()
            },
            onSetContextSendingEnabled: { [weak self] isEnabled in
                self?.setContextSendingEnabled(
                    isEnabled,
                    forApplicationIdentifier: snapshot.applicationIdentifier
                )
            }
        )
        if isProposalSuspended {
            proposalPanel.suspendVisibility()
        } else if let geometry {
            sourceOverlay.show(
                geometry,
                below: proposalPanel.windowNumber
            )
        }
        isProposalVisible = true
        if !isProposalSuspended,
           accessibility.supportsSourceSuggestionOverlay(suggestion) {
            startSourceOverlayTracking(
                snapshot: snapshot,
                suggestion: suggestion,
                initiallyAvailable: geometry != nil
            )
        }
    }

    private func restorePreviousSuggestion() {
        guard let snapshot = pendingSnapshot,
              let suggestion = suggestionHistory.popLast(),
              accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            return
        }
        present(suggestion, for: snapshot, compact: false)
    }

    private func startSourceOverlayTracking(
        snapshot: FocusedTextSnapshot,
        suggestion: WritingSuggestion,
        initiallyAvailable: Bool
    ) {
        sourceOverlayTrackingTask?.cancel()
        sourceOverlayTrackingTask = Task { [weak self] in
            var isShowingSourceOverlay = initiallyAvailable
            var consecutiveGeometryFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self,
                      self.pendingSnapshot?.fingerprint == snapshot.fingerprint else {
                    return
                }

                if let geometry = self.accessibility.sourceSuggestionGeometry(
                    for: snapshot,
                    suggestion: suggestion
                ) {
                    consecutiveGeometryFailures = 0
                    self.sourceOverlay.show(
                        geometry,
                        below: self.proposalPanel.windowNumber
                    )
                    let panelAnchor: CGRect
                    if self.isPanelAnchorPinned, let pinnedAnchor = self.pendingPanelAnchor {
                        panelAnchor = pinnedAnchor
                    } else {
                        panelAnchor = geometry.anchor
                        self.pendingPanelAnchor = panelAnchor
                    }
                    if isShowingSourceOverlay {
                        self.proposalPanel.reposition(near: panelAnchor, animated: false)
                    } else {
                        isShowingSourceOverlay = true
                        self.proposalPanel.updateSuggestionPresentation(
                            .sourceOverlay,
                            near: panelAnchor
                        )
                    }
                } else {
                    consecutiveGeometryFailures += 1
                    // AX geometry can be briefly unavailable while a native text
                    // control lays out, scrolls, or changes focus. Retain the last
                    // known-good mark for two seconds before falling back, and keep
                    // polling so the inline presentation can recover later.
                    if isShowingSourceOverlay,
                       consecutiveGeometryFailures >= 8 {
                        isShowingSourceOverlay = false
                        consecutiveGeometryFailures = 0
                        self.sourceOverlay.dismiss()
                        let panelAnchor = self.isPanelAnchorPinned
                            ? self.pendingPanelAnchor ?? snapshot.anchor
                            : snapshot.anchor
                        if !self.isPanelAnchorPinned {
                            self.pendingPanelAnchor = panelAnchor
                        }
                        self.proposalPanel.updateSuggestionPresentation(
                            .fallback,
                            near: panelAnchor
                        )
                    }
                }
            }
        }
    }

    private func stopSourceOverlay() {
        sourceOverlayTrackingTask?.cancel()
        sourceOverlayTrackingTask = nil
        sourceOverlay.dismiss()
    }

    /// Polls the source window while a proposal is on screen.
    ///
    /// Window notifications are the fast path, but applications are not required to post
    /// them and some only report a drag once it ends. This keeps the panel attached in
    /// those applications too, and costs nothing while the proposal is suspended.
    private func startSourceWindowTracking() {
        sourceWindowTrackingTask?.cancel()
        sourceWindowTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.followSourceWindowMovement()
            }
        }
    }

    private func stopSourceWindowTracking() {
        sourceWindowTrackingTask?.cancel()
        sourceWindowTrackingTask = nil
    }

    /// Moves the panel with the window that draws the text it points at.
    ///
    /// Dragging or resizing a window moves the reviewed text without changing it. A
    /// proposal that stayed where it was would underline the wrong words, which is worse
    /// than not being there at all.
    private func followSourceWindowMovement() {
        guard isProposalVisible,
              !isProposalSuspended,
              let snapshot = pendingSnapshot,
              activeApplicationProcessIdentifier == snapshot.processIdentifier,
              let delta = consumeSourceWindowTranslation(for: snapshot) else {
            return
        }

        if let anchor = pendingPanelAnchor {
            pendingPanelAnchor = anchor.offsetBy(dx: delta.width, dy: delta.height)
        }
        proposalPanel.translate(by: delta)
        refreshSourceOverlayGeometry()
    }

    /// Returns how far the source window moved since the panel anchor was last
    /// reconciled with it, and records the new frame as the reference for the next call.
    ///
    /// Movement is measured from the top-left corner because text lays out from the top:
    /// a window resized by its bottom edge does not move the text above it.
    private func consumeSourceWindowTranslation(
        for snapshot: FocusedTextSnapshot
    ) -> CGSize? {
        guard let currentFrame = accessibility.sourceWindowFrame(for: snapshot) else {
            return nil
        }
        defer { sourceWindowFrame = currentFrame }
        guard let previousFrame = sourceWindowFrame else { return nil }

        let delta = CGSize(
            width: currentFrame.minX - previousFrame.minX,
            height: currentFrame.maxY - previousFrame.maxY
        )
        guard abs(delta.width) >= 1 || abs(delta.height) >= 1 else { return nil }
        return delta
    }

    /// Redraws the source marks immediately after the window moved, so an underline
    /// cannot sit on the old glyphs until the next geometry poll.
    private func refreshSourceOverlayGeometry() {
        guard sourceOverlayTrackingTask != nil,
              let snapshot = pendingSnapshot,
              let suggestion = pendingSuggestion,
              let geometry = accessibility.sourceSuggestionGeometry(
                for: snapshot,
                suggestion: suggestion
              ) else {
            return
        }
        sourceOverlay.show(geometry, below: proposalPanel.windowNumber)
    }

    private func scheduleProposalRevalidation(initialDelayMilliseconds: Int = 0) {
        proposalRevalidationTask?.cancel()
        guard isProposalVisible,
              let originalSnapshot = pendingSnapshot,
              let suggestion = pendingSuggestion else {
            return
        }

        proposalRevalidationTask = Task { [weak self] in
            for attempt in 0..<6 {
                if attempt == 0, initialDelayMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(initialDelayMilliseconds))
                } else if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                guard !Task.isCancelled, let self,
                      self.isProposalVisible,
                      self.pendingSnapshot?.fingerprint == originalSnapshot.fingerprint else {
                    return
                }

                // Keep the proposal while the user is in another application. The
                // source AX tree may be unavailable until its app becomes active again.
                guard self.activeApplicationProcessIdentifier == originalSnapshot.processIdentifier else {
                    self.proposalRevalidationTask = nil
                    return
                }

                switch self.accessibility.snapshotState(originalSnapshot) {
                case .unchanged:
                    self.restoreProposal(
                        suggestion,
                        for: originalSnapshot
                    )
                    self.proposalRevalidationTask = nil
                    return
                case .changed:
                    self.proposalRevalidationTask = nil
                    self.dismissProposal()
                    return
                case .unavailable:
                    if let refreshedSnapshot = self.accessibility.refreshedSnapshot(
                        matching: originalSnapshot
                    ) {
                        self.pendingSnapshot = refreshedSnapshot
                        self.restoreProposal(
                            suggestion,
                            for: refreshedSnapshot
                        )
                        self.proposalRevalidationTask = nil
                        return
                    }
                }
            }

            guard !Task.isCancelled, let self,
                  self.activeApplicationProcessIdentifier == originalSnapshot.processIdentifier else {
                return
            }
            self.proposalRevalidationTask = nil
            self.dismissProposal()
        }
    }

    private func restoreProposal(
        _ suggestion: WritingSuggestion,
        for snapshot: FocusedTextSnapshot
    ) {
        let geometry = accessibility.sourceSuggestionGeometry(
            for: snapshot,
            suggestion: suggestion
        )
        let presentation: SuggestionPresentationMode = geometry == nil
            ? .fallback
            : .sourceOverlay
        let panelAnchor: CGRect
        if isPanelAnchorPinned, let pinnedAnchor = pendingPanelAnchor {
            // The window can move while the user is away in another application, and no
            // notification arrives for a proposal that is not on screen.
            if let delta = consumeSourceWindowTranslation(for: snapshot) {
                panelAnchor = pinnedAnchor.offsetBy(dx: delta.width, dy: delta.height)
            } else {
                panelAnchor = pinnedAnchor
            }
            pendingPanelAnchor = panelAnchor
        } else {
            panelAnchor = geometry?.anchor ?? snapshot.anchor
            pendingPanelAnchor = panelAnchor
        }
        proposalPanel.updateSuggestionPresentation(
            presentation,
            near: panelAnchor,
            animated: false
        )
        proposalPanel.restoreVisibility()
        if let geometry {
            sourceOverlay.show(
                geometry,
                below: proposalPanel.windowNumber
            )
        } else {
            sourceOverlay.dismiss()
        }
        isProposalSuspended = false

        if accessibility.supportsSourceSuggestionOverlay(suggestion) {
            startSourceOverlayTracking(
                snapshot: snapshot,
                suggestion: suggestion,
                initiallyAvailable: geometry != nil
            )
        }
    }

    private func dismissProposalUI(showingApplied: Bool = false) {
        isProposalVisible = false
        isProposalSuspended = false
        isCustomPromptVisible = false
        isReviewTriggerVisible = false
        isSuggestionPromptTriggerVisible = false
        pendingPanelAnchor = nil
        isPanelAnchorPinned = false
        sourceWindowFrame = nil
        stopSourceOverlay()
        if showingApplied {
            proposalPanel.showApplied()
        } else {
            proposalPanel.dismiss()
        }
    }

    private func suspendProposalUI() {
        guard isProposalVisible, !isProposalSuspended else { return }
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        stopSourceOverlay()
        proposalPanel.suspendVisibility()
        isProposalSuspended = true
    }

    private func resumeProposalUI() {
        guard isProposalVisible, isProposalSuspended else {
            return
        }
        isProposalSuspended = false
        proposalPanel.restoreVisibility()
        if isReviewTriggerVisible || isSuggestionPromptTriggerVisible {
            return
        }
        // Loading, unchanged, and failure states have no pending suggestion but
        // still belong to the source app and should return with it.
        guard pendingSuggestion != nil else { return }
        // Reuse the last stable frame immediately. AX revalidation follows after the
        // activation transition so a slow native accessibility bridge cannot stall it.
        scheduleProposalRevalidation(initialDelayMilliseconds: 50)
    }

    private func acceptProposal() {
        guard !isApplyingProposal else { return }
        guard let snapshot = pendingSnapshot,
              let correctedText = pendingCorrectionText else {
            dismissProposal()
            return
        }

        stopSourceOverlay()
        isApplyingProposal = true
        applicationTask = Task { [weak self] in
            await self?.applyProposal(snapshot, correctedText: correctedText)
        }
    }

    private func handleApplyShortcut(_ event: NSEvent) -> Bool {
        guard pendingSnapshot != nil,
              pendingCorrectionText != nil,
              Self.isApplyShortcut(event) else {
            return false
        }
        if !isApplyingProposal {
            acceptProposal()
        }
        return true
    }

    private func handleReviewShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = settings.popoverShortcut,
              shortcut.matches(event) else {
            return false
        }
        guard reviewShortcutGate.accepts(timestamp: event.timestamp) else {
            return true
        }
        Task { @MainActor [weak self] in
            self?.requestReviewFromShortcut()
        }
        return true
    }

    private func handleTransformShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = settings.transformShortcut,
              shortcut.matches(event) else {
            return false
        }
        guard transformShortcutGate.accepts(timestamp: event.timestamp) else {
            return true
        }
        Task { @MainActor [weak self] in
            self?.requestTransformFromShortcut()
        }
        return true
    }

    private func requestTransformFromShortcut() {
        guard isReady else {
            logger.debug(
                """
                Transform shortcut ignored: listening \(self.isListeningEnabled, privacy: .public), \
                accessibility \(self.isAccessibilityTrusted, privacy: .public), \
                provider configured \(self.settings.isLLMConfigured, privacy: .public)
                """
            )
            updateIdleActivity()
            return
        }
        if let activeApplication, isActiveApplicationExcluded {
            activity = .excluded(activeApplication.name)
            return
        }

        cancelPendingCorrection(dismissProposal: true)
        if let snapshot = accessibility.captureFocusedText(scope: .document) {
            presentCustomPrompt(for: snapshot)
            return
        }
        // An empty field has nothing to transform, but it is the one place where an
        // instruction alone is enough to work from.
        if let snapshot = accessibility.captureFocusedInsertionPoint() {
            presentComposePrompt(for: snapshot)
            return
        }
        activity = .failure(
            "Select up to 1,600 characters or focus a text field containing up to 6,000 characters."
        )
    }

    private func requestReviewFromShortcut() {
        guard isReady else {
            logger.debug(
                """
                Review shortcut ignored: listening \(self.isListeningEnabled, privacy: .public), \
                accessibility \(self.isAccessibilityTrusted, privacy: .public), \
                provider configured \(self.settings.isLLMConfigured, privacy: .public)
                """
            )
            updateIdleActivity()
            return
        }
        if let activeApplication, isActiveApplicationExcluded {
            activity = .excluded(activeApplication.name)
            return
        }

        if isReviewTriggerVisible,
           let pendingSnapshot,
           accessibility.snapshotState(pendingSnapshot) == .unchanged {
            reviewPendingText()
            return
        }

        // A press while a review is still running replaces it instead of queueing
        // behind it, so a slow provider never leaves the shortcut feeling stuck.
        if runningReviewGeneration != nil {
            logger.debug("Review shortcut restarting a review that is still running")
            restartRunningReview()
            return
        }

        cancelPendingCorrection(dismissProposal: true)
        guard let snapshot = captureSnapshotForExplicitReview(),
              snapshot.context.text
                .trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            // An empty field has nothing to review, but it is still somewhere the
            // author wants text. Both shortcuts lead here rather than only the one
            // that happens to be for transforming.
            if let composeSnapshot = accessibility.captureFocusedInsertionPoint() {
                presentComposePrompt(for: composeSnapshot)
                return
            }
            activity = .failure(
                "Select text or place the cursor in a paragraph to review it."
            )
            return
        }
        presentReviewTrigger(for: snapshot)
        reviewPendingText()
    }

    private func captureSnapshotForExplicitReview() -> FocusedTextSnapshot? {
        guard let focusedSnapshot = accessibility.captureFocusedText(scope: .sentence) else {
            return nil
        }
        if focusedSnapshot.selectedRange.length > 0 {
            return focusedSnapshot
        }
        return accessibility.captureFocusedText(scope: .paragraph)
    }

    private static func isApplyShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              flags.isDisjoint(with: [.control, .option, .shift]) else {
            return false
        }

        switch event.specialKey {
        case .carriageReturn, .enter:
            return true
        default:
            return event.charactersIgnoringModifiers == "\r"
                || event.charactersIgnoringModifiers == "\n"
                || event.charactersIgnoringModifiers == "\u{3}"
        }
    }

    private func applyProposal(
        _ snapshot: FocusedTextSnapshot,
        correctedText: String
    ) async {
        defer {
            applicationTask = nil
            isApplyingProposal = false
        }

        do {
            try await accessibility.replace(snapshot, with: correctedText)
            pendingSnapshot = nil
            pendingCorrectionText = nil
            pendingSuggestion = nil
            suggestionHistory.removeAll()
            // The panel is replaced by a receipt rather than simply vanishing, so the
            // edit that just landed is confirmed where the author was already looking.
            dismissProposalUI(showingApplied: true)
            updateIdleActivity()
        } catch is CancellationError {
            // Dismissing the proposal intentionally cancels pending verification.
        } catch {
            pendingSnapshot = nil
            pendingCorrectionText = nil
            pendingSuggestion = nil
            activity = .failure(error.localizedDescription)
            stopSourceOverlay()
            proposalPanel.showFailure(error.localizedDescription)
        }
    }

    private func cancelPendingCorrection(dismissProposal: Bool) {
        correctionGeneration &+= 1
        applicationTask?.cancel()
        applicationTask = nil
        contextPreviewTask?.cancel()
        contextPreviewTask = nil
        isApplyingProposal = false
        correctionTask?.cancel()
        correctionTask = nil
        pendingSnapshot = nil
        pendingCorrectionText = nil
        pendingSuggestion = nil
        pendingAvailableContext = nil
        pendingRequestSentContext = false
        suggestionHistory.removeAll()
        pendingPanelAnchor = nil
        isPanelAnchorPinned = false
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        runningReviewGeneration = nil
        if dismissProposal {
            dismissProposalUI()
        }
    }

    private func isCurrentCorrection(_ generation: Int) -> Bool {
        correctionGeneration == generation && !Task.isCancelled
    }

    private func refreshAccessibilityState() {
        let trusted = accessibility.isTrusted
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
            if !trusted {
                cancelPendingCorrection(dismissProposal: true)
            }
        }
        guard isListeningEnabled else {
            setEventMonitoringEnabled(false)
            activity = .paused
            return
        }
        setEventMonitoringEnabled(trusted)
        if !trusted {
            activity = .permissionRequired
            return
        }
        if !settings.isLLMConfigured {
            activity = .providerRequired
            return
        }
        if activity == .permissionRequired || activity == .providerRequired || activity == .listening {
            updateIdleActivity()
        }
    }

    private func setEventMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            installApplyShortcutEventTapIfNeeded()
            rearmEventDeliveryIfDisabled()
            startAccessibilityChangeObservationIfPossible()
            if keyMonitor == nil {
                keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleGlobalKeyDown(event)
                    }
                }
            }
            if mouseMonitor == nil {
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown]
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleGlobalMouseDown()
                    }
                }
            }
        } else {
            removeApplyShortcutEventTap()
            accessibilityChanges.stop()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            keyMonitor = nil
            mouseMonitor = nil
        }
    }

    private func handleGlobalMouseDown() {
        if isReviewTriggerVisible || isSuggestionPromptTriggerVisible {
            dismissProposal()
            return
        }
        guard !isProposalVisible else { return }
        cancelPendingCorrection(dismissProposal: true)
        updateIdleActivity()
    }

    /// Records the focused application's accessibility tree and offers it for saving.
    ///
    /// Recording is how a heuristic here stops being an argument and becomes a
    /// measurement: replayed offline, a captured tree exercises the real sources and the
    /// real ranking against what an application genuinely publishes.
    func recordAccessibilityFixture(scenario: String) -> String {
        guard isAccessibilityTrusted else {
            return "Accessibility access is required to record a tree."
        }
        guard let result = accessibility.recordFocusedTree(scenario: scenario) else {
            return "Nothing writable was focused when the recording was taken."
        }
        let stem = result.fixture.application.replacingOccurrences(of: " ", with: "-")
        let suffix = scenario.isEmpty ? "capture" : scenario
        let suggestedName = (stem + "-" + suffix).lowercased() + ".json"

        do {
            guard let url = try AXFixtureCapture.save(
                result.fixture,
                suggestedName: suggestedName
            ) else {
                return "Recording discarded."
            }
            let sources = result.telemetry.contributingSources.joined(separator: ", ")
            let nodes = result.fixture.nodes.count
            let reads = result.telemetry.roundTrips
            return "Saved \(nodes) nodes to \(url.lastPathComponent) — \(reads) reads from [\(sources)]."
        } catch {
            return "Could not write the recording: \(error.localizedDescription)"
        }
    }

    /// Reads the surroundings of the newly focused field, off the request path.
    ///
    /// Nothing is sent anywhere by this: it fills a short-lived local cache so that a
    /// shortcut pressed a moment later does not have to wait for the same reads. An
    /// application the author has excluded is left entirely alone, as everywhere else.
    private func prewarmContextForFocusedField() {
        guard isReady, !isActiveApplicationExcluded, let application = activeApplication else {
            return
        }
        Task { [accessibility] in
            await accessibility.prewarmContext(
                applicationName: application.name,
                bundleIdentifier: application.id
            )
        }
    }

    private func startAccessibilityChangeObservationIfPossible() {
        guard isAccessibilityTrusted,
              let processIdentifier = activeApplicationProcessIdentifier else {
            accessibilityChanges.stop()
            return
        }
        accessibilityChanges.start(processIdentifier: processIdentifier) { [weak self] change in
            self?.handleAccessibilityChange(change)
        }
    }

    private func handleAccessibilityChange(_ change: AccessibilityObservedChange) {
        guard !isApplyingProposal else { return }

        switch change {
        case .valueChanged:
            handleObservedValueChange()
        case .focusedElementChanged:
            // Whatever was learned about the last field described a screen that has now
            // moved on, and the new field's surroundings are worth reading before they
            // are asked for.
            prewarmContextForFocusedField()
            guard !isProposalVisible else {
                handleObservedFocusChange()
                return
            }
            cancelPendingCorrection(dismissProposal: true)
            updateIdleActivity()
        case .elementDestroyed:
            if isReviewTriggerVisible || isSuggestionPromptTriggerVisible {
                dismissProposal()
                return
            }
            if isProposalVisible {
                stopSourceOverlay()
                scheduleProposalRevalidation()
                return
            }
            cancelPendingCorrection(dismissProposal: true)
            updateIdleActivity()
        case .selectionChanged:
            handleObservedSelectionChange()
        case .windowGeometryChanged:
            followSourceWindowMovement()
        }
    }

    /// A proposal belongs to the field it was captured from.
    ///
    /// Moving the caret inside that field keeps it, because the suggestion still applies
    /// there. Focus landing on another place the user can write in retires it: that is a
    /// click outside in the only sense that matters to an anchored proposal.
    private func handleObservedFocusChange() {
        guard let pendingSnapshot else { return }
        // The prompt takes key focus, and some applications report their own focus
        // moving in response. Nothing about the reviewed field changed.
        guard !isCustomPromptVisible else { return }
        guard activeApplicationProcessIdentifier == pendingSnapshot.processIdentifier else {
            return
        }

        switch accessibility.focusState(for: pendingSnapshot) {
        case .matchesSnapshot:
            return
        case .unavailable:
            // The element may have been recreated with the same content. Revalidation
            // restores the proposal when it can and retires it when it cannot.
            scheduleProposalRevalidation()
        case .otherEditableElement:
            dismissProposal()
        }
    }

    private func handleObservedSelectionChange() {
        if isProposalVisible, let pendingSnapshot {
            guard activeApplicationProcessIdentifier == pendingSnapshot.processIdentifier else {
                return
            }
            switch accessibility.snapshotState(pendingSnapshot) {
            case .unchanged:
                return
            case .unavailable:
                scheduleProposalRevalidation()
                return
            case .changed:
                break
            }
        }
        cancelPendingCorrection(dismissProposal: true)
        updateIdleActivity()
    }

    private func handleObservedValueChange() {
        // Chromium may deliver a delayed or duplicate value-change notification after
        // a request completes. Ignore notifications that do not invalidate the snapshot
        // currently being reviewed; a real edit dismisses it below.
        if isProposalVisible, let pendingSnapshot {
            guard activeApplicationProcessIdentifier == pendingSnapshot.processIdentifier else {
                return
            }
            switch accessibility.snapshotState(pendingSnapshot) {
            case .unchanged:
                return
            case .unavailable:
                scheduleProposalRevalidation()
                return
            case .changed:
                break
            }
        }
        cancelPendingCorrection(dismissProposal: true)
        updateIdleActivity()
    }

    private func installApplyShortcutEventTapIfNeeded() {
        guard applyShortcutEventTap == nil else { return }
        // `start()` runs from the app's initialiser, before AppKit has finished
        // launching. A tap built against a session connection that is not there yet can
        // come back alive and permanently deaf, which no health check can then repair.
        // The accessibility poll retries a moment later, once there is a session.
        guard NSApplication.shared.isRunning else { return }

        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<CrossAppCorrectionController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()

                return MainActor.assumeIsolated {
                    if type == .keyDown {
                        controller.lastTapKeyDownUptime = ProcessInfo.processInfo.systemUptime
                    }
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let eventTap = controller.applyShortcutEventTap {
                            CGEvent.tapEnable(tap: eventTap, enable: true)
                        }
                        return Unmanaged.passUnretained(event)
                    }
                    guard type == .keyDown,
                          let keyEvent = NSEvent(cgEvent: event),
                          controller.handleMonitoredShortcut(keyEvent) else {
                        return Unmanaged.passUnretained(event)
                    }
                    return nil
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // The passive global monitor still provides the shortcut as a fallback.
            logger.error("Could not create the shortcut event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        applyShortcutEventTap = eventTap
        applyShortcutEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        // A tap that has never seen anything must not immediately look deaf.
        lastTapKeyDownUptime = ProcessInfo.processInfo.systemUptime
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// Puts shortcut delivery back when the system has quietly switched it off.
    ///
    /// macOS disables an event tap whose process was too slow to answer it, which a
    /// menu bar app can be after App Nap throttles it or a stalled accessibility call
    /// holds the main thread. The tap reports that to its own callback, but the passive
    /// monitor behind `addGlobalMonitorForEvents` dies in the same moment and AppKit
    /// never revives it or tells anyone. Both stayed dead until the app was restarted,
    /// so this runs with the accessibility poll and re-arms whatever went quiet.
    private func rearmEventDeliveryIfDisabled() {
        guard let eventTap = applyShortcutEventTap else { return }
        guard !CGEvent.tapIsEnabled(tap: eventTap) else {
            rebuildEventDeliveryIfDeaf()
            return
        }
        logger.notice("Shortcut delivery was switched off by the system; re-arming it")
        CGEvent.tapEnable(tap: eventTap, enable: true)
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            // Re-enabling a tap the system has given up on does not always take, so
            // build a new one rather than leaving a dead port in place.
            rebuildEventDelivery(reason: "re-enabling the tap did not take")
            return
        }
        recycleGlobalMonitors()
    }

    /// Rebuilds delivery that calls itself healthy but has stopped seeing keys.
    ///
    /// `tapIsEnabled` answers whether the system still has the tap switched on, not
    /// whether anything reaches it, and that gap is the failure every check here used
    /// to walk straight past: an enabled tap that never fires again, which re-enabling
    /// cannot repair because it was never off. The system does record when a key was
    /// last pressed anywhere in the session, so a press the tap did not see is the
    /// evidence, and a new tap is the only answer.
    private func rebuildEventDeliveryIfDeaf() {
        guard applyShortcutEventTap != nil else { return }
        // A password field takes the keyboard away from every tap in the session by
        // design. Nothing is broken there and a rebuild would not change it.
        guard !IsSecureEventInputEnabled() else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEventDeliveryRebuildUptime > Self.eventDeliveryRebuildInterval else {
            return
        }
        let sinceSystemKeyDown = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .keyDown
        )
        // Nobody has typed recently, so the tap's silence says nothing either way.
        guard sinceSystemKeyDown.isFinite,
              sinceSystemKeyDown < Self.deafTapObservationWindow else {
            return
        }
        let sinceTapKeyDown = now - lastTapKeyDownUptime
        guard sinceTapKeyDown > sinceSystemKeyDown + Self.deafTapTolerance else { return }

        rebuildEventDelivery(
            reason: """
                a key was pressed \(String(format: "%.1f", sinceSystemKeyDown))s ago and \
                the tap has seen nothing for \(String(format: "%.1f", sinceTapKeyDown))s
                """
        )
    }

    private func rebuildEventDelivery(reason: String) {
        logger.notice("Rebuilding shortcut delivery: \(reason, privacy: .public)")
        lastEventDeliveryRebuildUptime = ProcessInfo.processInfo.systemUptime
        removeApplyShortcutEventTap()
        installApplyShortcutEventTapIfNeeded()
        recycleGlobalMonitors()
    }

    /// Sleep, display wake and fast user switching all hand the session's event taps
    /// back in a state the system neither reports as broken nor repairs. Delivery is
    /// rebuilt on the way back rather than after a press has already been lost.
    private func startObservingSystemWake() {
        guard systemWakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        systemWakeObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemWake()
                }
            }
        }
    }

    private func stopObservingSystemWake() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in systemWakeObservers {
            center.removeObserver(observer)
        }
        systemWakeObservers.removeAll()
    }

    private func handleSystemWake() {
        guard isListeningEnabled, isAccessibilityTrusted else { return }
        rebuildEventDelivery(reason: "the machine woke or its login session came back")
        // The monitors were dropped with the tap; this puts them back.
        refreshAccessibilityState()
    }

    /// There is no way to ask whether a global monitor is still alive, so a disabled
    /// tap is taken as the answer for both and the monitors are simply rebuilt.
    private func recycleGlobalMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
    }

    private func handleMonitoredShortcut(_ event: NSEvent) -> Bool {
        handleApplyShortcut(event)
            || handleTransformShortcut(event)
            || handleReviewShortcut(event)
    }

    private func removeApplyShortcutEventTap() {
        if let source = applyShortcutEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap = applyShortcutEventTap {
            CFMachPortInvalidate(eventTap)
        }
        applyShortcutEventTapSource = nil
        applyShortcutEventTap = nil
    }

    private func updateIdleActivity() {
        if !isListeningEnabled {
            activity = .paused
        } else if !isAccessibilityTrusted {
            activity = .permissionRequired
        } else if !settings.isLLMConfigured {
            activity = .providerRequired
        } else if let activeApplication, isActiveApplicationExcluded {
            activity = .excluded(activeApplication.name)
        } else {
            activity = .listening
        }
    }

    private func startTrackingActiveApplication() {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            recordActiveApplication(frontmostApplication)
        }

        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                self?.recordActiveApplication(application)
            }
        }
    }

    private func stopTrackingActiveApplication() {
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
        }
        applicationActivationObserver = nil
    }

    private func recordActiveApplication(_ application: NSRunningApplication) {
        activeApplicationActivationScreenFrame = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        }?.frame
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if shouldSuspendVisibleProposal() {
                suspendProposalUI()
            }
            return
        }
        guard let identifier = application.bundleIdentifier, !identifier.isEmpty else {
            activeApplication = nil
            activeApplicationProcessIdentifier = nil
            accessibilityChanges.stop()
            if isProposalVisible {
                if shouldSuspendVisibleProposal() {
                    suspendProposalUI()
                }
            } else {
                cancelPendingCorrection(dismissProposal: true)
            }
            updateIdleActivity()
            return
        }

        let identity = ActiveApplication(
            id: identifier,
            name: application.localizedName ?? "Current app",
            icon: application.icon
        )
        let processChanged = activeApplicationProcessIdentifier != application.processIdentifier
        guard identity != activeApplication || processChanged else {
            if pendingSnapshot?.processIdentifier == application.processIdentifier {
                resumeProposalUI()
            }
            return
        }
        let previousProcessIdentifier = activeApplicationProcessIdentifier
        activeApplication = identity
        activeApplicationProcessIdentifier = application.processIdentifier
        if let previousProcessIdentifier {
            Task { [accessibility] in
                await accessibility.invalidateContext(
                    processIdentifier: previousProcessIdentifier
                )
            }
        }
        startAccessibilityChangeObservationIfPossible()
        if isProposalVisible,
           pendingSnapshot?.processIdentifier == application.processIdentifier {
            resumeProposalUI()
        } else if isProposalVisible, shouldSuspendVisibleProposal() {
            suspendProposalUI()
        } else if !isProposalVisible {
            cancelPendingCorrection(dismissProposal: true)
        }
        updateIdleActivity()
    }

    private func shouldSuspendVisibleProposal() -> Bool {
        guard let proposalScreenFrame = proposalPanel.screenFrame,
              let activationScreenFrame = activeApplicationActivationScreenFrame else {
            return true
        }
        return proposalScreenFrame == activationScreenFrame
    }

    private func shouldSuspendProposal(
        forSourceProcessIdentifier sourceProcessIdentifier: pid_t,
        sourceAnchor: CGRect
    ) -> Bool {
        guard activeApplicationProcessIdentifier != sourceProcessIdentifier else {
            return false
        }
        guard let sourceScreenFrame = NSScreen.screens.first(where: {
            $0.frame.intersects(sourceAnchor)
        })?.frame,
        let activationScreenFrame = activeApplicationActivationScreenFrame else {
            return true
        }
        return sourceScreenFrame == activationScreenFrame
    }

    private static func isEscapeKey(_ event: NSEvent) -> Bool {
        event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1B}"
    }

    private func setApplication(identifier: String, name: String, isExcluded: Bool) {
        var storedApplications = Dictionary(
            uniqueKeysWithValues: excludedApplications.map { ($0.id, $0.name) }
        )
        if isExcluded {
            storedApplications[identifier] = name
            excludedApplicationIdentifiers.insert(identifier)
            cancelPendingCorrection(dismissProposal: true)
        } else {
            storedApplications.removeValue(forKey: identifier)
            excludedApplicationIdentifiers.remove(identifier)
        }

        excludedApplications = Self.sortedApplications(from: storedApplications)
        defaults.set(storedApplications, forKey: "excludedApplications")
        updateIdleActivity()
    }

    private static func sortedApplications(
        from storedApplications: [String: String]
    ) -> [ExcludedApplication] {
        storedApplications
            .map { ExcludedApplication(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
