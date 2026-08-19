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

enum AccessibilitySnapshotState: Equatable {
    case unchanged
    case changed
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
    private let maximumSurroundingContextLength = 240
    private let maximumCompleteTextReadLength = 12_000
    private let maximumRangeWindowLength = 2_400
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
    }

    private let contextHarvester = ReadOnlyContextHarvester()
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
            location: selectedRange.location - textState.range.location,
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
                maximumSurroundingContextUTF16Length: scope == .sentence
                    || selectedRange.length > 0
                    ? maximumSurroundingContextLength
                    : 0
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
                for: NSRange(location: selectedRange.location, length: selectedRange.length),
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
        guard textState.documentUTF16Length == 0,
              textState.range.location == 0,
              textState.selectedRange.length == 0,
              let context = TextEditContextExtractor.insertionPoint(
                in: textState.text,
                at: textState.selectedRange.location
              ) else {
            logger.debug(
                """
                Writing: the focused field is not empty \
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
                    location: textState.selectedRange.location,
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

        let result = await contextHarvester.fragments(
            around: AXElementBox(snapshot.element),
            excluding: [
                snapshot.fullText,
                snapshot.context.text,
                snapshot.applicationName
            ],
            targetUTF16Length: snapshot.context.utf16Length,
            primaryScreenMaxY: primaryScreenMaxY
        )
        if result.telemetry.wasTruncated {
            logger.debug(
                """
                Read-only context truncated after \(result.telemetry.nodesExamined, privacy: .public) \
                nodes in \(Int(result.telemetry.durationSeconds * 1_000), privacy: .public) ms \
                (node limit: \(result.telemetry.reachedNodeLimit, privacy: .public), \
                time limit: \(result.telemetry.reachedTimeLimit, privacy: .public))
                """
            )
        }
        guard !result.fragments.isEmpty else { return snapshot }

        return snapshot.withContext(
            snapshot.context.withApplicationContext(
                snapshot.context.applicationContextFragments + result.fragments
            )
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
        guard let selectedRange = rangeAttribute(
            kAXSelectedTextRangeAttribute,
            from: element
        ), selectedRange.location >= 0, selectedRange.length >= 0 else {
            return nil
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
        guard let confirmedRange = rangeAttribute(
            kAXSelectedTextRangeAttribute,
            from: element
        ), confirmedRange.location == state.selectedRange.location,
        confirmedRange.length == state.selectedRange.length,
        documentLength(of: element) == state.documentUTF16Length else {
            return nil
        }
        return state
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
              let currentSelection = rangeAttribute(
                kAXSelectedTextRangeAttribute,
                from: snapshot.element
              ), currentSelection.location == snapshot.selectedRange.location,
              currentSelection.length == snapshot.selectedRange.length,
              let currentText = capturedText(
                in: snapshot.capturedTextRange,
                from: snapshot.element
              ) else {
            return .unavailable
        }
        return currentText == snapshot.fullText ? .unchanged : .changed
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
            if let selectedRange = rangeAttribute(
                kAXSelectedTextRangeAttribute,
                from: element
            ), selectedRange.location == range.location,
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
        integerAttribute(kAXNumberOfCharactersAttribute, from: element)
            ?? stringAttribute(kAXValueAttribute, from: element).map { ($0 as NSString).length }
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
