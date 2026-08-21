import CoreGraphics
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
///
/// There are three ways to read the same passage here, tried in that order of
/// preference: arithmetic on character offsets, which costs the same five messages on
/// every page; stepping backwards paragraph by paragraph, for a document that will not
/// convert a position to an offset; and reading the enclosing content landmark whole,
/// for one that will not walk either.
public struct MarkerPassageSource: ContextSource {
    public static let sourceName = "marker-passage"

    public let tier = ContextTier.passage
    public let name = MarkerPassageSource.sourceName

    /// How far back to walk. Far enough for a conversation's recent turns or an
    /// article's last few paragraphs, short enough to stay near what is being written.
    private let paragraphsBack = 14

    /// Ceiling on the text taken from one read, before ranking trims it further.
    static let maximumPassageUTF16Length = 4_000

    /// How much more than the field a container has to hold before it counts as holding
    /// the writing around it. A couple of sentences: enough that a container wrapping
    /// the field and a send button is not mistaken for the conversation above it.
    static let minimumSurroundingUTF16Length = 200

    /// Above this, a document is declined rather than read. A reference page can run to
    /// hundreds of thousands of characters, and none of it past the first few thousand
    /// would survive ranking anyway.
    private let maximumDocumentUTF16Length = 120_000

    public init() {}

