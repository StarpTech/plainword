import AppKit
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
    private var applicationActivationObserver: NSObjectProtocol?
    private var activeApplicationProcessIdentifier: pid_t?
    private var activeApplicationActivationScreenFrame: CGRect?
    private var keyMonitor: Any?
    private var applyShortcutEventTap: CFMachPort?
    private var applyShortcutEventTapSource: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var permissionTask: Task<Void, Never>?
    private var correctionTask: Task<Void, Never>?
    private var sourceOverlayTrackingTask: Task<Void, Never>?
    private var proposalRevalidationTask: Task<Void, Never>?
    private var correctionGeneration = 0
    private var applicationTask: Task<Void, Never>?
    private var started = false
    private var isApplyingProposal = false
    private var isProposalVisible = false
    private var isProposalSuspended = false
    private var isCustomPromptVisible = false
    private var isReviewTriggerVisible = false
    private var isSuggestionPromptTriggerVisible = false
    private var pendingSnapshot: FocusedTextSnapshot?
    private var pendingCorrectionText: String?
    private var pendingSuggestion: WritingSuggestion?
    private var suggestionHistory: [WritingSuggestion] = []
    private var preparedManualSnapshot: FocusedTextSnapshot?
    private var preparedManualSnapshotDate: Date?
    private var pendingPanelAnchor: CGRect?
    private var isPanelAnchorPinned = false
    private var suggestionCache = CorrectionSuggestionCache()
    private var reviewShortcutGate = ShortcutInvocationGate(minimumInterval: 0.35)
    private var transformShortcutGate = ShortcutInvocationGate(minimumInterval: 0.35)
    private var shortcutReviewGeneration: Int?

    init(settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        let storedApplications = defaults.dictionary(forKey: "excludedApplications") as? [String: String]
            ?? [:]
        excludedApplications = Self.sortedApplications(from: storedApplications)
        excludedApplicationIdentifiers = Set(storedApplications.keys)
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
        startTrackingActiveApplication()
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
        guard isReady,
              !isActiveApplicationExcluded,
              let snapshot = accessibility.captureFocusedText(scope: .document) else {
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
        shortcutReviewGeneration = nil
        pendingSnapshot = nil
        pendingCorrectionText = nil
        pendingSuggestion = nil
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
        shortcutReviewGeneration = nil
        permissionTask?.cancel()
        proposalRevalidationTask?.cancel()
        setEventMonitoringEnabled(false)
        accessibilityChanges.stop()
        stopTrackingActiveApplication()
        dismissProposalUI()
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

        let snapshot = await accessibility.enriched(capturedSnapshot)
        guard isCurrentCorrection(generation) else { return }

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
            for try await response in stream {
                try Task.checkCancellation()
                correctionResponse = response
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
                proposalPanel.showFailure(error.localizedDescription)
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
            title: snapshot.context.targetKind == .document
                ? "Transform entire field"
                : "Transform selection",
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

    private func reviewPendingText(startedFromShortcut: Bool = false) {
        guard let snapshot = pendingSnapshot,
              accessibility.snapshotState(snapshot) == .unchanged else {
            dismissProposal()
            return
        }

        correctionGeneration &+= 1
        let generation = correctionGeneration
        if startedFromShortcut {
            shortcutReviewGeneration = generation
        }
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
            // Keep the review idempotent until the final panel resize animation has
            // left AppKit's display cycle as well as until the provider work is done.
            try? await Task.sleep(for: .milliseconds(250))
            if self.shortcutReviewGeneration == generation {
                self.shortcutReviewGeneration = nil
            }
        }
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
            activity = .failure("The selected text changed before it could be transformed.")
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
        let editContext = await accessibility.enriched(capturedEditContext, for: snapshot)
        guard isCurrentCorrection(generation) else { return }
        let locale = promptLanguageIdentifier(for: editContext)

        do {
            var correctionResponse: CorrectionResponse?
            let stream = try settings.streamCorrection(
                editContext,
                intent: .correct,
                locale: locale,
                instruction: instruction
            )
            for try await response in stream {
                try Task.checkCancellation()
                correctionResponse = response
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
                activity = .failure("The selected text changed before it could be transformed.")
                return
            }

            guard correctionResponse.correctedText != editContext.text else {
                dismissProposal()
                activity = .failure("That instruction did not change the selected text.")
                return
            }

            guard let suggestion = WritingSuggestionPlanner.make(
                originalText: snapshot.context.text,
                replacementText: correctionResponse.correctedText,
                completionIsAllowed: false,
                classifiedAs: correctionResponse.classification,
                allowsNewConcreteDetails: true,
                allowsLanguageChange: true
            ) else {
                dismissProposal()
                activity = .failure("That instruction did not change the selected text.")
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
            proposalPanel.showFailure(error.localizedDescription)
        }
    }

    private func promptLanguageIdentifier(for context: TextEditContext) -> String {
        switch settings.spellingLanguageMode {
        case .fixed:
            return settings.fixedSpellingLanguageIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? "unspecified"
        case .automatic:
            return TextLanguageDetector.dominantLanguageIdentifier(in: context) ?? "unspecified"
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
            panelAnchor = pinnedAnchor
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

    private func dismissProposalUI() {
        isProposalVisible = false
        isProposalSuspended = false
        isCustomPromptVisible = false
        isReviewTriggerVisible = false
        isSuggestionPromptTriggerVisible = false
        pendingPanelAnchor = nil
        isPanelAnchorPinned = false
        stopSourceOverlay()
        proposalPanel.dismiss()
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
            updateIdleActivity()
            return
        }
        if let activeApplication, isActiveApplicationExcluded {
            activity = .excluded(activeApplication.name)
            return
        }

        cancelPendingCorrection(dismissProposal: true)
        guard let snapshot = accessibility.captureFocusedText(scope: .document) else {
            activity = .failure(
                "Select up to 1,600 characters or focus a text field containing up to 6,000 characters."
            )
            return
        }
        presentCustomPrompt(for: snapshot)
    }

    private func requestReviewFromShortcut() {
        // A second press used to cancel and immediately rebuild the visible SwiftUI
        // panel while AppKit was still laying it out. Treat review as idempotent until
        // the current request completes; ordinary typing and dismissal still cancel it.
        guard shortcutReviewGeneration == nil else { return }
        guard isReady else {
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

        cancelPendingCorrection(dismissProposal: true)
        guard let snapshot = captureSnapshotForExplicitReview(),
              snapshot.context.text
                .trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            activity = .failure(
                "Select text or place the cursor in a paragraph to review it."
            )
            return
        }
        presentReviewTrigger(for: snapshot)
        reviewPendingText(startedFromShortcut: true)
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
            dismissProposalUI()
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
        isApplyingProposal = false
        correctionTask?.cancel()
        correctionTask = nil
        pendingSnapshot = nil
        pendingCorrectionText = nil
        pendingSuggestion = nil
        suggestionHistory.removeAll()
        pendingPanelAnchor = nil
        isPanelAnchorPinned = false
        proposalRevalidationTask?.cancel()
        proposalRevalidationTask = nil
        shortcutReviewGeneration = nil
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
            guard !isProposalVisible else { return }
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
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        applyShortcutEventTap = eventTap
        applyShortcutEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
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
        activeApplication = identity
        activeApplicationProcessIdentifier = application.processIdentifier
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
