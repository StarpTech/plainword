import CoreGraphics
import Foundation

/// Reads the writing above a field by asking the application what it drew there.
///
/// The traversal this runs ahead of has to find text by walking to it, and in web and
/// Electron interfaces the walk is the problem. A composer sits twenty levels inside
/// anonymous grouping nodes; most of them publish no frame, so nothing can be ruled out
/// by position; their children arrive in the order the markup was written rather than
/// the order the page reads; and a whole subtree can be reached only through an
/// attribute that this particular framework happens to answer. A budget spent that way
/// buys wrappers, and the message above the composer is never reached at all.
///
/// Hit testing asks the opposite question. Instead of *where is the text?* it asks
/// *what is at this point?*, which every toolkit can answer because it must answer it to
/// route a click — and answers with a leaf, skipping every wrapper between. Walking a
/// line of points up the column the caret sits in therefore costs a fixed number of
/// reads whatever the interface is made of, returns the text in the order it is read
/// because that is the order the points were visited, and reaches views that are not
/// among their parent's published children.
///
/// It sees only what is on screen, which is the honest limit of a question asked in
/// screen coordinates. Everything above this in the pipeline can read past the viewport;
/// this is what is left when none of them could.
public struct ScreenLadderSource: ContextSource {
    public static let sourceName = "screen-ladder"

    public let tier = ContextTier.screen
    public let name = ScreenLadderSource.sourceName

    /// How far apart the probes are. Below a line of body text, so no paragraph can fall
    /// between two rungs; above the point where a tall column would cost more probes
    /// than the whole ladder is worth.
    private let step: CGFloat = 22

    /// A ceiling for a very tall viewport. The shared budget usually bites first; this
    /// is what keeps a full-screen document from spending all of it here.
    private let maximumProbes = 48

    /// The tallest thing a probe may treat as one piece of writing.
    ///
    /// A hit test answers with whatever is drawn at the point, and in a web interface
    /// that is often a container rather than a line: a message row, but sometimes the
    /// whole thread's wrapper. A row is a paragraph and can be read as one; a wrapper is
    /// the page, and reading it would hand back everything on screen as a single
    /// fragment attributed to one position.
    private let maximumElementHeight: CGFloat = 200

    /// How much of a container's text is worth taking. Beyond this it is not a passage.
    private let maximumLiftedUTF16Length = 900

    public init() {}

    public func supports(_ target: ContextTarget) -> Bool {
        !target.need.sendsNothing
    }

