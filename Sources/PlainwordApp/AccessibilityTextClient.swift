import AppKit
import ApplicationServices
import CoreGraphics
import OSLog
import PlainwordCore

struct FocusedTextSnapshot {
    let element: AXUIElement
    let processIdentifier: pid_t
    let applicationIdentifier: String?
    let applicationName: String
    /// A complete field value for ordinary controls, or a bounded range window for a
    /// large/range-only editor.
    let fullText: String
    let capturedTextRange: NSRange
    let documentUTF16Length: Int
    let selectedRange: CFRange
    let context: TextEditContext
    let anchor: CGRect

    var fingerprint: String {
        "\(processIdentifier):\(capturedTextRange.location):\(documentUTF16Length):\(fullText.hashValue):\(selectedRange.location):\(selectedRange.length)"
    }

    /// Returns the same captured editor state carrying a revised request context.
    func withContext(_ context: TextEditContext) -> FocusedTextSnapshot {
        FocusedTextSnapshot(
            element: element,
            processIdentifier: processIdentifier,
            applicationIdentifier: applicationIdentifier,
            applicationName: applicationName,
            fullText: fullText,
            capturedTextRange: capturedTextRange,
            documentUTF16Length: documentUTF16Length,
            selectedRange: selectedRange,
            context: context,
            anchor: anchor
        )
    }
}

/// A writable field seen while a fixture recording was armed.
///
/// A recording used to fire on a countdown, against whatever happened to be focused when
/// it expired. Arming remembers the field instead, while the author is still in the
/// application they are writing in — because by the time they come back to Plainword to
/// stop the recording, focus is in the settings window, and a countdown that fired then
/// would faithfully record that.
struct FixtureRecordingTarget {
    let element: AXUIElement
    let processIdentifier: pid_t
    let applicationName: String
    let bundleIdentifier: String?
    let role: String

    /// What the author is told is about to be recorded.
    var summary: String {
        applicationName + " — " + role
    }
}

enum AccessibilitySnapshotState: Equatable {
    case unchanged
    case changed
    case unavailable
}

/// Where the source application's keyboard focus sits relative to a captured snapshot.
enum AccessibilityFocusState: Equatable {
    /// Focus is still in the field the snapshot was captured from.
    case matchesSnapshot
    /// Focus moved to a different place the user can write in.
    case otherEditableElement
    /// Focus is somewhere that is not a writing site, or cannot be read at all.
    case unavailable
}

enum AccessibilityTextError: LocalizedError {
    case permissionRequired
    case fieldChanged
    case fieldIsNotWritable
    case replacementFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Accessibility access is required to work in other applications."
        case .fieldChanged:
            "The text changed before the suggestion could be applied."
        case .fieldIsNotWritable:
            "This application does not expose a writable text field."
        case .replacementFailed:
            "The application did not accept the replacement."
        }
    }
}

@MainActor
final class AccessibilityTextClient {
    private enum HorizontalEndpointEdge {
        case leading
        case trailing
    }

