import Foundation

/// Reads the document above the caret through the text-marker API.
///
/// This is the one source that gets a browser or an Electron application to hand over
/// its writing directly. A marker is a position in the rendered document; two of them
/// make a range, and a range can be asked for its text. So the conversation above a
/// composer, or the article above a comment box, arrives in reading order in a handful
/// of calls — where a traversal has to find the same words by walking wrappers and
/// guessing from rectangles which of them belong together.
///
/// Two things make it safe to lean on. The marker vocabulary differs between WebKit and
/// Chromium and asking for an absent attribute costs a full messaging timeout, so the
/// element is probed once and the answer remembered. And every marker used here was
/// vended by the application itself: nothing constructs one, which is what keeps this
/// clear of the private functions that creating markers would need.
public struct MarkerPassageSource: ContextSource {
    public static let sourceName = "marker-passage"

    public let tier = ContextTier.passage
    public let name = MarkerPassageSource.sourceName

    /// How far back to walk. Far enough for a conversation's recent turns or an
    /// article's last few paragraphs, short enough to stay near what is being written.
    private let paragraphsBack = 14

    /// Ceiling on the text taken from one read, before ranking trims it further.
    private let maximumPassageUTF16Length = 4_000

    /// Above this, a document is declined rather than read. A reference page can run to
    /// hundreds of thousands of characters, and none of it past the first few thousand
    /// would survive ranking anyway.
    private let maximumDocumentUTF16Length = 120_000

    public init() {}