    public func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate] {
        guard let focusedFrame = workspace.focusedFrame() else { return [] }

        let bounds = ReadOnlyContextGeometry.searchBounds(
            around: focusedFrame,
            clippedTo: workspace.clipFrame()
        )
        guard bounds.height > 0 else { return [] }

        // The caret's own column. Text that belongs to the same thread of writing is
        // laid out under it; a sidebar or a toolbar button is not.
        let column = focusedFrame.midX
        var candidates: [ReadOnlyContextCandidate] = []
        var visited: Set<ElementRef> = [workspace.target.element]
        var probes = 0
        var y = focusedFrame.maxY + step / 2

        while y <= bounds.maxY, probes < maximumProbes, !workspace.budget.isExhausted {
            probes += 1
            let found = probe(
                CGPoint(x: column, y: y),
                in: workspace,
                focusedFrame: focusedFrame,
                visited: &visited,
                into: &candidates
            )

            // Step past whatever was found rather than through it. A paragraph eight
            // lines tall would otherwise be hit eight times, and the probes that could
            // have reached the paragraph above it would be spent on the same element
            // being recognised and discarded.
            //
            // Only past something of a readable size, though. A probe that lands in the
            // gap between two messages is answered with the container holding both, and
            // skipping to the top of that would step over everything above the point —
            // which is the whole conversation this is climbing towards.
            if let frame = found?.frame,
               frame.maxY > y,
               frame.height <= maximumElementHeight {
                y = frame.maxY + step / 2
            } else {
                y += step
            }
        }

        // The caption under a field and the label beside it are not part of the writing
        // above the caret, but they are the two things a traversal would have found
        // nearby — and this source exists in the applications where that traversal
        // reaches nothing at all. Three fixed probes cover both bands.
        for point in nearbyPoints(around: focusedFrame) where !workspace.budget.isExhausted {
            _ = probe(
                point,
                in: workspace,
                focusedFrame: focusedFrame,
                visited: &visited,
                into: &candidates
            )
        }
        return candidates
    }

    /// One point, and whatever it turned out to be standing on.
    @discardableResult
    private func probe(
        _ point: CGPoint,
        in workspace: ContextWorkspace,
        focusedFrame: CGRect,
        visited: inout Set<ElementRef>,
        into candidates: inout [ReadOnlyContextCandidate]
    ) -> ElementFacts? {
        guard let element = workspace.elementAtPosition(point) else { return nil }
        guard visited.insert(element).inserted else { return nil }

        let facts = workspace.facts(of: element)
        if let candidate = candidate(
            for: element,
            facts: facts,
            in: workspace,
            focusedFrame: focusedFrame
        ) {
            candidates.append(candidate)
        }
        return facts
    }

    /// The words at a hit, however the host chose to publish them.
    ///
    /// The obvious case is a text element, which carries its own. The case that made
    /// this source necessary is the other one: Chromium answers a hit test with the
    /// group that draws the line, never with the text inside it, so a ladder that only
    /// read text elements would climb a whole conversation and come back with nothing.
    /// A recording of a Gmail thread did exactly that — eighteen probes, every one of
    /// them landing on an `AXGroup` or an `AXRow`, not one of them readable.
    ///
    /// Where the host publishes text markers, the rendered text of a container is one
    /// question with one answer, already in reading order. Where it does not, the words
    /// have to be gathered from just below the surface, which is where a row keeps them.
    private func text(
        of element: ElementRef,
        role: String,
        in workspace: ContextWorkspace
    ) -> String? {
        if AXRole.readableContext.contains(role),
           let own = workspace.readableText(of: element) {
            return own
        }

        let document = workspace.document()
        if let area = document.element,
           document.markerVocabulary.contains(AXName.textMarkerRangeForUIElement),
           document.markerVocabulary.contains(AXName.stringForTextMarkerRange),
           let range = workspace.parameterized(
            AXName.textMarkerRangeForUIElement,
            of: area,
            parameter: .element(element)
           ),
           let text = workspace.parameterized(
            AXName.stringForTextMarkerRange,
            of: area,
            parameter: range
           )?.stringValue {
            return trimmed(text)
        }

        return trimmed(lifted(from: element, in: workspace))
    }

    /// The readable text a shallow walk finds under a container.
    ///
    /// Bounded hard on both depth and count. This is a fallback for a host with no
    /// markers, and a source whose whole argument is that it costs a fixed amount
    /// cannot answer one probe with an unbounded traversal.
    private func lifted(from element: ElementRef, in workspace: ContextWorkspace) -> String {
        var collected: [String] = []
        var frontier: [(element: ElementRef, depth: Int)] = [(element, 0)]
        var examined = 0

        while !frontier.isEmpty, examined < 12, !workspace.budget.isExhausted {
            let node = frontier.removeFirst()
            guard node.depth < 3 else { continue }
            for child in workspace.childElements(of: node.element) {
                examined += 1
                guard examined <= 12 else { break }
                let facts = workspace.facts(of: child)
                guard !facts.isExcludedFromContext, !facts.isEditable else { continue }
                if let role = facts.role,
                   AXRole.readableContext.contains(role),
                   let text = workspace.readableText(of: child) {
                    collected.append(text)
                } else {
                    frontier.append((child, node.depth + 1))
                }
            }
        }
        return collected.joined(separator: " ")
    }

    private func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return nil }
        return String(trimmed.prefix(maximumLiftedUTF16Length))
    }

    /// The caption band below the field, and the label band to its left.
    private func nearbyPoints(around focusedFrame: CGRect) -> [CGPoint] {
        [
            CGPoint(x: focusedFrame.midX, y: focusedFrame.minY - step / 2),
            CGPoint(x: focusedFrame.midX, y: focusedFrame.minY - step * 1.5),
            CGPoint(
                x: focusedFrame.minX - ReadOnlyContextGeometry.maximumSideLabelGap / 3,
                y: focusedFrame.midY
            )
        ]
    }

    private func candidate(
        for element: ElementRef,
        facts: ElementFacts,
        in workspace: ContextWorkspace,
        focusedFrame: CGRect
    ) -> ReadOnlyContextCandidate? {
        guard !facts.isExcludedFromContext,
              let role = facts.role,
              !facts.isEditable,
              !workspace.isWritableTextElement(element, role: role),
              let frame = facts.frame,
              frame.height <= maximumElementHeight,
              let text = text(of: element, role: role, in: workspace) else {
            return nil
        }
        return ReadOnlyContextGeometry.candidate(
            text: text,
            isHeading: role == AXRole.heading,
            frame: frame,
            focusedFrame: focusedFrame,
            // Nothing was walked to reach this, so there is no ancestry to be penalised
            // for. A point either landed on the text or it did not.
            ancestorDistance: 0
        )?.with(provenance: provenance(.inferred))
    }
}