    private let maximumAutomaticContextLength = 800
    private let maximumSelectionLength = 1_600
    private let maximumManualReviewLength = 6_000
    private let maximumCompleteTextReadLength = 12_000
    private let maximumRangeWindowLength = 2_400
    /// Ceiling on how long a prompt may be before an equal value stops reading as an
    /// echo of it. Prompts are a few words; an application that answers its accessible
    /// name with the field's own contents should not make a long value look empty.
    private let maximumPlaceholderPromptLength = 120
    /// How many of an editor's own children are examined for the class that marks an
    /// empty document. The mark sits on the first block; the rest are not worth the cost.
    private let maximumEmptyEditorChildScan = 3
    /// How much longer than its prompt a value may be and still read as an echo of it:
    /// the newline Chromium reports for an empty paragraph, plus the spelled-out
    /// ellipsis a drawn prompt carries where the accessible name leaves it off.
    private let placeholderEchoSlack = 5
    private let domClassListAttribute = "AXDOMClassList"
    /// How far back a caret's own line is followed when a host cannot report where that
    /// line begins. Long enough to be unique inside a paragraph, and read only for a
    /// caret that already looks misplaced.
    private let maximumCaretMarkerSteps = 48
    /// Classes a rich-text editor puts on an empty document while it draws its prompt.
    /// Each one is that editor's own statement that the field holds nothing.
    private let emptyEditorClassNames: Set<String> = [
        // ProseMirror and Tiptap. Their per-node marker, "is-empty", also lands on a
        // blank paragraph inside a document that has text elsewhere, so it is not here.
        "is-editor-empty",
        // Quill, on the editor root.
        "ql-blank",
        // CKEditor, on the element drawing the prompt.
        "ck-placeholder"
    ]
    private let standardTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String
    ]

    private struct CapturedTextState {
        let text: String
        let range: NSRange
        let documentUTF16Length: Int
        let selectedRange: CFRange
        /// Where the caret sits in the captured text, once the source's own answer has
        /// been reconciled with the text it handed over. The same number as
        /// `selectedRange.location` in every host that reports the two consistently,
        /// which is every host that is not drawing web content.
        let caretLocation: Int

        init(
            text: String,
            range: NSRange,
            documentUTF16Length: Int,
            selectedRange: CFRange,
            caretLocation: Int? = nil
        ) {
            self.text = text
            self.range = range
            self.documentUTF16Length = documentUTF16Length
            self.selectedRange = selectedRange
            self.caretLocation = caretLocation ?? selectedRange.location
        }

        func withCaret(_ caretLocation: Int) -> CapturedTextState {
            CapturedTextState(
                text: text,
                range: range,
                documentUTF16Length: documentUTF16Length,
                selectedRange: selectedRange,
                caretLocation: caretLocation
            )
        }
    }

    private let contextService = ContextService()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.example.Plainword",
        category: "AccessibilityTextClient"
    )

    init() {
        AccessibilityElementReader.applyGlobalMessagingTimeout()
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccess() -> Bool {
        // The SDK exposes kAXTrustedCheckOptionPrompt as mutable global state, which is
        // unavailable under Swift 6 strict concurrency. This is its documented CFString key.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Resolves the focused writable text element, or nothing when the focus is not
    /// somewhere Plainword may write.
    private func focusedEditableElement() -> (element: AXUIElement, processIdentifier: pid_t)? {
        guard isTrusted else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        guard var element = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ) else {
            return nil
        }

        if !isSupportedTextElement(element),
           let editableAncestor = elementAttribute(kAXEditableAncestorAttribute, from: element) {
            element = editableAncestor
        }

        guard isSupportedTextElement(element),
              !isProtected(element),
              !isInsideToolbar(element) else {
            return nil
        }

        _ = AXUIElementSetMessagingTimeout(element, 0.75)

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier,
              isWritableTextElement(element),
              !hasMultipleSelections(element) else {
            return nil
        }
        return (element, processIdentifier)
    }

    func captureFocusedText(
        scope: TextEditExtractionScope = .sentence
    ) -> FocusedTextSnapshot? {
        guard let focused = focusedEditableElement() else { return nil }
        let element = focused.element
        let processIdentifier = focused.processIdentifier
        guard let textState = captureTextState(from: element, scope: scope) else {
            return nil
        }
        let selectedRange = textState.selectedRange
        let fullText = textState.text
        let localSelectedRange = NSRange(
            location: textState.caretLocation - textState.range.location,
            length: selectedRange.length
        )
        guard localSelectedRange.location >= 0,
              localSelectedRange.location + localSelectedRange.length <= (fullText as NSString).length,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location + selectedRange.length <= textState.documentUTF16Length,
              let localFieldContext = TextEditContextExtractor.extract(
                from: fullText,
                selectedRange: localSelectedRange,
                scope: scope,
                maximumUTF16Length: maximumTargetLength(
                    selectedRange: selectedRange,
                    scope: scope
                ),
                surrounding: scope == .sentence || selectedRange.length > 0
                    ? .modest
                    : .identityOnly
              ),
              let fieldContext = localFieldContext.translated(
                byUTF16Offset: textState.range.location
              ) else {
            return nil
        }

        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        let applicationName = runningApplication?.localizedName ?? "Another app"
        // Only the source application is attached here. Harvesting the surrounding
        // interface costs hundreds of Accessibility round trips, so it is deferred to
        // `enriched(_:)` and runs off this actor while the UI stays responsive.
        let context = fieldContext.withApplicationContext(
            [.init(kind: .sourceApplication, text: applicationName)]
        )

        return FocusedTextSnapshot(
            element: element,
            processIdentifier: processIdentifier,
            applicationIdentifier: runningApplication?.bundleIdentifier,
            applicationName: applicationName,
            fullText: fullText,
            capturedTextRange: textState.range,
            documentUTF16Length: textState.documentUTF16Length,
            selectedRange: selectedRange,
            context: context,
            anchor: anchorRect(
                for: NSRange(
                    location: textState.caretLocation,
                    length: selectedRange.length
                ),
                textLength: textState.documentUTF16Length,
                in: element
            )
        )
    }

    /// Captures the caret of a focused field that holds no text.
    ///
    /// `captureFocusedText` has nothing to return here, because every editing request
    /// needs text to work from. An empty field is not a failure though: it is a place
    /// to write, so it gets a snapshot whose target is the caret itself.
    func captureFocusedInsertionPoint() -> FocusedTextSnapshot? {
        guard let focused = focusedEditableElement() else {
            logger.debug("Writing: no writable text element is focused")
            return nil
        }
        let element = focused.element
        let processIdentifier = focused.processIdentifier
        guard let textState = captureTextState(from: element, scope: .document) else {
            logger.debug("Writing: the focused field did not report a readable state")
            return nil
        }
        // The document scope reads from the start of the field, so the caret offset and
        // the captured text share one coordinate space. `insertionPoint` then decides
        // whether the caret's own paragraph is blank; the field itself need not be.
        guard textState.range.location == 0,
              textState.selectedRange.length == 0,
              let context = TextEditContextExtractor.insertionPoint(
                in: textState.text,
                at: textState.caretLocation
              ) else {
            logger.debug(
                """
                Writing: the caret is not on a blank line \
                (\(textState.documentUTF16Length, privacy: .public) characters, \
                selection at \(textState.selectedRange.location, privacy: .public) \
                length \(textState.selectedRange.length, privacy: .public))
                """
            )
            return nil
        }

        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        let applicationName = runningApplication?.localizedName ?? "Another app"

        return FocusedTextSnapshot(
            element: element,
            processIdentifier: processIdentifier,
            applicationIdentifier: runningApplication?.bundleIdentifier,
            applicationName: applicationName,
            fullText: textState.text,
            capturedTextRange: textState.range,
            documentUTF16Length: textState.documentUTF16Length,
            selectedRange: textState.selectedRange,
            // The surrounding interface is what a draft has to go on, so the harvest in
            // `enriched(_:)` matters more here than anywhere else.
            context: context.withApplicationContext(
                [.init(kind: .sourceApplication, text: applicationName)]
            ),
            anchor: anchorRect(
                for: NSRange(
                    location: textState.caretLocation,
                    length: textState.selectedRange.length
                ),
                textLength: textState.documentUTF16Length,
                in: element
            )
        )
    }

    /// Returns the snapshot with read-only context from the surrounding interface
    /// attached, harvesting it off this actor.
    ///
    /// The harvest observes the interface a moment after the field itself was captured,
    /// so it can reflect a slightly newer state of the screen. That is acceptable for
    /// context that is only ever read: the editable target and its offsets come from the
    /// snapshot, and `snapshotState(_:)` still has to confirm them before anything is
    /// applied.
    func enriched(_ snapshot: FocusedTextSnapshot) async -> FocusedTextSnapshot {
        guard isTrusted else { return snapshot }

        let assembly = await contextService.assembly(for: contextRequest(for: snapshot))
        guard !assembly.fragments.isEmpty else { return snapshot }

        return snapshot.withContext(
            snapshot.context.withApplicationContext(
                snapshot.context.applicationContextFragments + assembly.fragments
            )
        )
    }

    /// Reads the surroundings of whatever is focused now, before anything has been asked
    /// of them.
    ///
    /// Called when focus lands rather than when the author invokes a shortcut, which is
    /// the whole reason the harvest can afford to look further than it used to: the
    /// budget stops being the pause the author would otherwise sit through.
    func prewarmContext(
        applicationName: String,
        bundleIdentifier: String?
    ) async {
        guard isTrusted, let focused = focusedEditableElement() else { return }
        let request = ContextService.Request(
            element: AXElementBox(focused.element),
            processIdentifier: focused.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            // Harvested for the most demanding case on purpose. A draft needs the most
            // prose before it is satisfied, so a prefetch taken for one also answers the
            // correction or rewrite that actually turns up — where reading for the
            // lesser case would leave the greater one to start again.
            targetKind: .insertionPoint,
            // What the field already holds, so the harvest can stop where the author's
            // own writing begins. A prefetch that believed the field were empty would
            // read straight through it and hand the writing back as if the interface
            // had said it — and would go on doing so after the text had been replaced.
            // One attribute read against the several hundred about to be spent.
            capturedText: stringAttribute(kAXValueAttribute as String, from: focused.element)
                ?? "",
            targetRange: NSRange(location: 0, length: 0),
            primaryScreenMaxY: primaryScreenMaxY
        )
        await contextService.prewarm(request)
    }

    /// Forgets what was learned about an application's screen, because it has moved on.
    func invalidateContext(processIdentifier: pid_t? = nil) async {
        await contextService.invalidate(processIdentifier: processIdentifier)
    }

    /// What is focused, in the words the Accessibility API used, whether or not it is
    /// somewhere Plainword can work.
    ///
    /// Only for explaining a refusal. "Nothing writable was focused" is true of a great
    /// many different situations — a canvas, a read-only field, a password box, an
    /// application that publishes no tree at all — and while recording a corpus the
    /// difference between them is the whole finding.
    func focusedElementDescription() -> String {
        guard isTrusted else { return "Accessibility access is off." }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let element = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ) else {
            return "no focused element at all"
        }

        var processIdentifier: pid_t = 0
        _ = AXUIElementGetPid(element, &processIdentifier)
        let application = NSRunningApplication(processIdentifier: processIdentifier)
        let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? "no role"
        let subrole = stringAttribute(kAXSubroleAttribute as String, from: element)
        let editable = elementAttribute(kAXEditableAncestorAttribute, from: element) != nil

        var reasons: [String] = []
        if !isSupportedTextElement(element) { reasons.append("not a text role") }
        if isProtected(element) { reasons.append("protected") }
        if isInsideToolbar(element) { reasons.append("in a toolbar") }
        if !isWritableTextElement(element) { reasons.append("value not settable") }
        if hasMultipleSelections(element) { reasons.append("multiple selections") }

        return "\(application?.localizedName ?? "unknown app") published "
            + "\(role)\(subrole.map { "/\($0)" } ?? "")"
            + (editable ? " with an editable ancestor" : " with no editable ancestor")
            + (reasons.isEmpty ? "" : " — \(reasons.joined(separator: ", "))")
    }

    /// The writable field focus is in right now, remembered for a recording that will be
    /// taken later.
    func focusedRecordingTarget() -> FixtureRecordingTarget? {
        guard let focused = focusedEditableElement() else { return nil }
        let application = NSRunningApplication(processIdentifier: focused.processIdentifier)
        return FixtureRecordingTarget(
            element: focused.element,
            processIdentifier: focused.processIdentifier,
            applicationName: application?.localizedName ?? "Another app",
            bundleIdentifier: application?.bundleIdentifier,
            role: stringAttribute(kAXRoleAttribute, from: focused.element) ?? "unknown role"
        )
    }

    /// Records the tree behind a remembered field, for replaying offline.
    ///
    /// The pipeline is run for real against the live application while a recorder watches
    /// it, so the fixture answers exactly the questions the sources ask — including the
    /// marker reads, whose parameters could not be enumerated any other way.
    func recordTree(
        for target: FixtureRecordingTarget,
        scenario: String
    ) -> AXFixtureCapture.Result? {
        guard isTrusted else { return nil }
        // Read from the remembered element rather than from focus, which by now is in
        // Plainword's own window.
        let capturedText = captureTextState(from: target.element, scope: .document)?.text
            ?? stringAttribute(kAXValueAttribute, from: target.element)
            ?? ""
        return AXFixtureCapture.recordTree(
            element: target.element,
            applicationName: target.applicationName,
            bundleIdentifier: target.bundleIdentifier,
            // Recorded as the prefetch would ask, not as this moment happens to be. A
            // draft at an empty caret is the most demanding request the pipeline serves,
            // so a recording taken for it measures the case that fails first — and one
            // taken for anything lesser would call a thin harvest sufficient.
            targetKind: .insertionPoint,
            capturedText: capturedText,
            scenario: scenario,
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    private func contextRequest(
        for snapshot: FocusedTextSnapshot
    ) -> ContextService.Request {
        ContextService.Request(
            element: AXElementBox(snapshot.element),
            processIdentifier: snapshot.processIdentifier,
            bundleIdentifier: snapshot.applicationIdentifier,
            applicationName: snapshot.applicationName,
            targetKind: snapshot.context.targetKind,
            capturedText: snapshot.fullText,
            targetRange: NSRange(
                location: snapshot.context.utf16Location - snapshot.capturedTextRange.location,
                length: snapshot.context.utf16Length
            ),
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    /// Returns a request context — which may target revised text rather than the
    /// snapshot's own — with the same harvested application context attached.
    func enriched(
        _ context: TextEditContext,
        for snapshot: FocusedTextSnapshot
    ) async -> TextEditContext {
        let enrichedSnapshot = await enriched(snapshot)
        guard enrichedSnapshot.context.applicationContextFragments
                != context.applicationContextFragments else {
            return context
        }
        return context.withApplicationContext(
            enrichedSnapshot.context.applicationContextFragments
        )
    }

    private func captureTextState(
        from element: AXUIElement,
        scope: TextEditExtractionScope
    ) -> CapturedTextState? {
        guard let selectedRange = selectedRange(of: element),
              selectedRange.location >= 0, selectedRange.length >= 0 else {
            return nil
        }

        // A field drawing its placeholder holds nothing, whatever its own reported
        // value and offsets claim, so it is captured as the empty document it is.
        if isShowingPlaceholder(element) {
            return validatedTextState(CapturedTextState(
                text: "",
                range: NSRange(location: 0, length: 0),
                documentUTF16Length: 0,
                selectedRange: CFRange(location: 0, length: 0)
            ), from: element)
        }

        let reportedLength = integerAttribute(
            kAXNumberOfCharactersAttribute,
            from: element
        )
        let completeValue = reportedLength.map { $0 <= maximumCompleteTextReadLength } != false
            ? stringAttribute(kAXValueAttribute, from: element)
            : nil
        let documentLength = reportedLength ?? completeValue.map { ($0 as NSString).length }
        guard let documentLength,
              documentLength >= 0,
              selectedRange.location + selectedRange.length <= documentLength else {
            return nil
        }

        if scope == .document, documentLength > maximumManualReviewLength {
            return nil
        }
        // An empty field has no range to read. Applications differ on whether they
        // answer AXStringForRange or AXValue for one, so state it directly instead.
        if documentLength == 0 {
            return validatedTextState(CapturedTextState(
                text: "",
                range: NSRange(location: 0, length: 0),
                documentUTF16Length: 0,
                selectedRange: selectedRange
            ), from: element)
        }
        if let completeValue, (completeValue as NSString).length == documentLength {
            return validatedTextState(CapturedTextState(
                text: completeValue,
                range: NSRange(location: 0, length: documentLength),
                documentUTF16Length: documentLength,
                selectedRange: selectedRange
            ), from: element)
        }

        let range: NSRange
        if selectedRange.length > 0 {
            guard selectedRange.length <= maximumSelectionLength else { return nil }
            range = NSRange(location: selectedRange.location, length: selectedRange.length)
        } else if scope == .document {
            range = NSRange(location: 0, length: documentLength)
        } else {
            let preferredBefore = maximumRangeWindowLength * 3 / 4
            var start = max(0, selectedRange.location - preferredBefore)
            var end = min(documentLength, start + maximumRangeWindowLength)
            if end - start < maximumRangeWindowLength {
                start = max(0, end - maximumRangeWindowLength)
            }
            end = max(start, end)
            range = NSRange(location: start, length: end - start)
        }

        guard let text = stringForRange(range, in: element),
              (text as NSString).length == range.length else {
            return nil
        }
        return validatedTextState(CapturedTextState(
            text: text,
            range: range,
            documentUTF16Length: documentLength,
            selectedRange: selectedRange
        ), from: element)
    }

    private func validatedTextState(
        _ state: CapturedTextState,
        from element: AXUIElement
    ) -> CapturedTextState? {
        guard let confirmedRange = selectedRange(of: element),
              confirmedRange.location == state.selectedRange.location,
        confirmedRange.length == state.selectedRange.length,
        documentLength(of: element) == state.documentUTF16Length else {
            return nil
        }
        return state.withCaret(realignedCaretLocation(for: state, in: element))
    }

    /// Where the caret is, once the source's own answer has been reconciled with the
    /// text it handed over.
    ///
    /// A caret resting at the end of a paragraph and one resting at the start of the
    /// next are the same place on screen, and Chromium publishes the second spelling for
    /// both: ask a `contenteditable` where its collapsed selection is while the author is
    /// typing at the end of a line, and the offset that comes back begins the line below.
    /// Everything downstream then agrees on the wrong paragraph, so a review of "the
    /// paragraph at the cursor" proposes a rewrite of the signature under the letter.
    ///
    /// The offset cannot settle it, because both positions are the same number. The
    /// writing immediately before the caret can, and the text-marker API reports that
    /// separately — a marker is a position in a document rather than a number, so the two
    /// are different markers even where they are the same offset.
    private func realignedCaretLocation(
        for state: CapturedTextState,
        in element: AXUIElement
    ) -> Int {
        let reported = state.selectedRange.location
        guard state.selectedRange.length == 0 else { return reported }

        // Only a caret a source placed at the start of a line can be the downstream
        // spelling of one resting at the end of the line above, so nowhere else is worth
        // the marker round trips.
        let local = reported - state.range.location
        guard CaretAlignment.isAtLineStart(local, in: state.text),
              let lineBeforeCaret = lineBeforeCaret(in: element) else {
            return reported
        }

        let resolved = CaretAlignment.resolved(
            reported: local,
            lineBeforeCaret: lineBeforeCaret,
            in: state.text
        )
        if resolved != local {
            logger.debug(
                """
                Caret realigned from \(reported, privacy: .public) to \
                \(resolved + state.range.location, privacy: .public), against a line of \
                \((lineBeforeCaret as NSString).length, privacy: .public) characters
                """
            )
        }
        return resolved + state.range.location
    }

    /// The writing between the start of the caret's line and the caret itself, as the
    /// text-marker API reports it.
    ///
    /// Empty when the caret really is at the start of a line, which is what makes this an
    /// answer rather than a guess. Absent in every host that publishes no markers —
    /// native controls report their offsets consistently and never come here.
    ///
    /// It does not matter whether a host reads "previous line start" as the start of the
    /// caret's own line or of the one before it. The probe is trimmed to the caret's line
    /// either way, and one that overran is only a longer match.
    private func lineBeforeCaret(in element: AXUIElement) -> String? {
        guard let selection = attributeValue("AXSelectedTextMarkerRange", from: element),
              let caret = parameterizedAttributeValue(
                "AXStartTextMarkerForTextMarkerRange",
                parameter: selection,
                from: element
              ),
              let lineStart = parameterizedAttributeValue(
                "AXPreviousLineStartTextMarkerForTextMarker",
                parameter: caret,
                from: element
              ) ?? markerSteppedBack(from: caret, in: element),
              let lineRange = parameterizedAttributeValue(
                "AXTextMarkerRangeForUnorderedTextMarkers",
                parameter: [lineStart, caret] as CFArray,
                from: element
              ),
              let line = parameterizedAttributeValue(
                "AXStringForTextMarkerRange",
                parameter: lineRange,
                from: element
              ) else {
            return nil
        }
        return (line as? String) ?? (line as? NSAttributedString)?.string
    }

    /// A bounded walk back through single markers, for a host that publishes markers but
    /// will not say where a line begins.
    private func markerSteppedBack(
        from caret: CFTypeRef,
        in element: AXUIElement
    ) -> CFTypeRef? {
        var marker = caret
        var stepped: CFTypeRef?
        for _ in 0..<maximumCaretMarkerSteps {
            guard let previous = parameterizedAttributeValue(
                "AXPreviousTextMarkerForTextMarker",
                parameter: marker,
                from: element
            ) else {
                break
            }
            marker = previous
            stepped = previous
        }
        return stepped
    }

    private func maximumTargetLength(
        selectedRange: CFRange,
        scope: TextEditExtractionScope
    ) -> Int {
        if selectedRange.length > 0 {
            return maximumSelectionLength
        }
        return scope == .document
            ? maximumManualReviewLength
            : maximumAutomaticContextLength
    }

    func snapshotState(_ snapshot: FocusedTextSnapshot) -> AccessibilitySnapshotState {
        guard let currentLength = documentLength(of: snapshot.element),
              currentLength == snapshot.documentUTF16Length,
              let currentSelection = selectedRange(of: snapshot.element),
              currentSelection.location == snapshot.selectedRange.location,
              currentSelection.length == snapshot.selectedRange.length,
              let currentText = capturedText(
                in: snapshot.capturedTextRange,
                from: snapshot.element
              ) else {
            return .unavailable
        }
        return currentText == snapshot.fullText ? .unchanged : .changed
    }

    /// Reports whether the source application still has the reviewed field focused.
    ///
    /// A caret moving inside that field leaves a proposal applicable, so this is
    /// deliberately narrower than the selection and value checks: only focus landing on
    /// a different writable element retires the proposal.
    func focusState(for snapshot: FocusedTextSnapshot) -> AccessibilityFocusState {
        guard isTrusted else { return .unavailable }

        let applicationElement = AXUIElementCreateApplication(snapshot.processIdentifier)
        guard var element = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: applicationElement
        ) else {
            return .unavailable
        }

        if !isSupportedTextElement(element),
           let editableAncestor = elementAttribute(kAXEditableAncestorAttribute, from: element) {
            element = editableAncestor
        }
        if elementsAreEqual(element, snapshot.element) {
            return .matchesSnapshot
        }

        // Menus, buttons, and the placeholder focus some applications report while a
        // panel is key are not a new writing site. Treating them as unavailable leaves
        // the decision to revalidation instead of retiring a usable proposal.
        guard isSupportedTextElement(element), !isProtected(element) else {
            return .unavailable
        }
        return .otherEditableElement
    }

    /// The screen frame of the window holding a snapshot's text, in AppKit coordinates.
    ///
    /// A proposal is anchored to text rather than to the screen, so this is what a
    /// pinned anchor is measured against while the user drags or resizes the window.
    func sourceWindowFrame(for snapshot: FocusedTextSnapshot) -> CGRect? {
        guard let window = elementAttribute(kAXWindowAttribute, from: snapshot.element) else {
            return nil
        }
        guard let frame = elementRect(window), frame.width > 0, frame.height > 0 else {
            return nil
        }
        return frame
    }

    func isUnchanged(_ snapshot: FocusedTextSnapshot) -> Bool {
        snapshotState(snapshot) == .unchanged
    }

    func sourceTextIsUnchanged(_ snapshot: FocusedTextSnapshot) -> Bool {
        capturedSourceIsUnchanged(snapshot)
    }

    /// Reconnects a proposal to a focused text element that an application recreated
    /// while it was inactive. Native controls can invalidate their AX element on app
    /// deactivation even though the document, selection, and source text did not change.
    func refreshedSnapshot(matching snapshot: FocusedTextSnapshot) -> FocusedTextSnapshot? {
        for scope in [TextEditExtractionScope.sentence, .document] {
            guard let candidate = captureFocusedText(scope: scope) else { continue }
            guard candidate.processIdentifier == snapshot.processIdentifier,
                  candidate.documentUTF16Length == snapshot.documentUTF16Length,
                  candidate.capturedTextRange == snapshot.capturedTextRange,
                  candidate.fullText == snapshot.fullText,
                  candidate.selectedRange.location == snapshot.selectedRange.location,
                  candidate.selectedRange.length == snapshot.selectedRange.length,
                  candidate.context.range == snapshot.context.range,
                  candidate.context.text == snapshot.context.text else {
                continue
            }
            return candidate
        }
        return nil
    }

    func sourceSuggestionGeometry(
        for snapshot: FocusedTextSnapshot,
        suggestion: WritingSuggestion
    ) -> SourceSuggestionGeometry? {
        guard capturedSourceIsUnchanged(snapshot) else { return nil }

        let style: SourceSuggestionMarkStyle
        let sourceRanges: [NSRange]
        switch suggestion.kind {
        case .correction:
            let segments = WritingDiffPlanner.make(
                original: suggestion.originalText,
                replacement: suggestion.replacementText
            )
            sourceRanges = segments.compactMap(trimmedRemovedRange)
            style = .deletion
        case .rewrite:
            sourceRanges = [snapshot.context.range]
            style = .rewrite
        case .completion, .composition:
            // Neither marks existing text: one appends to it, the other writes where
            // there is none.
            return nil
        }

        guard !sourceRanges.isEmpty else { return nil }
        var marks: [SourceSuggestionMark] = []
        for sourceRange in sourceRanges {
            let absoluteRange: NSRange
            if suggestion.kind == .correction {
                absoluteRange = NSRange(
                    location: snapshot.context.utf16Location + sourceRange.location,
                    length: sourceRange.length
                )
            } else {
                absoluteRange = sourceRange
            }
            guard let rects = visibleRects(
                for: absoluteRange,
                in: snapshot.element
            ), !rects.isEmpty else {
                return nil
            }
            marks.append(contentsOf: rects.map {
                SourceSuggestionMark(rect: $0, style: style)
            })
        }

        return marks.isEmpty ? nil : SourceSuggestionGeometry(marks: marks)
    }

    func supportsSourceSuggestionOverlay(_ suggestion: WritingSuggestion) -> Bool {
        switch suggestion.kind {
        case .correction:
            let segments = WritingDiffPlanner.make(
                original: suggestion.originalText,
                replacement: suggestion.replacementText
            )
            return segments.contains(where: { trimmedRemovedRange($0) != nil })
        case .rewrite:
            return true
        case .completion, .composition:
            return false
        }
    }

    func replace(_ snapshot: FocusedTextSnapshot, with correctedText: String) async throws {
        guard isTrusted else { throw AccessibilityTextError.permissionRequired }
        // Clicking a non-activating proposal panel can still make Chromium briefly
        // report a different or unavailable selection. The global input monitors have
        // already invalidated explicit user navigation, so verify the source text and
        // document length here and let the replacement select its target range again.
        guard try await waitForSourceToRemainUnchanged(snapshot) else {
            throw AccessibilityTextError.fieldChanged
        }

        guard let localContext = snapshot.context.translated(
            byUTF16Offset: -snapshot.capturedTextRange.location
        ) else {
            throw AccessibilityTextError.fieldChanged
        }
        guard let updatedText = TextEditContextExtractor.replacing(
                context: localContext,
                in: snapshot.fullText,
                with: correctedText
        ) else {
            throw AccessibilityTextError.fieldChanged
        }
        let replacementDelta = (correctedText as NSString).length
            - snapshot.context.utf16Length
        let updatedCapturedRange = NSRange(
            location: snapshot.capturedTextRange.location,
            length: snapshot.capturedTextRange.length + replacementDelta
        )

        // Browser-backed editors frequently implement range replacement even when a
        // whole-value write reports success without updating the DOM. Prefer the
        // standard selected-text attributes so the edit also preserves content outside
        // the captured sentence (and any rich-text structure owned by the editor).
        if try await replaceSelectedText(
            in: snapshot.element,
            range: snapshot.context.range,
            originalText: snapshot.context.text,
            with: correctedText,
            expectedText: updatedText,
            expectedRange: updatedCapturedRange
        ) {
            moveCaret(
                in: snapshot.element,
                to: snapshot.context.utf16Location + (correctedText as NSString).length
            )
            return
        }

        // Selecting the range is itself an observable state change. Some browser-backed
        // editors (including ChatGPT's contenteditable composer) accept that selection
        // but reject AXSelectedText writes. Validate the text independently of the
        // selection before restoring the original caret and trying another strategy.
        // A failed range write may still have changed the document, so never continue
        // when either the captured text or document length differs from the snapshot.
        guard capturedSourceIsUnchanged(snapshot) else {
            throw AccessibilityTextError.replacementFailed
        }
        restoreSelection(snapshot.selectedRange, in: snapshot.element)

        let capturedCompleteField = snapshot.capturedTextRange.location == 0
            && snapshot.capturedTextRange.length == snapshot.documentUTF16Length
        if capturedCompleteField,
           isAttributeSettable(kAXValueAttribute, on: snapshot.element) {
            let valueResult = AXUIElementSetAttributeValue(
                snapshot.element,
                kAXValueAttribute as CFString,
                updatedText as CFString
            )
            if valueResult == .success,
               try await waitForCapturedText(
                updatedText,
                range: updatedCapturedRange,
                in: snapshot.element,
                attempts: 8
               ) {
                moveCaret(
                    in: snapshot.element,
                    to: snapshot.context.utf16Location + (correctedText as NSString).length
                )
                return
            }

            guard capturedSourceIsUnchanged(snapshot) else {
                throw AccessibilityTextError.replacementFailed
            }
            restoreSelection(snapshot.selectedRange, in: snapshot.element)
        }

        if try await replaceWithKeyboardInput(
            snapshot,
            replacement: correctedText,
            expectedText: updatedText,
            expectedRange: updatedCapturedRange
        ) {
            moveCaret(
                in: snapshot.element,
                to: snapshot.context.utf16Location + (correctedText as NSString).length
            )
            return
        }

        if capturedSourceIsUnchanged(snapshot) {
            restoreSelection(snapshot.selectedRange, in: snapshot.element)
        }
        throw AccessibilityTextError.replacementFailed
    }

    private func replaceSelectedText(
        in element: AXUIElement,
        range: NSRange,
        originalText: String,
        with replacement: String,
        expectedText: String,
        expectedRange: NSRange
    ) async throws -> Bool {
        guard isAttributeSettable(kAXSelectedTextRangeAttribute, on: element),
              isAttributeSettable(kAXSelectedTextAttribute, on: element),
              try await selectText(
                range,
                originalText: originalText,
                in: element
              ) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        )
        guard result == .success else { return false }
        return try await waitForCapturedText(
            expectedText,
            range: expectedRange,
            in: element,
            attempts: 12
        )
    }

    private func replaceWithKeyboardInput(
        _ snapshot: FocusedTextSnapshot,
        replacement: String,
        expectedText: String,
        expectedRange: NSRange
    ) async throws -> Bool {
        focus(snapshot.element)
        guard try await selectText(
            snapshot.context.range,
            originalText: snapshot.context.text,
            in: snapshot.element
        ), postKeyboardInput(replacement, to: snapshot.processIdentifier) else {
            return false
        }

        return try await waitForCapturedText(
            expectedText,
            range: expectedRange,
            in: snapshot.element,
            attempts: 24
        )
    }

    private func selectText(
        _ range: NSRange,
        originalText: String,
        in element: AXUIElement
    ) async throws -> Bool {
        guard setSelection(range, in: element) else { return false }

        for attempt in 0..<8 {
            try Task.checkCancellation()
            if let selectedRange = selectedRange(of: element),
               selectedRange.location == range.location,
               selectedRange.length == range.length,
               (stringAttribute(kAXSelectedTextAttribute, from: element) ?? "") == originalText {
                return true
            }
            if attempt < 7 {
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        return false
    }

    private func waitForCapturedText(
        _ expectedText: String,
        range: NSRange,
        in element: AXUIElement,
        attempts: Int
    ) async throws -> Bool {
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            if capturedText(in: range, from: element) == expectedText {
                return true
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        return false
    }

    private func waitForSourceToRemainUnchanged(
        _ snapshot: FocusedTextSnapshot,
        attempts: Int = 4
    ) async throws -> Bool {
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            if capturedSourceIsUnchanged(snapshot) {
                return true
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        return false
    }

    private func focus(_ element: AXUIElement) {
        guard !boolAttribute(kAXFocusedAttribute, from: element),
              isAttributeSettable(kAXFocusedAttribute, on: element) else {
            return
        }
        AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
    }

    private func postKeyboardInput(_ text: String, to processIdentifier: pid_t) -> Bool {
        let chunks = unicodeChunks(text)
        guard !chunks.isEmpty else { return false }

        let source = CGEventSource(stateID: .privateState)
        for chunk in chunks {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                return false
            }

            let utf16 = Array(chunk.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
        }
        return true
    }

    private func unicodeChunks(
        _ text: String,
        maximumUTF16Length: Int = 64
    ) -> [String] {
        var chunks: [String] = []
        var chunk = ""
        var chunkLength = 0

        for character in text {
            let characterText = String(character)
            let characterLength = characterText.utf16.count
            if !chunk.isEmpty, chunkLength + characterLength > maximumUTF16Length {
                chunks.append(chunk)
                chunk = ""
                chunkLength = 0
            }
            chunk.append(character)
            chunkLength += characterLength
        }
        if !chunk.isEmpty {
            chunks.append(chunk)
        }
        return chunks
    }

    private func documentLength(of element: AXUIElement) -> Int? {
        if isShowingPlaceholder(element) { return 0 }
        return integerAttribute(kAXNumberOfCharactersAttribute, from: element)
            ?? stringAttribute(kAXValueAttribute, from: element).map { ($0 as NSString).length }
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        if isShowingPlaceholder(element) { return CFRange(location: 0, length: 0) }
        return rangeAttribute(kAXSelectedTextRangeAttribute, from: element)
    }

    /// Reports whether an element is drawing a prompt in place of a value.
    ///
    /// Chromium folds the generated content of an empty `contenteditable` into the
    /// accessible text: `AXValue` answers with the prompt and `AXNumberOfCharacters`
    /// agrees. None of that is text the user wrote, so every read above treats such a
    /// field as empty. Correcting it would otherwise propose a rewrite of a prompt nobody
    /// typed, and writing into it would start from the prompt's offsets rather than from
    /// an empty document.
    ///
    /// Two things can give a prompt away, and a host exposes one or the other. A web page
    /// that sets `placeholder` or `aria-placeholder` gets `AXPlaceholderValue`, and the
    /// value echoing it settles the question. A rich-text editor sets neither, so it is
    /// taken at its word when it marks its own document empty.
    private func isShowingPlaceholder(_ element: AXUIElement) -> Bool {
        let metadata = multipleAttributeValues(
            [
                kAXPlaceholderValueAttribute as String,
                kAXDescriptionAttribute as String,
                kAXTitleAttribute as String,
                kAXNumberOfCharactersAttribute as String,
                domClassListAttribute
            ],
            from: element
        )
        let characterCount = integerValue(metadata[kAXNumberOfCharactersAttribute as String])
        if isMarkedEmptyEditor(
            element,
            classList: metadata[domClassListAttribute],
            characterCount: characterCount
        ) {
            return true
        }

        let prompts = [
            kAXPlaceholderValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXTitleAttribute as String
        ]
            .compactMap { singleLine(stringValue(metadata[$0])) }
            .filter { ($0 as NSString).length <= maximumPlaceholderPromptLength }
        guard let longestPrompt = prompts.map({ ($0 as NSString).length }).max() else {
            return false
        }
        // An echo is a prompt itself, give or take the slack below. A longer field is
        // holding text, and reading that text back to compare it would cost a round trip
        // for nothing.
        if let characterCount, characterCount > longestPrompt + placeholderEchoSlack {
            return false
        }
        guard let value = normalizedPrompt(stringAttribute(kAXValueAttribute, from: element)) else {
            return false
        }
        return prompts.contains { normalizedPrompt($0) == value }
    }

    /// Reports whether a rich-text editor has marked its own document empty while still
    /// reporting the prompt it draws as its value.
    ///
    /// An editor of this kind draws its prompt as generated content inside the editable
    /// node itself — the Electron chat composers Plainword meets are built this way — so
    /// there is no prompt attribute to compare a value against, and the drawn text is
    /// indistinguishable from writing by every other measure the Accessibility API
    /// offers. What these editors do publish is the class they put on an empty document,
    /// which is the same fact stated by the one party that knows it.
    ///
    /// The class sits on the editor itself for some and on the blank paragraph inside it
    /// for others, so both are examined. Only classes meaning *the document* is empty
    /// count: an editor also marks a blank paragraph in the middle of a full document,
    /// and reading that as an empty field would discard the text around it.
    private func isMarkedEmptyEditor(
        _ element: AXUIElement,
        classList: Any?,
        characterCount: Int?
    ) -> Bool {
        // Absent outside a web view, which is the cheap way to leave native fields alone.
        guard let ownClasses = stringArrayValue(classList) else { return false }
        if ownClasses.contains(where: emptyEditorClassNames.contains) { return true }
        // Only a prompt's worth of text can be a prompt, and a longer document does not
        // deserve the round trips below either.
        guard let characterCount, characterCount <= maximumPlaceholderPromptLength else {
            return false
        }
        return uiElementArray(attributeValue(kAXChildrenAttribute, from: element))
            .prefix(maximumEmptyEditorChildScan)
            .contains { child in
                stringArrayValue(attributeValue(domClassListAttribute, from: child))?
                    .contains(where: emptyEditorClassNames.contains) ?? false
            }
    }

    /// Reduces a prompt or a field value to the form the two can be compared in.
    ///
    /// The same prompt reaches different attributes spelled differently: the value an
    /// editor reports carries the trailing ellipsis it draws and the line break of its
    /// empty paragraph, where the accessible name carries neither. Returns `nil` for
    /// anything that holds no text, which is not a prompt at all.
    private func normalizedPrompt(_ text: String?) -> String? {
        guard let collapsed = singleLine(text) else { return nil }
        var trimmed = collapsed[...]
        while trimmed.hasSuffix("\u{2026}") || trimmed.hasSuffix("...") {
            trimmed = trimmed.hasSuffix("\u{2026}") ? trimmed.dropLast() : trimmed.dropLast(3)
            while trimmed.last?.isWhitespace == true { trimmed = trimmed.dropLast() }
        }
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    private func singleLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Used only after Plainword has deliberately changed the source selection while
    /// attempting a replacement. The public snapshot check remains selection-sensitive
    /// so an external caret move still invalidates a pending suggestion.
    private func capturedSourceIsUnchanged(_ snapshot: FocusedTextSnapshot) -> Bool {
        guard documentLength(of: snapshot.element) == snapshot.documentUTF16Length,
              let currentText = capturedText(
                in: snapshot.capturedTextRange,
                from: snapshot.element
              ) else {
            return false
        }
        return currentText == snapshot.fullText
    }

    private func capturedText(in range: NSRange, from element: AXUIElement) -> String? {
        // Reading an empty range back would otherwise depend on the application
        // answering a parameterized query about nothing.
        if range.length == 0 { return "" }
        if let completeValue = stringAttribute(kAXValueAttribute, from: element),
           range.location == 0,
           (completeValue as NSString).length == range.length {
            return completeValue
        }
        return stringForRange(range, in: element)
    }

    private func moveCaret(in element: AXUIElement, to location: Int) {
        _ = setSelection(NSRange(location: location, length: 0), in: element)
    }

    private func restoreSelection(_ range: CFRange, in element: AXUIElement) {
        _ = setSelection(
            NSRange(location: range.location, length: range.length),
            in: element
        )
    }

    private func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }

    private func isSupportedTextElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element),
              stringAttribute(kAXSubroleAttribute, from: element) != kAXSecureTextFieldSubrole as String else {
            return false
        }
        if standardTextRoles.contains(role) {
            return true
        }

        // Chromium and other accessibility bridges can expose contenteditable roots as
        // AXGroup or AXWebArea. Prefer the actual text capabilities over a closed role
        // list, while retaining the writable/protected checks at the capture boundary.
        let explicitlyEditable = boolAttribute(kAXIsEditableAttribute, from: element)
        let exposesSelection = hasAttribute(kAXSelectedTextRangeAttribute, on: element)
        let exposesText = hasAttribute(kAXValueAttribute, on: element)
            || supportsParameterizedAttribute(
                kAXStringForRangeParameterizedAttribute,
                on: element
            )
        return (explicitlyEditable || isWritableTextElement(element))
            && exposesSelection
            && exposesText
    }

    private func hasMultipleSelections(_ element: AXUIElement) -> Bool {
        rangeArrayAttribute(kAXSelectedTextRangesAttribute, from: element).count > 1
    }

    private func isProtected(_ element: AXUIElement) -> Bool {
        AccessibilityElementReader.isProtected(element)
    }

    /// Browser address and search controls are exposed as writable text fields inside an
    /// accessibility toolbar. Web-page editors instead live below an AXWebArea. Using the
    /// semantic hierarchy keeps this independent of any browser's bundle identifier.
    private func isInsideToolbar(_ element: AXUIElement) -> Bool {
        var currentElement: AXUIElement? = element

        for _ in 0..<20 {
            guard let candidate = currentElement else { return false }
            let role = stringAttribute(kAXRoleAttribute, from: candidate)
            if role == "AXWebArea" {
                return false
            }
            if role == kAXToolbarRole as String {
                return true
            }
            currentElement = elementAttribute(kAXParentAttribute, from: candidate)
        }

        return false
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        AccessibilityElementReader.isAttributeSettable(attribute, on: element)
    }

    private func isWritableTextElement(_ element: AXUIElement) -> Bool {
        AccessibilityElementReader.isWritableTextElement(element)
    }

    private func hasAttribute(_ attribute: String, on element: AXUIElement) -> Bool {
        AccessibilityElementReader.hasAttribute(attribute, on: element)
    }

    private func supportsParameterizedAttribute(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        AccessibilityElementReader.supportsParameterizedAttribute(attribute, on: element)
    }

    private func multipleAttributeValues(
        _ attributes: [String],
        from element: AXUIElement
    ) -> [String: Any] {
        AccessibilityElementReader.multipleAttributeValues(attributes, from: element)
    }

    private func stringValue(_ value: Any?) -> String? {
        AccessibilityElementReader.stringValue(value)
    }

    private func boolValue(_ value: Any?) -> Bool {
        AccessibilityElementReader.boolValue(value)
    }

    private func integerValue(_ value: Any?) -> Int? {
        AccessibilityElementReader.integerValue(value)
    }

    private func stringArrayValue(_ value: Any?) -> [String]? {
        value as? [String]
    }

    private func axValue(_ value: Any?) -> AXValue? {
        AccessibilityElementReader.axValue(value)
    }

    private func uiElementValue(_ value: Any?) -> AXUIElement? {
        AccessibilityElementReader.uiElementValue(value)
    }

    private func uiElementArray(_ value: Any?) -> [AXUIElement] {
        AccessibilityElementReader.uiElementArray(value)
    }

    private func elementsAreEqual(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        AccessibilityElementReader.elementsAreEqual(lhs, rhs)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        AccessibilityElementReader.stringAttribute(attribute, from: element)
    }

    private func integerAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        AccessibilityElementReader.integerAttribute(attribute, from: element)
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        AccessibilityElementReader.boolAttribute(attribute, from: element)
    }

    private func rangeAttribute(_ attribute: String, from element: AXUIElement) -> CFRange? {
        AccessibilityElementReader.rangeAttribute(attribute, from: element)
    }

    private func rangeArrayAttribute(_ attribute: String, from element: AXUIElement) -> [CFRange] {
        AccessibilityElementReader.rangeArrayAttribute(attribute, from: element)
    }

    private func stringForRange(_ range: NSRange, in element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        guard let result = parameterizedAttributeValue(
            kAXStringForRangeParameterizedAttribute,
            parameter: rangeValue,
            from: element
        ) else {
            return nil
        }
        if let string = result as? String {
            return string
        }
        return (result as? NSAttributedString)?.string
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        AccessibilityElementReader.elementAttribute(attribute, from: element)
    }

    private func attributeValue(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        AccessibilityElementReader.attributeValue(attribute, from: element)
    }

    private func anchorRect(
        for range: NSRange,
        textLength: Int,
        in element: AXUIElement
    ) -> CGRect {
        if range.length > 0 {
            if let markerAnchor = selectedTextMarkerSelectionAnchorRect(in: element) {
                return markerAnchor
            }
            if let selectionAnchor = preferredSelectionAnchor(
                start: selectionStartAnchorRect(for: range, in: element),
                end: selectionEndAnchorRect(for: range, in: element)
            ) {
                return selectionAnchor
            }
        }

        if range.length == 0 {
            if let markerCaret = selectedTextMarkerCaretRect(in: element) {
                return markerCaret
            }

            if let caretBounds = bounds(for: range, in: element),
               isPlausibleCaretBounds(caretBounds, in: element) {
                return caretRect(from: caretBounds, range: range, textLength: textLength)
            }

            // Chromium sometimes reports the whole contenteditable frame for an
            // empty range. In that case, anchor after the glyph immediately before
            // the caret so the compact action follows the text the user just typed.
            if textLength > 0 {
                let probeLocation = range.location > 0
                    ? min(range.location - 1, textLength - 1)
                    : 0
                if let glyphBounds = bounds(
                    for: NSRange(location: probeLocation, length: 1),
                    in: element
                ), isPlausibleGlyphBounds(glyphBounds, in: element) {
                    let x = range.location > 0 ? glyphBounds.maxX : glyphBounds.minX
                    return CGRect(
                        x: x,
                        y: glyphBounds.minY,
                        width: 2,
                        height: max(glyphBounds.height, 16)
                    )
                }
            }
        }

        guard let fieldRect = elementRect(element), fieldRect != .zero else {
            return CGRect(origin: NSEvent.mouseLocation, size: CGSize(width: 2, height: 18))
        }
        if range.length > 0,
           let pointerAnchor = SelectionAnchorResolver.pointerFallback(
               pointer: NSEvent.mouseLocation,
               inside: fieldRect
           ) {
            return pointerAnchor
        }
        return CGRect(
            x: min(fieldRect.minX + 24, fieldRect.maxX),
            y: max(fieldRect.minY, fieldRect.maxY - 28),
            width: 2,
            height: min(max(fieldRect.height, 18), 22)
        )
    }

    private func selectionStartAnchorRect(
        for range: NSRange,
        in element: AXUIElement
    ) -> CGRect? {
        let maximumProbeCount = min(range.length, 64)
        for offset in 0..<maximumProbeCount {
            guard let visibleGlyph = visibleGlyphRect(
                at: range.location + offset,
                in: element
            ) else {
                continue
            }
            return endpointAnchor(for: visibleGlyph, edge: .leading)
        }

        guard let firstVisibleRect = visibleRects(for: range, in: element)?.first else {
            return nil
        }
        return endpointAnchor(for: firstVisibleRect, edge: .leading)
    }

    private func selectionEndAnchorRect(
        for range: NSRange,
        in element: AXUIElement
    ) -> CGRect? {
        // Browser bridges often return the first line (or the editor frame) for a
        // multi-line AXBoundsForRange request. Resolve a glyph at the end of the
        // selection instead so the compact action sits beside the selected text.
        let maximumProbeCount = min(range.length, 64)
        for offset in 0..<maximumProbeCount {
            let location = NSMaxRange(range) - 1 - offset
            guard let visibleGlyph = visibleGlyphRect(at: location, in: element) else {
                continue
            }
            return endpointAnchor(for: visibleGlyph, edge: .trailing)
        }

        if let lastVisibleRect = visibleRects(for: range, in: element)?.last {
            return endpointAnchor(for: lastVisibleRect, edge: .trailing)
        }
        return nil
    }

    private func visibleGlyphRect(at location: Int, in element: AXUIElement) -> CGRect? {
        guard let glyphBounds = bounds(
            for: NSRange(location: location, length: 1),
            in: element
        ) else {
            return nil
        }
        if let elementFrame = elementRect(element) {
            return clippedVisibleRects(glyphBounds, to: elementFrame).first
        }
        return NSScreen.screens.lazy.compactMap { screen in
            let visible = glyphBounds.intersection(screen.frame)
            return visible.isNull ? nil : visible
        }.first
    }

    private func isPlausibleCaretBounds(
        _ bounds: CGRect,
        in element: AXUIElement
    ) -> Bool {
        guard bounds != .zero,
              bounds.width >= 0,
              bounds.height > 0,
              bounds.width <= 24,
              bounds.height <= 80 else {
            return false
        }
        guard let elementFrame = elementRect(element), elementFrame != .zero else {
            return true
        }
        return bounds.intersects(elementFrame)
    }

    private func isPlausibleGlyphBounds(
        _ bounds: CGRect,
        in element: AXUIElement
    ) -> Bool {
        guard bounds != .zero,
              bounds.width > 0,
              bounds.height > 0,
              bounds.width <= 80,
              bounds.height <= 80 else {
            return false
        }
        guard let elementFrame = elementRect(element), elementFrame != .zero else {
            return true
        }
        let resemblesWholeElement = bounds.width >= elementFrame.width * 0.75
            && bounds.height >= elementFrame.height * 0.75
        return bounds.intersects(elementFrame) && !resemblesWholeElement
    }

    private func selectedTextMarkerCaretRect(in element: AXUIElement) -> CGRect? {
        // Chromium exposes web caret geometry through its text-marker API. Its
        // NSRange-based AXBoundsForRange implementation can return nil or the whole
        // contenteditable frame, especially for a collapsed selection after typing.
        guard let markerRange = attributeValue(
            "AXSelectedTextMarkerRange",
            from: element
        ) else {
            return nil
        }

        if let bounds = textMarkerBounds(for: markerRange, in: element),
           isPlausibleCaretBounds(bounds, in: element) {
            return CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: 2,
                height: max(bounds.height, 16)
            )
        }

        // At the end of a contenteditable Chromium may return an empty rectangle for
        // the collapsed marker range. Resolve the preceding marker range and anchor
        // immediately after that glyph instead.
        guard let caretMarker = parameterizedAttributeValue(
            "AXStartTextMarkerForTextMarkerRange",
            parameter: markerRange,
            from: element
        ), let previousMarker = parameterizedAttributeValue(
            "AXPreviousTextMarkerForTextMarker",
            parameter: caretMarker,
            from: element
        ) else {
            return nil
        }
        let markers = [previousMarker, caretMarker] as CFArray
        guard let precedingRange = parameterizedAttributeValue(
            "AXTextMarkerRangeForUnorderedTextMarkers",
            parameter: markers,
            from: element
        ), let precedingBounds = textMarkerBounds(
            for: precedingRange,
            in: element
        ), isPlausibleGlyphBounds(precedingBounds, in: element) else {
            return nil
        }
        return CGRect(
            x: precedingBounds.maxX,
            y: precedingBounds.minY,
            width: 2,
            height: max(precedingBounds.height, 16)
        )
    }

    private func selectedTextMarkerSelectionAnchorRect(in element: AXUIElement) -> CGRect? {
        // Chromium's NSRange-based bounds can be relative to an accessibility
        // container instead of the visible web content. Resolve both text-marker
        // endpoints in screen coordinates: marker ranges are normalized, while a
        // mouse selection can be made in either direction.
        guard let markerRange = attributeValue(
            "AXSelectedTextMarkerRange",
            from: element
        ) else {
            return nil
        }

        let startAnchor: CGRect?
        if let startMarker = parameterizedAttributeValue(
            "AXStartTextMarkerForTextMarkerRange",
            parameter: markerRange,
            from: element
        ), let nextMarker = parameterizedAttributeValue(
            "AXNextTextMarkerForTextMarker",
            parameter: startMarker,
            from: element
        ) {
            startAnchor = textMarkerEndpointAnchor(
                between: startMarker,
                and: nextMarker,
                edge: .leading,
                in: element
            )
        } else {
            startAnchor = nil
        }

        let endAnchor: CGRect?
        if let endMarker = parameterizedAttributeValue(
            "AXEndTextMarkerForTextMarkerRange",
            parameter: markerRange,
            from: element
        ), let previousMarker = parameterizedAttributeValue(
            "AXPreviousTextMarkerForTextMarker",
            parameter: endMarker,
            from: element
        ) {
            endAnchor = textMarkerEndpointAnchor(
                between: previousMarker,
                and: endMarker,
                edge: .trailing,
                in: element
            )
        } else {
            endAnchor = nil
        }

        return preferredSelectionAnchor(start: startAnchor, end: endAnchor)
    }

    private func textMarkerEndpointAnchor(
        between firstMarker: CFTypeRef,
        and secondMarker: CFTypeRef,
        edge: HorizontalEndpointEdge,
        in element: AXUIElement
    ) -> CGRect? {
        let markers = [firstMarker, secondMarker] as CFArray
        guard let endpointRange = parameterizedAttributeValue(
            "AXTextMarkerRangeForUnorderedTextMarkers",
            parameter: markers,
            from: element
        ), let endpointBounds = textMarkerBounds(
            for: endpointRange,
            in: element
        ), isPlausibleGlyphBounds(endpointBounds, in: element) else {
            return nil
        }

        return endpointAnchor(for: endpointBounds, edge: edge)
    }

    private func endpointAnchor(
        for bounds: CGRect,
        edge: HorizontalEndpointEdge
    ) -> CGRect {
        let x = edge == .leading ? bounds.minX : bounds.maxX
        return CGRect(
            x: x,
            y: bounds.minY,
            width: 2,
            height: max(bounds.height, 16)
        )
    }

    private func preferredSelectionAnchor(start: CGRect?, end: CGRect?) -> CGRect? {
        // A mouse-created selection leaves the pointer at its active endpoint. If
        // the pointer has moved elsewhere (menu command or keyboard selection), keep
        // the conventional logical end instead of guessing a direction.
        return SelectionAnchorResolver.preferred(
            start: start,
            end: end,
            pointer: NSEvent.mouseLocation
        )
    }

    private func textMarkerBounds(
        for markerRange: CFTypeRef,
        in element: AXUIElement
    ) -> CGRect? {
        guard let boundsValue = parameterizedAttributeValue(
            "AXBoundsForTextMarkerRange",
            parameter: markerRange,
            from: element
        ), CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(boundsValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &bounds) else { return nil }
        return appKitRect(fromAccessibilityRect: bounds)
    }

    private func bounds(for range: NSRange, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        if let rangeValue = AXValueCreate(.cfRange, &cfRange),
           let boundsValue = parameterizedAttributeValue(
               kAXBoundsForRangeParameterizedAttribute,
               parameter: rangeValue,
               from: element
           ) {
            if
               CFGetTypeID(boundsValue) == AXValueGetTypeID(),
               AXValueGetType(unsafeDowncast(boundsValue, to: AXValue.self)) == .cgRect {
                let axBoundsValue = unsafeDowncast(boundsValue, to: AXValue.self)
                var bounds = CGRect.zero
                if AXValueGetValue(axBoundsValue, .cgRect, &bounds) {
                    return appKitRect(fromAccessibilityRect: bounds)
                }
            }
        }

        return nil
    }

    private func visibleRects(
        for range: NSRange,
        in element: AXUIElement
    ) -> [CGRect]? {
        guard range.location >= 0, range.length > 0,
              let elementFrame = elementRect(element),
              elementFrame.width > 0, elementFrame.height > 0 else {
            return nil
        }

        if let firstLine = lineNumber(for: range.location, in: element),
           let lastLine = lineNumber(
               for: NSMaxRange(range) - 1,
               in: element
           ), firstLine >= 0, lastLine >= firstLine,
           lastLine - firstLine <= 64 {
            var lineRects: [CGRect] = []
            var resolvedEveryLine = true

            for line in firstLine...lastLine {
                guard let lineRange = self.range(forLine: line, in: element) else {
                    resolvedEveryLine = false
                    break
                }
                let intersection = NSIntersectionRange(range, lineRange)
                guard intersection.length > 0 else { continue }
                guard let lineBounds = bounds(for: intersection, in: element) else {
                    resolvedEveryLine = false
                    break
                }
                lineRects.append(contentsOf: clippedVisibleRects(
                    lineBounds,
                    to: elementFrame
                ))
            }

            if resolvedEveryLine, !lineRects.isEmpty {
                return mergedRects(lineRects)
            }
        }

        guard let rangeBounds = bounds(for: range, in: element),
              rangeBounds.height <= 80 else {
            return nil
        }
        let clipped = clippedVisibleRects(rangeBounds, to: elementFrame)
        return clipped.isEmpty ? nil : mergedRects(clipped)
    }

    private func lineNumber(for index: Int, in element: AXUIElement) -> Int? {
        guard let narrowedIndex = Int32(exactly: index) else { return nil }
        var value = narrowedIndex
        guard let number = CFNumberCreate(nil, .intType, &value) else { return nil }
        let result = parameterizedAttributeValue(
            kAXLineForIndexParameterizedAttribute,
            parameter: number,
            from: element
        )
        return (result as? NSNumber)?.intValue
    }

    private func range(forLine line: Int, in element: AXUIElement) -> NSRange? {
        guard let narrowedLine = Int32(exactly: line) else { return nil }
        var value = narrowedLine
        guard let number = CFNumberCreate(nil, .intType, &value) else { return nil }
        guard let result = parameterizedAttributeValue(
            kAXRangeForLineParameterizedAttribute,
            parameter: number,
            from: element
        ),
        CFGetTypeID(result) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(result, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func parameterizedAttributeValue(
        _ attribute: String,
        parameter: CFTypeRef,
        from element: AXUIElement
    ) -> CFTypeRef? {
        for attempt in 0..<3 {
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(
                element,
                attribute as CFString,
                parameter,
                &value
            )
            if result == .success {
                return value
            }
            guard result == .cannotComplete, attempt < 2 else { return nil }
        }
        return nil
    }

    private func clippedVisibleRects(
        _ rect: CGRect,
        to elementFrame: CGRect
    ) -> [CGRect] {
        guard rect.width > 0, rect.height > 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else {
            return []
        }

        let fieldClipped = rect.intersection(elementFrame)
        guard !fieldClipped.isNull,
              fieldClipped.width >= 1,
              fieldClipped.height >= 3 else {
            return []
        }
        return NSScreen.screens.compactMap { screen in
            let visible = fieldClipped.intersection(screen.frame)
            guard !visible.isNull,
                  visible.width >= 1,
                  visible.height >= 3 else {
                return nil
            }
            return visible
        }
    }

    private func mergedRects(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects.sorted(by: { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 3 {
                return lhs.maxY > rhs.maxY
            }
            return lhs.minX < rhs.minX
        }) {
            if let last = result.last,
               abs(last.midY - rect.midY) <= 3,
               rect.minX - last.maxX <= 4 {
                result[result.count - 1] = last.union(rect)
            } else {
                result.append(rect)
            }
        }
        return result
    }

    private func trimmedRemovedRange(_ segment: WritingDiffSegment) -> NSRange? {
        guard segment.kind == .removed else { return nil }
        let leadingLength = segment.text.prefix(while: \Character.isWhitespace).utf16.count
        let trailingText = String(
            segment.text.reversed().prefix(while: \Character.isWhitespace)
        )
        let trailingLength = trailingText.utf16.count
        let length = segment.originalUTF16Range.length - leadingLength - trailingLength
        guard length > 0 else { return nil }
        return NSRange(
            location: segment.originalUTF16Range.location + leadingLength,
            length: length
        )
    }

    private func elementRect(_ element: AXUIElement) -> CGRect? {
        AccessibilityElementReader.rect(of: element, primaryScreenMaxY: primaryScreenMaxY)
    }

    private func caretRect(from bounds: CGRect, range: NSRange, textLength: Int) -> CGRect {
        guard range.length == 0 else { return bounds }
        let x = range.location >= textLength ? bounds.maxX : bounds.minX
        return CGRect(
            x: x,
            y: bounds.minY,
            width: max(bounds.width, 2),
            height: max(bounds.height, 16)
        )
    }

    private func appKitRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        AccessibilityElementReader.appKitRect(
            fromAccessibilityRect: rect,
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    /// Accessibility reports geometry from the top-left of the primary display while
    /// AppKit measures from the bottom-left. Reading it here lets the harvester convert
    /// frames without touching `NSScreen` from another isolation domain.
    private var primaryScreenMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }
}