    public func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate] {
        guard let area = documentElement(in: workspace) else { return [] }
        let vocabulary = workspace.parameterizedAttributeNames(of: area)
        // Only what every engine that implements markers at all provides. An earlier
        // version also demanded `AXStartTextMarkerForTextMarkerRange`, which WebKit has
        // and Chromium does not — so in Chrome this source returned before asking a
        // single question, and the traversal was left to find the page by itself.
        guard vocabulary.contains(AXName.stringForTextMarkerRange),
              vocabulary.contains(AXName.textMarkerRangeForUIElement) else {
            return []
        }

        // Preferred: the paragraphs immediately above the field. Reading the whole
        // document instead works, but on a media-heavy page most of what comes back is
        // advertising and player controls — real text, from nowhere near the caret.
        let documentText = textBeforeField(in: workspace, area: area, vocabulary: vocabulary)
            ?? text(
                ofElement: contentRoot(in: workspace, area: area),
                in: workspace,
                area: area,
                vocabulary: vocabulary
            )
        guard let documentText else { return [] }

        // The author's own words inside the field always travel with a request, while
        // text read from the interface is theirs to switch off per application. One read
        // spans both, so it is cut at that boundary before anything downstream sees it.
        let fieldText = text(
            ofElement: workspace.target.element,
            in: workspace,
            area: area,
            vocabulary: vocabulary
        ) ?? workspace.target.capturedText
        let outside = Self.removingFieldText(fieldText, from: documentText)

        let trimmed = outside.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return [] }

        return [
            .init(
                kind: .relatedPrecedingContent,
                text: String(trimmed.suffix(maximumPassageUTF16Length)),
                relevance: 900,
                // Position on screen had no part in finding this, so it presents in the
                // band reserved for context that came from a stated relationship.
                readingOrder: ReadOnlyContextGeometry.metadataReadingOrder,
                provenance: provenance(.stated)
            )
        ]
    }

    /// The smallest container holding the field that the page calls content.
    ///
    /// A document's text is not all of one kind: an article sits among advertising,
    /// player controls, consent banners and navigation, and all of it is equally real
    /// text at equally real positions. Nothing about the words separates them — but the
    /// page has already said which is which, through the landmarks it publishes, and
    /// that statement costs nothing to read because the ancestry is walked anyway.
    ///
    /// Falls back to the document itself, which is the honest answer for a page that
    /// declares no structure at all.
    private func contentRoot(in workspace: ContextWorkspace, area: ElementRef) -> ElementRef {
        for level in workspace.ancestry() {
            if let subrole = level.facts.subrole,
               AXRole.contentLandmarks.contains(subrole) {
                return level.element
            }
            // Reached the document without finding one: there is nothing narrower.
            if level.element == area { break }
        }
        return area
    }

    /// The paragraphs immediately before the focused field.
    ///
    /// Chromium publishes no way to take an endpoint marker off a range, but it will
    /// answer with a marker for a *rectangle* — and the field's own frame is already
    /// known. From there the paragraph accessors walk backwards through the document,
    /// which bounds the read to what is near the caret instead of to the page.
    private func textBeforeField(
        in workspace: ContextWorkspace,
        area: ElementRef,
        vocabulary: Set<String>
    ) -> String? {
        guard vocabulary.contains(AXName.startTextMarkerForBounds),
              vocabulary.contains(AXName.previousParagraphStartTextMarkerForTextMarker),
              vocabulary.contains(AXName.textMarkerRangeForUnorderedTextMarkers),
              let frame = workspace.focusedFrame(),
              let fieldStart = workspace.parameterized(
                AXName.startTextMarkerForBounds,
                of: area,
                parameter: .rect(frame)
              )?.opaqueValue else {
            return nil
        }

        var marker = fieldStart
        for _ in 0..<paragraphsBack {
            guard !workspace.budget.isExhausted,
                  let previous = workspace.parameterized(
                    AXName.previousParagraphStartTextMarkerForTextMarker,
                    of: area,
                    parameter: .opaque(marker)
                  )?.opaqueValue,
                  previous != marker else {
                break
            }
            marker = previous
        }
        // Never moved: the field is at the top of the document and there is nothing
        // above it to read.
        guard marker != fieldStart,
              let range = workspace.parameterized(
                AXName.textMarkerRangeForUnorderedTextMarkers,
                of: area,
                parameter: .opaques([marker, fieldStart])
              ) else {
            return nil
        }
        return workspace.parameterized(
            AXName.stringForTextMarkerRange,
            of: area,
            parameter: range
        )?.stringValue
    }

    /// The rendered text of one element, read through the document that contains it.
    ///
    /// `AXTextMarkerRangeForUIElement` is the one call both engines agree on for turning
    /// an element into a span, and it needs no endpoint markers to be extracted from it —
    /// which is what makes this work in Chromium, where those accessors do not exist.
    private func text(
        ofElement element: ElementRef,
        in workspace: ContextWorkspace,
        area: ElementRef,
        vocabulary: Set<String>
    ) -> String? {
        guard let range = workspace.parameterized(
            AXName.textMarkerRangeForUIElement,
            of: area,
            parameter: .element(element)
        ) else {
            return nil
        }

        // A long article would answer with a string far larger than any of it could be
        // used, at a cost paid inside the author's own pause. Asking how long it is
        // first is one call and lets an outsized document be declined rather than read.
        if vocabulary.contains(AXName.lengthForTextMarkerRange),
           let length = workspace.parameterized(
            AXName.lengthForTextMarkerRange,
            of: area,
            parameter: range
           )?.intValue,
           length > maximumDocumentUTF16Length {
            return nil
        }

        return workspace.parameterized(
            AXName.stringForTextMarkerRange,
            of: area,
            parameter: range
        )?.stringValue
    }

    // MARK: - Steps

    /// The element that answers marker questions: the enclosing web area, or the focused
    /// element itself when it is one.
    private func documentElement(in workspace: ContextWorkspace) -> ElementRef? {
        if workspace.facts(of: workspace.target.element).role == AXRole.webArea {
            return workspace.target.element
        }
        return workspace.nearestAncestor(
            withRoleIn: [AXRole.webArea, AXRole.document]
        )?.element
    }

    /// Drops the longest suffix of the read that the field's own text accounts for.
    static func removingFieldText(_ fieldText: String, from wholeText: String) -> String {
        let field = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !field.isEmpty else { return wholeText }
        if let found = wholeText.range(of: field, options: .backwards) {
            return String(wholeText[wholeText.startIndex..<found.lowerBound])
        }
        // A rich editor reports its text with different whitespace than it renders, so
        // an exact match often fails. Fall back to the longest matching prefix of the
        // field text, which still ends the passage before the author's own writing.
        var candidate = field
        while candidate.count > 24 {
            candidate = String(candidate.prefix(candidate.count / 2))
            if let found = wholeText.range(of: candidate, options: .backwards) {
                return String(wholeText[wholeText.startIndex..<found.lowerBound])
            }
        }
        return wholeText
    }
}
