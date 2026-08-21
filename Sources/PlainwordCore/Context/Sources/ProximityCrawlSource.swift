import CoreGraphics
import Foundation

/// Finds context by walking outward from the field and reading whatever sits near it.
///
/// This is the traversal Plainword has always used, kept intact and moved to the end of
/// the queue. Position is the weakest signal available — a recycled row reports a stale
/// rectangle, a hidden node often does not say it is hidden, and "above the caret"
/// describes the previous message and the window's toolbar equally well — so it is asked
/// last, and only for what the sources that read stated facts could not supply.
///
/// It also now spends what is left of a shared budget rather than an allowance of its
/// own, which in a browser is frequently nothing at all.
public struct ProximityCrawlSource: ContextSource {
    public static let sourceName = "proximity"

    public let tier = ContextTier.proximity
    public let name = ProximityCrawlSource.sourceName

    /// Counted from an ancestor, whose own children — the branches beside the focused
    /// field — are therefore at depth 1.
    private let maximumDepth = 13

    public init() {}

    private struct FrontierNode {
        let element: ElementRef
        let facts: ElementFacts
        /// How many levels above the focused field this node's subtree was entered from.
        let ancestorDistance: Int
        let depth: Int
        let priority: Double
        let sequence: Int
    }

    public func supports(_ target: ContextTarget) -> Bool {
        !target.need.sendsNothing
    }

    public func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate] {
        guard let focusedFrame = workspace.focusedFrame() else {
            // Without geometry there is nothing to rank by, and this source has nothing
            // else to go on.
            return []
        }

        let ancestry = workspace.ancestry()
        let searchBounds = ReadOnlyContextGeometry.searchBounds(
            around: focusedFrame,
            clippedTo: workspace.clipFrame()
        )

        var candidates: [ReadOnlyContextCandidate] = []
        var sequence = 0
        var frontier: [FrontierNode] = []

        // Everything on the path from the field up to the window is spoken for. Marking
        // it before any seeding means expanding an ancestor only ever yields the other
        // branches beside the field.
        var visited: Set<ElementRef> = [workspace.target.element]
        for level in ancestry {
            visited.insert(level.element)
            visited.insert(level.childOnFocusedPath)
        }

        // Seeding with the ancestors costs nothing: their facts were read on the way up.
        // Each contains the field and so scores a proximity of zero, and the tie-break on
        // ancestor distance expands the tightest container first — the shortest path to
        // whatever sits beside the field.
        for level in ancestry where !level.facts.isExcludedFromContext {
            frontier.append(
                FrontierNode(
                    element: level.element,
                    facts: level.facts,
                    ancestorDistance: level.distance,
                    depth: 0,
                    priority: 0,
                    sequence: sequence
                )
            )
            sequence += 1
        }

        while !frontier.isEmpty, !workspace.budget.isExhausted {
            var nearestIndex = 0
            for index in frontier.indices.dropFirst()
            where Self.isCloser(frontier[index], than: frontier[nearestIndex]) {
                nearestIndex = index
            }
            let node = frontier.remove(at: nearestIndex)

            if let candidate = readableCandidate(
                for: node,
                focusedFrame: focusedFrame,
                in: workspace
            ) {
                candidates.append(candidate)
                // Readable text is a leaf as far as context goes; below it are runs and
                // glyphs that would only repeat what was just captured.
                continue
            }

            for child in workspace.childElements(of: node.element) {
                admit(
                    child,
                    from: node,
                    focusedFrame: focusedFrame,
                    searchBounds: searchBounds,
                    in: workspace,
                    sequence: &sequence,
                    visited: &visited,
                    frontier: &frontier
                )
            }
        }
        return candidates
    }

    /// Nearest first, then the shallowest ancestry, then discovery order.
    private static func isCloser(_ lhs: FrontierNode, than rhs: FrontierNode) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.ancestorDistance != rhs.ancestorDistance {
            return lhs.ancestorDistance < rhs.ancestorDistance
        }
        return lhs.sequence < rhs.sequence
    }

    private func admit(
        _ element: ElementRef,
        from parent: FrontierNode,
        focusedFrame: CGRect,
        searchBounds: CGRect,
        in workspace: ContextWorkspace,
        sequence: inout Int,
        visited: inout Set<ElementRef>,
        frontier: inout [FrontierNode]
    ) {
        let depth = parent.depth + 1
        guard depth <= maximumDepth, !workspace.budget.isExhausted else { return }
        guard visited.insert(element).inserted else { return }

        let facts = workspace.facts(of: element)
        guard !facts.isExcludedFromContext else { return }

        let priority: Double
        if let frame = facts.frame {
            guard frame.intersects(searchBounds) || frame.contains(focusedFrame) else {
                return
            }
            priority = ReadOnlyContextGeometry.proximity(of: frame, to: focusedFrame)
        } else {
            // Frameless grouping nodes are everywhere in web content. Exploring them
            // where their parent sat keeps a whole subtree from being deferred behind
            // content that is further away.
            priority = parent.priority
        }

        frontier.append(
            FrontierNode(
                element: element,
                facts: facts,
                ancestorDistance: parent.ancestorDistance,
                depth: depth,
                priority: priority,
                sequence: sequence
            )
        )
        sequence += 1
    }

    private func readableCandidate(
        for node: FrontierNode,
        focusedFrame: CGRect,
        in workspace: ContextWorkspace
    ) -> ReadOnlyContextCandidate? {
        guard let role = node.facts.role,
              AXRole.readableContext.contains(role),
              !node.facts.isEditable,
              !workspace.isWritableTextElement(node.element, role: role),
              let frame = node.facts.frame,
              let text = workspace.readableText(of: node.element) else {
            return nil
        }
        return ReadOnlyContextGeometry.candidate(
            text: text,
            isHeading: role == AXRole.heading,
            frame: frame,
            focusedFrame: focusedFrame,
            ancestorDistance: node.ancestorDistance
        )?.with(provenance: provenance(.inferred))
    }

}
