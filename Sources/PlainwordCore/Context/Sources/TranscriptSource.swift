import Foundation

/// Reads the conversation above a composer from the list that holds it.
///
/// Where a chat or mail transcript is exposed as a table, outline, or list, the rows are
/// already the turns, already in order, and already narrowed to the ones on screen. That
/// is better than any of it can be reconstructed from position: a row knows it is a row,
/// while a rectangle only knows it is above something else.
public struct TranscriptSource: ContextSource {
    public static let sourceName = "transcript"

    public let tier = ContextTier.structure
    public let name = TranscriptSource.sourceName

    /// How many of the nearest turns to take. A conversation's relevance falls away
    /// quickly, and the ranker's own budget would drop the rest anyway.
    private let maximumRows = 12
    /// How deep to look inside a row for its words.
    private let maximumLiftDepth = 4
    private let maximumLiftNodes = 24

    public init() {}

    public func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate] {
        var roles = AXRole.transcriptContainer
        roles.formUnion(workspace.profile.additionalTranscriptRoles)
        guard let container = workspace.nearestAncestor(withRoleIn: roles) else {
            return []
        }

        let values = workspace.attributes(
            [AXName.visibleRows, AXName.rows],
            of: container.element
        )
        let rows = values[AXName.visibleRows]?.elementsValue.isEmpty == false
            ? values[AXName.visibleRows]!.elementsValue
            : values[AXName.rows]?.elementsValue ?? []
        guard !rows.isEmpty else { return [] }

        // The composer sits below the conversation, so the rows nearest it are the last
        // ones — and those are the turns being replied to.
        let nearest = Array(rows.suffix(maximumRows))
        var candidates: [ReadOnlyContextCandidate] = []
        for (index, row) in nearest.enumerated() {
            guard !workspace.budget.isExhausted else { break }
            let facts = workspace.facts(of: row)
            guard !facts.isExcludedFromContext else { continue }
            guard let text = text(of: row, in: workspace) else { continue }

            // Later rows are nearer the composer and matter more.
            let distanceFromComposer = nearest.count - index - 1
            candidates.append(
                .init(
                    kind: .relatedPrecedingContent,
                    text: text,
                    relevance: 800 - min(200, distanceFromComposer * 12),
                    readingOrder: ReadOnlyContextGeometry.metadataReadingOrder + index,
                    provenance: provenance(.stated)
                )
            )
        }
        return candidates
    }

    /// A row's own words, or its descendants' where the row is only a container.
    ///
    /// Rows carrying no text of their own are the common case in web and Electron
    /// transcripts, where the row is a layout wrapper and the message is two or three
    /// levels inside it.
    private func text(of row: ElementRef, in workspace: ContextWorkspace) -> String? {
        if let own = workspace.readableText(of: row), own.count > 2 {
            return own
        }
        var collected: [String] = []
        var frontier: [(element: ElementRef, depth: Int)] = [(row, 0)]
        var examined = 0

        while !frontier.isEmpty, examined < maximumLiftNodes {
            let node = frontier.removeFirst()
            guard node.depth < maximumLiftDepth, !workspace.budget.isExhausted else {
                continue
            }
            for child in workspace.childElements(of: node.element) {
                examined += 1
                guard examined <= maximumLiftNodes else { break }
                let facts = workspace.facts(of: child)
                guard !facts.isExcludedFromContext else { continue }
                if let role = facts.role,
                   AXRole.readableContext.contains(role),
                   !facts.isEditable,
                   let text = workspace.readableText(of: child),
                   text.count > 1 {
                    collected.append(text)
                } else {
                    frontier.append((child, node.depth + 1))
                }
            }
        }

        let joined = collected.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count > 2 ? joined : nil
    }
}