    public func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate] {
        let document = workspace.document()
        guard let area = document.element else { return [] }
        let vocabulary = document.markerVocabulary
        // Only what every engine that implements markers at all provides. An earlier
        // version also demanded `AXStartTextMarkerForTextMarkerRange`, which WebKit has
        // and Chromium does not — so in Chrome this source returned before asking a
        // single question, and the traversal was left to find the page by itself.
        guard vocabulary.contains(AXName.stringForTextMarkerRange),
              vocabulary.contains(AXName.textMarkerRangeForUIElement) else {
            return []
        }

        // Preferred by a wide margin, and the only path whose cost does not depend on
        // what the page happens to contain. It ends exactly where the field begins, so
        // none of the author's own writing is in it and none has to be cut back out.
        if let passage = indexedTextBeforeField(
            in: workspace,
            area: area,
            document: document
        ) {
            return candidates(from: passage)
        }

        // Failing that: the paragraphs immediately above the field. Reading the whole
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

        guard let passage = Self.passage(
            before: fieldText,
            in: documentText,
            maximumUTF16Length: requestedLength(for: workspace)
        ) else {
            return []
        }
        return candidates(from: passage)
    }

    private func candidates(from passage: String) -> [ReadOnlyContextCandidate] {
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return [] }
        return [
            .init(
                kind: .relatedPrecedingContent,
                text: String(trimmed.suffix(Self.maximumPassageUTF16Length)),
                relevance: 900,
                // Position on screen had no part in finding this, so it presents in the
                // band reserved for context that came from a stated relationship.
                readingOrder: ReadOnlyContextGeometry.metadataReadingOrder,
                provenance: provenance(.stated)
            )
        ]
    }

    /// The writing immediately before the field, taken by character offset.
    ///
    /// A document that can convert a position to an index and an index back to a
    /// position is addressable, and both engines can. That changes what this source is
    /// able to promise. Stepping backwards a paragraph at a time costs one blocking
    /// message per step — fourteen of them, in sequence, inside the pause between a
    /// keystroke and a popover — and hands back however much fourteen paragraphs happens
    /// to be, which is forty characters in a chat window and twenty thousand on a wiki.
    /// Arithmetic on an index costs four messages whatever the page is, and returns the
    /// number of characters the request actually asked for.
    ///
    /// The anchor differs by engine because only one of them will take a range apart.
    private func indexedTextBeforeField(
        in workspace: ContextWorkspace,
        area: ElementRef,
        document: ContextWorkspace.DocumentFacts
    ) -> String? {
        guard document.supportsIndexArithmetic,
              let anchor = anchorMarker(in: workspace, area: area, document: document),
              let anchorIndex = workspace.parameterized(
                AXName.indexForTextMarker,
                of: area,
                parameter: .opaque(anchor)
              )?.intValue,
              anchorIndex > 0 else {
            return nil
        }

        let wanted = min(anchorIndex, requestedLength(for: workspace))
        guard let start = workspace.parameterized(
            AXName.textMarkerForIndex,
            of: area,
            parameter: .number(anchorIndex - wanted)
        )?.opaqueValue,
        start != anchor,
        let range = workspace.parameterized(
            AXName.textMarkerRangeForUnorderedTextMarkers,
            of: area,
            parameter: .opaques([start, anchor])
        ) else {
            return nil
        }
        return workspace.parameterized(
            AXName.stringForTextMarkerRange,
            of: area,
            parameter: range
        )?.stringValue
    }

    /// Where the field begins, as a position in the document that contains it.
    ///
    /// Three ways to ask, tried in order, because no single one of them is answered
    /// everywhere. WebKit will hand back the endpoints of the selected range, which is
    /// the caret's own position and so survives a field that is scrolled or partly
    /// covered. Chromium publishes no endpoint accessor and has to be asked through
    /// geometry — and a recording of a Gmail reply showed it declining the rectangle
    /// form while still listing it, so the point form is asked first. A point is the
    /// less ambiguous question in any case: a rectangle spanning several lines has more
    /// than one plausible answer, while a position inside the first line has one.
    private func anchorMarker(
        in workspace: ContextWorkspace,
        area: ElementRef,
        document: ContextWorkspace.DocumentFacts
    ) -> OpaqueRef? {
        let vocabulary = document.markerVocabulary

        if vocabulary.contains(AXName.startTextMarkerForTextMarkerRange),
           let selection = workspace.attribute(AXName.selectedTextMarkerRange, of: area),
           let start = workspace.parameterized(
            AXName.startTextMarkerForTextMarkerRange,
            of: area,
            parameter: selection
           )?.opaqueValue {
            return start
        }

        guard let frame = workspace.focusedFrame() else { return nil }

        if vocabulary.contains(AXName.textMarkerForPosition),
           let start = workspace.parameterized(
            AXName.textMarkerForPosition,
            of: area,
            // Just inside the field's top-left corner rather than on it: a point on the
            // boundary belongs as much to whatever is drawn above.
            parameter: .point(CGPoint(x: frame.minX + 2, y: frame.maxY - 2))
           )?.opaqueValue {
            return start
        }

        guard vocabulary.contains(AXName.startTextMarkerForBounds) else { return nil }
        return workspace.parameterized(
            AXName.startTextMarkerForBounds,
            of: area,
            parameter: .rect(frame)
        )?.opaqueValue
    }

    /// How much to take, from what the request is for.
    ///
    /// Twice the stated need rather than exactly it. Ranking narrows the passage again
    /// against the words actually being edited, and it can only choose from what was
    /// brought back; reading precisely the budget would leave it nothing to choose
    /// between. The ceiling is what one read is allowed to cost regardless.
    private func requestedLength(for workspace: ContextWorkspace) -> Int {
        let need = workspace.profile.need(for: workspace.target.targetKind)
        return min(Self.maximumPassageUTF16Length, max(600, need.leading.maximumUTF16Length * 2))
    }

    /// The smallest container around the field that holds more writing than the field.
    ///
    /// Choosing this well is most of the quality of a passage, and choosing it by name
    /// alone does not work. Two recordings of the same Gmail reply showed both failures.
    /// The nearest landmark was the composer's own `AXLandmarkRegion`, so reading
    /// "within the content" collapsed to reading the field the author was already
    /// writing in. The nearest landmark that was not — the page's `AXLandmarkMain` —
    /// held the entire mailbox: twenty thousand characters of other people's messages,
    /// of which the thread being replied to was the last four hundred, so the passage
    /// nearest the caret came out as somebody's parking receipt.
    ///
    /// Exactly the right container sat between those two, an `AXList` holding the
    /// thread, and what distinguishes it from both is not its name but its size. So the
    /// walk goes outward from the field and stops at the first container holding
    /// meaningfully more writing than the field does. Two reads settle each candidate,
    /// and erring inward is much the cheaper mistake: a container slightly too small
    /// costs a sentence of context, one too large costs a passage about parking.
    private func contentRoot(in workspace: ContextWorkspace, area: ElementRef) -> ElementRef {
        guard workspace.document().markerVocabulary
            .contains(AXName.lengthForTextMarkerRange) else {
            return namedContentRoot(in: workspace, area: area)
        }

        let fieldLength = length(of: workspace.target.element, in: workspace, area: area) ?? 0
        let wanted = fieldLength + Self.minimumSurroundingUTF16Length

        let modal = workspace.enclosingModal()?.element

        for level in workspace.ancestry() {
            guard !workspace.budget.isExhausted else { break }
            // Navigation, banners and complementary regions can hold plenty of text and
            // pass a size test on link labels alone. They are already excluded from
            // being read; they have to be excluded from being read *within*, too.
            if !level.facts.isExcludedFromContext,
               isContentContainer(level.facts),
               let length = length(of: level.element, in: workspace, area: area),
               length >= wanted,
               length <= maximumDocumentUTF16Length {
                return level.element
            }
            // A dialog is where the walk stops whether or not it qualified. Writing a
            // post over a feed, or a message over an inbox, is not writing about them,
            // and continuing outward is how the feed became the context.
            if level.element == modal { return level.element }
            // Reached the document without finding one: there is nothing wider to try.
            if level.element == area { break }
        }
        return modal ?? area
    }

    /// Whether a container is the kind that holds writing, by role or by the page's own
    /// declaration. The size test decides between them; this decides what to weigh.
    private func isContentContainer(_ facts: ElementFacts) -> Bool {
        if let role = facts.role, AXRole.contentContainer.contains(role) { return true }
        if let subrole = facts.subrole, AXRole.contentLandmarks.contains(subrole) {
            return true
        }
        return false
    }

    private func length(
        of element: ElementRef,
        in workspace: ContextWorkspace,
        area: ElementRef
    ) -> Int? {
        guard let range = workspace.parameterized(
            AXName.textMarkerRangeForUIElement,
            of: area,
            parameter: .element(element)
        ) else {
            return nil
        }
        return workspace.parameterized(
            AXName.lengthForTextMarkerRange,
            of: area,
            parameter: range
        )?.intValue
    }

    /// The older rule, for a document that will not say how long a range is: the nearest
    /// thing the page itself calls content.
    private func namedContentRoot(
        in workspace: ContextWorkspace,
        area: ElementRef
    ) -> ElementRef {
        for level in workspace.ancestry() {
            if let subrole = level.facts.subrole,
               AXRole.contentLandmarks.contains(subrole) {
                return level.element
            }
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

    /// The writing that precedes the field, located inside a whole-document read.
    ///
    /// This path exists for a document that will not say where its own field is, and the
    /// question it has to answer is *where in this text is the caret*. Taking the end of
    /// the document instead — which is what this used to do — is right only when the
    /// composer is the last thing on the page, and a recording of a Gmail reply showed
    /// what it costs when it is not: the read ran to the end of the mailbox and the
    /// context attached to a reply about a job interview was somebody's parking receipt.
    ///
    /// So the field's own text is what locates it, and if it cannot be found the answer
    /// is nothing at all. A source that cannot say where the caret is has not earned the
    /// right to guess: wrong context is worse than none, because none leaves the
    /// remaining sources free to answer and a confident four thousand characters does
    /// not — it satisfies the need and stops the run.
    ///
    /// Matching is done on normalised text because the two readings genuinely differ. A
    /// rich editor reports non-breaking spaces where it renders ordinary ones, drops the
    /// newlines it draws, and leaves object-replacement characters where images were, so
    /// an exact comparison fails on writing that is plainly the same. The passage is
    /// returned normalised too, which loses nothing: it is prose being handed to a
    /// language model, not a document being reconstructed.
    static func passage(
        before fieldText: String,
        in documentText: String,
        maximumUTF16Length: Int
    ) -> String? {
        let document = normalised(documentText)
        let field = normalised(fieldText)
        guard !document.isEmpty else { return nil }

        if let found = locate(field, in: document) {
            let before = String(document[document.startIndex..<found])
            return String(before.suffix(maximumUTF16Length))
        }

        // Not found, so where the caret sits in this text is unknown. Its end is still a
        // safe answer when the read is short enough to be about the field's surroundings
        // in the first place — a comment box under an article is at the end of it — and
        // is never a safe answer for a read that spans a whole mailbox.
        guard document.count <= min(
            Self.maximumPassageUTF16Length,
            maximumUTF16Length * 2
        ) else {
            return nil
        }
        return String(document.suffix(maximumUTF16Length))
    }

    /// Where the field's text begins, matched on progressively shorter openings of it
    /// because a rich editor's reading of its own contents diverges further the more of
    /// it you take. The floor is long enough that a match is still evidence.
    private static func locate(_ field: String, in document: String) -> String.Index? {
        guard !field.isEmpty else { return nil }
        var candidate = field
        while true {
            if let found = document.range(of: candidate, options: .backwards) {
                return found.lowerBound
            }
            guard candidate.count > 16 else { return nil }
            candidate = String(candidate.prefix(max(16, candidate.count / 2)))
        }
    }

    /// One reading of a piece of text that both a page and a field can be compared by.
    static func normalised(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character == "\u{FFFC}" { continue }
            if character.isWhitespace || character == "\u{00A0}" {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
        }
        return result
    }
}
