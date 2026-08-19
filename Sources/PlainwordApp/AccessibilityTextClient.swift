import AppKit
import ApplicationServices
import CoreGraphics
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
        "\(processIdentifier):\(capturedTextRange.location):\(documentUTF16Length):\(fullText.hashValue):\(context.applicationContext.hashValue):\(selectedRange.location):\(selectedRange.length)"
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
    private let maximumApplicationContextLength = 2_500
    private let maximumCompleteTextReadLength = 12_000
    private let maximumRangeWindowLength = 2_400
    private let maximumContextTraversalNodes = 240
    private let maximumContextTraversalDepth = 12
    private let maximumContextAncestorDepth = 14
    private let maximumContextCollectionDuration: CFTimeInterval = 0.12
    private let standardTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String
    ]
    private let readableContextRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXHeading"
    ]
    private let contextViewportRoles: Set<String> = [
        kAXScrollAreaRole as String,
        "AXWebArea",
        "AXDocument"
    ]

    private struct ContextNodeMetadata {
        let role: String?
        let frame: CGRect?
        let isHidden: Bool
        let isEditable: Bool
        let isProtected: Bool
    }

    private struct ContextAncestorLevel {
        let childOnFocusedPath: AXUIElement
        let parent: AXUIElement
        let metadata: ContextNodeMetadata
        let distance: Int
    }

    private struct CapturedTextState {
        let text: String
        let range: NSRange
        let documentUTF16Length: Int
        let selectedRange: CFRange
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

    func captureFocusedText(
        scope: TextEditExtractionScope = .sentence
    ) -> FocusedTextSnapshot? {
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
              !hasMultipleSelections(element),
              let textState = captureTextState(from: element, scope: scope) else {
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
        let rankedApplicationContext = readOnlyApplicationContext(
            around: element,
            excluding: [fullText, fieldContext.text, applicationName],
            targetUTF16Length: fieldContext.utf16Length
        )
        let context = fieldContext.withApplicationContext(
            [.init(kind: .sourceApplication, text: applicationName)]
                + rankedApplicationContext
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
        case .completion:
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
        case .completion:
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
               stringAttribute(kAXSelectedTextAttribute, from: element) == originalText {
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
        boolAttribute(NSAccessibility.Attribute.containsProtectedContent.rawValue, from: element)
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
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private func isWritableTextElement(_ element: AXUIElement) -> Bool {
        if isAttributeSettable(kAXValueAttribute, on: element) {
            return true
        }

        // Chromium/WebKit contenteditable roots commonly expose a writable selection
        // range but make AXSelectedText read-only. They are still safely editable via
        // the existing range-selection + keyboard-input replacement path. Requiring a
        // direct AXSelectedText write here prevented capture before that fallback ran.
        guard boolAttribute(kAXIsEditableAttribute, from: element),
              isAttributeSettable(kAXSelectedTextRangeAttribute, on: element) else {
            return false
        }
        return hasAttribute(kAXValueAttribute, on: element)
            || supportsParameterizedAttribute(
                kAXStringForRangeParameterizedAttribute,
                on: element
            )
    }

    private func hasAttribute(_ attribute: String, on element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names = names as? [String] else {
            return false
        }
        return names.contains(attribute)
    }

    private func supportsParameterizedAttribute(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let names = names as? [String] else {
            return false
        }
        return names.contains(attribute)
    }

    /// Collects typed, read-only context using explicit accessibility relationships
    /// first and nearby content only as a bounded fallback.
    private func readOnlyApplicationContext(
        around focusedElement: AXUIElement,
        excluding excludedTexts: [String],
        targetUTF16Length: Int
    ) -> [ReadOnlyContextFragment] {
        let collectionDeadline = CFAbsoluteTimeGetCurrent()
            + maximumContextCollectionDuration
        let contextBudget = applicationContextBudget(targetUTF16Length: targetUTF16Length)
        var candidates = directContextCandidates(
            around: focusedElement,
            deadline: collectionDeadline
        )
        var ancestorLevels: [ContextAncestorLevel] = []
        var currentElement = focusedElement
        for distance in 0..<maximumContextAncestorDepth {
            guard CFAbsoluteTimeGetCurrent() < collectionDeadline else { break }
            guard let parent = elementAttribute(kAXParentAttribute, from: currentElement) else {
                break
            }
            let metadata = contextNodeMetadata(parent)
            ancestorLevels.append(
                ContextAncestorLevel(
                    childOnFocusedPath: currentElement,
                    parent: parent,
                    metadata: metadata,
                    distance: distance
                )
            )
            if metadata.role == kAXWindowRole as String { break }
            currentElement = parent
        }

        for level in ancestorLevels where isDocumentContextRole(level.metadata.role) {
            guard CFAbsoluteTimeGetCurrent() < collectionDeadline else { break }
            if let title = stringAttribute(kAXTitleAttribute, from: level.parent) {
                candidates.append(
                    .init(
                        kind: .documentTitle,
                        text: title,
                        relevance: 850 - level.distance * 20,
                        readingOrder: -100 + level.distance
                    )
                )
            }
        }

        guard let focusedFrame = elementRect(focusedElement), focusedFrame != .zero else {
            return ReadOnlyContextRanker.select(
                from: candidates,
                excluding: excludedTexts,
                maximumUTF16Length: contextBudget,
                maximumFragments: 4,
                minimumRelevance: 300
            )
        }

        let windowFrame = ancestorLevels.first {
            $0.metadata.role == kAXWindowRole as String
        }?.metadata.frame
        let viewportFrame = contextViewportFrame(
            from: ancestorLevels,
            containing: focusedFrame
        ) ?? windowFrame
        let searchBounds = contextSearchBounds(
            around: focusedFrame,
            clippedTo: viewportFrame
        )
        var remainingNodes = maximumContextTraversalNodes
        var traversalOrder = 0
        var visitedElements: [AXUIElement] = [focusedElement]
        let traversalDeadline = collectionDeadline

        for level in ancestorLevels
        where remainingNodes > 0 && CFAbsoluteTimeGetCurrent() < traversalDeadline {
            for sibling in contextChildElements(of: level.parent)
            where !elementsAreEqual(sibling, level.childOnFocusedPath) {
                collectContextCandidates(
                    from: sibling,
                    focusedFrame: focusedFrame,
                    searchBounds: searchBounds,
                    ancestorDistance: level.distance,
                    depth: 0,
                    deadline: traversalDeadline,
                    remainingNodes: &remainingNodes,
                    traversalOrder: &traversalOrder,
                    visitedElements: &visitedElements,
                    candidates: &candidates
                )
            }
        }

        return ReadOnlyContextRanker.select(
            from: candidates,
            excluding: excludedTexts,
            maximumUTF16Length: contextBudget,
            maximumFragments: 6,
            minimumRelevance: 300
        )
    }

    private func directContextCandidates(
        around focusedElement: AXUIElement,
        deadline: CFAbsoluteTime
    ) -> [ReadOnlyContextCandidate] {
        let attributes = [
            kAXTitleAttribute as String,
            kAXPlaceholderValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXTitleUIElementAttribute as String,
            kAXLinkedUIElementsAttribute as String
        ]
        let values = multipleAttributeValues(attributes, from: focusedElement)
        var candidates: [ReadOnlyContextCandidate] = []

        func appendString(_ attribute: String, kind: ReadOnlyContextKind, relevance: Int) {
            guard let text = stringValue(values[attribute]) else { return }
            candidates.append(
                .init(kind: kind, text: text, relevance: relevance, readingOrder: 0)
            )
        }

        // AXTitle and AXDescription can both carry the accessible name depending
        // on the target framework. Keep them as field identity instead of
        // claiming a label/description distinction that the API cannot guarantee.
        appendString(kAXTitleAttribute as String, kind: .fieldIdentity, relevance: 970)
        appendString(
            kAXPlaceholderValueAttribute as String,
            kind: .fieldPlaceholder,
            relevance: 820
        )
        appendString(
            kAXDescriptionAttribute as String,
            kind: .fieldIdentity,
            relevance: 950
        )
        appendString(
            kAXHelpAttribute as String,
            kind: .fieldHelp,
            relevance: 310
        )

        if let titleElement = uiElementValue(values[kAXTitleUIElementAttribute as String]),
           !isProtected(titleElement),
           let title = readableText(from: titleElement) {
            candidates.append(
                .init(kind: .fieldLabel, text: title, relevance: 1_100, readingOrder: 0)
            )
        }

        for (index, linkedElement) in uiElementArray(
            values[kAXLinkedUIElementsAttribute as String]
        ).prefix(3).enumerated() {
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            if let candidate = validatedLinkedContextCandidate(
                from: linkedElement,
                around: focusedElement,
                readingOrder: index
            ) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func validatedLinkedContextCandidate(
        from linkedElement: AXUIElement,
        around focusedElement: AXUIElement,
        readingOrder: Int
    ) -> ReadOnlyContextCandidate? {
        let metadata = contextNodeMetadata(linkedElement)
        guard let role = metadata.role,
              readableContextRoles.contains(role),
              !metadata.isHidden,
              !metadata.isProtected,
              !metadata.isEditable,
              !readableContextElementIsWritable(role: role, element: linkedElement),
              linkedElementSharesWindow(linkedElement, with: focusedElement),
              let focusedFrame = elementRect(focusedElement),
              let linkedFrame = metadata.frame,
              isRelevantContextFrame(linkedFrame, to: focusedFrame),
              let text = readableText(from: linkedElement) else {
            return nil
        }
        return .init(
            kind: .relatedContent,
            text: text,
            relevance: 520 - readingOrder * 10,
            readingOrder: readingOrder
        )
    }

    private func linkedElementSharesWindow(
        _ linkedElement: AXUIElement,
        with focusedElement: AXUIElement
    ) -> Bool {
        guard let linkedWindow = elementAttribute(kAXWindowAttribute, from: linkedElement),
              let focusedWindow = elementAttribute(kAXWindowAttribute, from: focusedElement) else {
            // Some web accessibility nodes omit AXWindow. Geometry validation
            // still provides a conservative fallback in that case.
            return true
        }
        return elementsAreEqual(linkedWindow, focusedWindow)
    }

    private func collectContextCandidates(
        from element: AXUIElement,
        focusedFrame: CGRect,
        searchBounds: CGRect,
        ancestorDistance: Int,
        depth: Int,
        deadline: CFAbsoluteTime,
        remainingNodes: inout Int,
        traversalOrder: inout Int,
        visitedElements: inout [AXUIElement],
        candidates: inout [ReadOnlyContextCandidate]
    ) {
        guard remainingNodes > 0,
              depth <= maximumContextTraversalDepth,
              CFAbsoluteTimeGetCurrent() < deadline,
              !visitedElements.contains(where: { elementsAreEqual($0, element) }) else {
            return
        }
        visitedElements.append(element)
        remainingNodes -= 1

        let metadata = contextNodeMetadata(element)
        guard !metadata.isHidden, !metadata.isProtected else { return }
        if let frame = metadata.frame,
           !frame.intersects(searchBounds),
           !frame.contains(focusedFrame) {
            return
        }

        if let role = metadata.role,
           readableContextRoles.contains(role),
           !metadata.isEditable,
           !readableContextElementIsWritable(role: role, element: element),
           let text = readableText(from: element),
           let frame = metadata.frame,
           let candidate = nearbyContextCandidate(
                text: text,
                role: role,
                frame: frame,
                focusedFrame: focusedFrame,
                ancestorDistance: ancestorDistance,
                readingOrder: traversalOrder
           ) {
            candidates.append(candidate)
            traversalOrder += 1
            return
        }

        for child in contextChildElements(of: element) {
            collectContextCandidates(
                from: child,
                focusedFrame: focusedFrame,
                searchBounds: searchBounds,
                ancestorDistance: ancestorDistance,
                depth: depth + 1,
                deadline: deadline,
                remainingNodes: &remainingNodes,
                traversalOrder: &traversalOrder,
                visitedElements: &visitedElements,
                candidates: &candidates
            )
        }
    }

    private func readableText(from element: AXUIElement) -> String? {
        let attributes = [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String
        ]
        let values = multipleAttributeValues(attributes, from: element)
        for attribute in attributes {
            if let text = stringValue(values[attribute])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func nearbyContextCandidate(
        text: String,
        role: String,
        frame: CGRect,
        focusedFrame: CGRect,
        ancestorDistance: Int,
        readingOrder: Int
    ) -> ReadOnlyContextCandidate? {
        guard isRelevantContextFrame(frame, to: focusedFrame) else { return nil }

        let textLength = (text as NSString).length
        guard textLength >= 3 else { return nil }
        let horizontalOverlap = max(
            0,
            min(frame.maxX, focusedFrame.maxX) - max(frame.minX, focusedFrame.minX)
        )
        let overlapRatio = horizontalOverlap / max(1, min(frame.width, focusedFrame.width))
        let ancestorPenalty = min(160, ancestorDistance * 18)

        let verticallyAligned = frame.maxY > focusedFrame.minY
            && frame.minY < focusedFrame.maxY
        if verticallyAligned,
           frame.maxX <= focusedFrame.minX,
           focusedFrame.minX - frame.maxX <= 120,
           textLength <= 120 {
            return .init(
                kind: .fieldLabel,
                text: text,
                relevance: 820 - ancestorPenalty,
                readingOrder: readingOrder
            )
        }

        if frame.maxY <= focusedFrame.minY {
            let gap = focusedFrame.minY - frame.maxY
            guard gap <= 72, textLength <= 320 else { return nil }
            return .init(
                kind: .fieldDescription,
                text: text,
                relevance: 720 - ancestorPenalty - Int(gap),
                readingOrder: readingOrder
            )
        }

        if frame.minY >= focusedFrame.maxY - 4 {
            let gap = max(0, frame.minY - focusedFrame.maxY)
            var relevance = 690 - ancestorPenalty - Int(gap / 3)
            if overlapRatio >= 0.5 { relevance += 70 }
            if textLength >= 40 { relevance += 35 }
            if role == "AXHeading" { relevance += 80 }
            return .init(
                kind: role == "AXHeading" ? .documentTitle : .relatedPrecedingContent,
                text: text,
                relevance: relevance,
                readingOrder: readingOrder
            )
        }

        guard verticallyAligned, textLength <= 240 else { return nil }
        return .init(
            kind: textLength <= 120 ? .fieldDescription : .relatedContent,
            text: text,
            relevance: 560 - ancestorPenalty + (overlapRatio >= 0.5 ? 40 : 0),
            readingOrder: readingOrder
        )
    }

    private func readableContextElementIsWritable(
        role: String,
        element: AXUIElement
    ) -> Bool {
        guard role == kAXTextFieldRole as String
                || role == kAXTextAreaRole as String
                || role == kAXComboBoxRole as String else {
            return false
        }
        return isWritableTextElement(element)
    }

    private func applicationContextBudget(targetUTF16Length: Int) -> Int {
        let budget: Int
        switch targetUTF16Length {
        case ...120:
            budget = 2_000
        case ...400:
            budget = 1_500
        default:
            budget = 900
        }
        return min(maximumApplicationContextLength, budget)
    }

    private func contextSearchBounds(
        around focusedFrame: CGRect,
        clippedTo windowFrame: CGRect?
    ) -> CGRect {
        let horizontalMargin = min(180, max(96, focusedFrame.width * 0.2))
        var bounds = CGRect(
            x: focusedFrame.minX - horizontalMargin,
            y: focusedFrame.minY - 80,
            width: focusedFrame.width + horizontalMargin * 2,
            height: focusedFrame.height + 980
        )
        if let windowFrame, windowFrame != .zero {
            bounds = bounds.intersection(windowFrame)
        }
        return bounds
    }

    private func contextViewportFrame(
        from ancestorLevels: [ContextAncestorLevel],
        containing focusedFrame: CGRect
    ) -> CGRect? {
        ancestorLevels.lazy.compactMap { level -> CGRect? in
            guard let role = level.metadata.role,
                  self.contextViewportRoles.contains(role),
                  let frame = level.metadata.frame,
                  frame != .zero,
                  frame.intersects(focusedFrame) || frame.contains(focusedFrame) else {
                return nil
            }
            return frame
        }.first
    }

    private func isDocumentContextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == kAXWindowRole as String
            || role == "AXWebArea"
            || role == "AXDocument"
    }

    private func contextNodeMetadata(_ element: AXUIElement) -> ContextNodeMetadata {
        let attributes = [
            kAXRoleAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String,
            kAXHiddenAttribute as String,
            kAXIsEditableAttribute as String,
            NSAccessibility.Attribute.containsProtectedContent.rawValue
        ]
        let values = multipleAttributeValues(attributes, from: element)
        return ContextNodeMetadata(
            role: stringValue(values[kAXRoleAttribute as String]),
            frame: contextFrame(from: values),
            isHidden: boolValue(values[kAXHiddenAttribute as String]),
            isEditable: boolValue(values[kAXIsEditableAttribute as String]),
            isProtected: boolValue(
                values[NSAccessibility.Attribute.containsProtectedContent.rawValue]
            )
        )
    }

    private func contextFrame(from values: [String: Any]) -> CGRect? {
        guard let positionValue = axValue(values[kAXPositionAttribute as String]),
              let sizeValue = axValue(values[kAXSizeAttribute as String]) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return appKitRect(fromAccessibilityRect: CGRect(origin: position, size: size))
    }

    private func contextChildElements(of element: AXUIElement) -> [AXUIElement] {
        let navigationOrderAttribute = "AXChildrenInNavigationOrder"
        let attributes = [
            kAXContentsAttribute as String,
            navigationOrderAttribute,
            kAXVisibleChildrenAttribute as String
        ]
        let values = multipleAttributeValues(attributes, from: element)
        let contentChildren = uiElementArray(values[kAXContentsAttribute as String])
        let navigationOrder = uiElementArray(values[navigationOrderAttribute])
        let visibleChildren = uiElementArray(values[kAXVisibleChildrenAttribute as String])

        if !contentChildren.isEmpty {
            let visibleContent = visibleChildren.isEmpty
                ? contentChildren
                : contentChildren.filter { candidate in
                    visibleChildren.contains(where: { elementsAreEqual($0, candidate) })
                }
            let eligibleContent = visibleContent.isEmpty ? contentChildren : visibleContent
            if !navigationOrder.isEmpty {
                var orderedContent = navigationOrder.filter { candidate in
                    eligibleContent.contains(where: { elementsAreEqual($0, candidate) })
                }
                for child in eligibleContent
                where !orderedContent.contains(where: { elementsAreEqual($0, child) }) {
                    orderedContent.append(child)
                }
                if !orderedContent.isEmpty { return orderedContent }
            }
            return eligibleContent
        }

        if !navigationOrder.isEmpty, !visibleChildren.isEmpty {
            var orderedVisible = navigationOrder.filter { candidate in
                visibleChildren.contains(where: { elementsAreEqual($0, candidate) })
            }
            for child in visibleChildren
            where !orderedVisible.contains(where: { elementsAreEqual($0, child) }) {
                orderedVisible.append(child)
            }
            if !orderedVisible.isEmpty { return orderedVisible }
        }
        if !visibleChildren.isEmpty { return visibleChildren }
        if !navigationOrder.isEmpty { return navigationOrder }
        return uiElementArray(attributeValue(kAXChildrenAttribute, from: element))
    }

    private func isRelevantContextFrame(_ frame: CGRect, to focusedFrame: CGRect) -> Bool {
        guard frame != .zero,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let horizontalGap: CGFloat
        if frame.maxX < focusedFrame.minX {
            horizontalGap = focusedFrame.minX - frame.maxX
        } else if frame.minX > focusedFrame.maxX {
            horizontalGap = frame.minX - focusedFrame.maxX
        } else {
            horizontalGap = 0
        }
        guard horizontalGap <= min(180, max(96, focusedFrame.width * 0.2)) else {
            return false
        }

        if frame.maxY <= focusedFrame.minY {
            return focusedFrame.minY - frame.maxY <= 72
        }
        if frame.minY >= focusedFrame.maxY {
            return frame.minY - focusedFrame.maxY <= 900
        }
        return true
    }

    private func multipleAttributeValues(
        _ attributes: [String],
        from element: AXUIElement
    ) -> [String: Any] {
        for attempt in 0..<2 {
            var rawValues: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                element,
                attributes as CFArray,
                [],
                &rawValues
            )
            if result == .success, let values = rawValues as? [Any] {
                var mapped: [String: Any] = [:]
                for (attribute, value) in zip(attributes, values) {
                    if !(value is NSNull) {
                        mapped[attribute] = value
                    }
                }
                return mapped
            }
            guard result == .cannotComplete, attempt == 0 else { break }
        }

        var fallback: [String: Any] = [:]
        for attribute in attributes {
            if let value = attributeValue(attribute, from: element) {
                fallback[attribute] = value
            }
        }
        return fallback
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return (value as? NSAttributedString)?.string
    }

    private func boolValue(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private func axValue(_ value: Any?) -> AXValue? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(cfValue, to: AXValue.self)
    }

    private func uiElementValue(_ value: Any?) -> AXUIElement? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(cfValue, to: AXUIElement.self)
    }

    private func uiElementArray(_ value: Any?) -> [AXUIElement] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(uiElementValue)
    }

    private func elementsAreEqual(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        guard let value = attributeValue(attribute, from: element) else { return nil }
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func integerAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        (attributeValue(attribute, from: element) as? NSNumber)?.intValue
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        (attributeValue(attribute, from: element) as? NSNumber)?.boolValue ?? false
    }

    private func rangeAttribute(_ attribute: String, from element: AXUIElement) -> CFRange? {
        guard let value = attributeValue(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func rangeArrayAttribute(_ attribute: String, from element: AXUIElement) -> [CFRange] {
        guard let values = attributeValue(attribute, from: element) as? [Any] else {
            return []
        }
        return values.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
            let axValue = unsafeDowncast(cfValue, to: AXValue.self)
            guard AXValueGetType(axValue) == .cfRange else { return nil }
            var range = CFRange()
            return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
        }
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
        guard let value = attributeValue(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func attributeValue(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        for attempt in 0..<2 {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            )
            if result == .success {
                return value
            }
            guard result == .cannotComplete, attempt == 0 else { return nil }
        }
        return nil
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
        guard let positionValue = attributeValue(kAXPositionAttribute, from: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attributeValue(kAXSizeAttribute, from: element),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        let axPositionValue = unsafeDowncast(positionValue, to: AXValue.self)
        let axSizeValue = unsafeDowncast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(axPositionValue, .cgPoint, &position),
              AXValueGetValue(axSizeValue, .cgSize, &size) else {
            return nil
        }
        return appKitRect(fromAccessibilityRect: CGRect(origin: position, size: size))
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
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primaryScreen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
