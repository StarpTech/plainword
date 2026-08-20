import Foundation

public enum ReadOnlyContextKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case sourceApplication
    case fieldLabel
    case fieldIdentity
    case fieldPlaceholder
    case fieldDescription
    case fieldHelp
    case documentTitle
    case relatedPrecedingContent
    case relatedContent

    public var promptTag: String {
        switch self {
        case .sourceApplication:
            "source_application"
        case .fieldLabel:
            "field_label"
        case .fieldIdentity:
            "field_identity"
        case .fieldPlaceholder:
            "field_placeholder"
        case .fieldDescription:
            "field_description"
        case .fieldHelp:
            "field_help"
        case .documentTitle:
            "document_title"
        case .relatedPrecedingContent:
            "related_preceding_content"
        case .relatedContent:
            "related_application_content"
        }
    }

    fileprivate var presentationOrder: Int {
        switch self {
        case .sourceApplication: 0
        case .fieldLabel: 1
        case .fieldIdentity: 2
        case .fieldPlaceholder: 3
        case .fieldDescription: 4
        case .fieldHelp: 5
        case .documentTitle: 6
        case .relatedPrecedingContent: 7
        case .relatedContent: 8
        }
    }

    var keepsNearestSuffixWhenTruncated: Bool {
        self == .relatedPrecedingContent
    }

    /// Whether a run of fragments of this kind reads as one continuous passage. When it
    /// does, dropping a fragment from the middle silently joins two pieces of text that
    /// were never adjacent, so the omission has to be marked.
    fileprivate var contiguityMatters: Bool {
        self == .relatedPrecedingContent
    }

    fileprivate var maximumFragmentUTF16Length: Int {
        switch self {
        case .sourceApplication, .fieldLabel, .fieldIdentity, .fieldPlaceholder:
            160
        case .fieldDescription, .fieldHelp:
            320
        case .documentTitle:
            240
        case .relatedPrecedingContent, .relatedContent:
            900
        }
    }
}

public struct ReadOnlyContextFragment: Equatable, Hashable, Sendable {
    public let kind: ReadOnlyContextKind
    public let text: String
    /// Which source found this, and whether the application stated it or Plainword
    /// inferred it. Absent for a fragment built by hand rather than harvested.
    public let provenance: ContextProvenance?

    public init(
        kind: ReadOnlyContextKind,
        text: String,
        provenance: ContextProvenance? = nil
    ) {
        self.kind = kind
        self.text = text
        self.provenance = provenance
    }

    /// Identity is the kind and the text, never where they were found. Two fragments
    /// carrying the same words are the same context whichever source turned them up,
    /// and the suggestion cache keys on that — so a fragment that arrives from the
    /// transcript this time and the traversal the next must not read as a change.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(text)
    }
}

public struct ReadOnlyContextCandidate: Equatable, Sendable {
    public let kind: ReadOnlyContextKind
    public let text: String
    public let relevance: Int
    public let readingOrder: Int
    public let provenance: ContextProvenance?

    public init(
        kind: ReadOnlyContextKind,
        text: String,
        relevance: Int,
        readingOrder: Int,
        provenance: ContextProvenance? = nil
    ) {
        self.kind = kind
        self.text = text
        self.relevance = relevance
        self.readingOrder = readingOrder
        self.provenance = provenance
    }

    public func with(provenance: ContextProvenance) -> ReadOnlyContextCandidate {
        .init(
            kind: kind,
            text: text,
            relevance: relevance,
            readingOrder: readingOrder,
            provenance: provenance
        )
    }
}

public enum ReadOnlyContextRanker {
    public static func select(
        from candidates: [ReadOnlyContextCandidate],
        excluding excludedTexts: [String] = [],
        relatedTo targetText: String = "",
        maximumUTF16Length: Int,
        maximumFragments: Int = 8,
        minimumRelevance: Int = 300
    ) -> [ReadOnlyContextFragment] {
        guard maximumUTF16Length > 0, maximumFragments > 0 else { return [] }

        let excluded = excludedTexts.compactMap(normalized)
        let normalizedCandidates = candidates.enumerated().compactMap {
            index, candidate -> RankedCandidate? in
            guard let text = normalized(candidate.text),
                  !ContextRelevance.isNoise(text),
                  !substantiallyOverlaps(text, anyOf: excluded) else {
                return nil
            }
            let score = candidate.relevance
                + ContextRelevance.lexicalBoost(for: text, relatedTo: targetText)
            guard score >= minimumRelevance else { return nil }
            return RankedCandidate(
                candidate: candidate,
                text: text,
                score: score,
                insertionOrder: index
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            // A fact the application published outranks one read off the screen, whatever
            // the geometry made of them.
            let lhsConfidence = lhs.candidate.provenance?.confidence ?? .inferred
            let rhsConfidence = rhs.candidate.provenance?.confidence ?? .inferred
            if lhsConfidence != rhsConfidence {
                return lhsConfidence > rhsConfidence
            }
            return lhs.insertionOrder < rhs.insertionOrder
        }
        var seen: Set<String> = []
        let ranked = normalizedCandidates.filter { seen.insert($0.text).inserted }

        var selected: [RankedCandidate] = []
        var remainingLength = maximumUTF16Length
        for rankedCandidate in ranked where selected.count < maximumFragments {
            let separatorLength = selected.isEmpty ? 0 : 1
            let availableLength = min(
                remainingLength - separatorLength,
                rankedCandidate.candidate.kind.maximumFragmentUTF16Length
            )
            guard availableLength > 0 else { break }

            let text: String
            if (rankedCandidate.text as NSString).length <= availableLength {
                text = rankedCandidate.text
            } else {
                text = truncated(
                    rankedCandidate.text,
                    maximumUTF16Length: availableLength,
                    keepingSuffix: rankedCandidate.candidate.kind.keepsNearestSuffixWhenTruncated
                )
            }
            guard !text.isEmpty else { continue }

            if selected.contains(where: { substantiallyOverlaps(text, anyOf: [$0.text]) }) {
                continue
            }
            selected.append(
                RankedCandidate(
                    candidate: rankedCandidate.candidate,
                    text: text,
                    score: rankedCandidate.score,
                    insertionOrder: rankedCandidate.insertionOrder
                )
            )
            remainingLength -= (text as NSString).length + separatorLength
        }

        let presented = selected.sorted { lhs, rhs in
            let lhsKind = lhs.candidate.kind.presentationOrder
            let rhsKind = rhs.candidate.kind.presentationOrder
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            if lhs.candidate.readingOrder != rhs.candidate.readingOrder {
                return lhs.candidate.readingOrder < rhs.candidate.readingOrder
            }
            return lhs.insertionOrder < rhs.insertionOrder
        }
        return markingOmissions(in: presented, drawnFrom: ranked)
    }

    /// Marker for a passage that was ranked out from between two selected fragments.
    /// Without it the two read as consecutive, which invents an adjacency that the
    /// source never had.
    public static let elisionMarker = "[…]"

    /// Prefixes the marker to any fragment that a person would read as continuing the
    /// previous one when something was dropped in between.
    ///
    /// Markers are added after the length budget has been spent, so a selection can
    /// exceed `maximumUTF16Length` by at most `maximumFragments` markers.
    private static func markingOmissions(
        in presented: [RankedCandidate],
        drawnFrom ranked: [RankedCandidate]
    ) -> [ReadOnlyContextFragment] {
        let selectedOrders = Set(presented.map(\.insertionOrder))
        return presented.enumerated().map { index, item in
            guard index > 0 else {
                return ReadOnlyContextFragment(
                    kind: item.candidate.kind,
                    text: item.text,
                    provenance: item.candidate.provenance
                )
            }
            let previous = presented[index - 1]
            let kind = item.candidate.kind
            guard kind.contiguityMatters, previous.candidate.kind == kind else {
                return ReadOnlyContextFragment(
                    kind: kind,
                    text: item.text,
                    provenance: item.candidate.provenance
                )
            }
            let lowerBound = min(previous.candidate.readingOrder, item.candidate.readingOrder)
            let upperBound = max(previous.candidate.readingOrder, item.candidate.readingOrder)
            let omittedContentExists = ranked.contains { other in
                other.candidate.kind == kind
                    && !selectedOrders.contains(other.insertionOrder)
                    && other.candidate.readingOrder > lowerBound
                    && other.candidate.readingOrder < upperBound
            }
            return ReadOnlyContextFragment(
                kind: kind,
                text: omittedContentExists ? "\(elisionMarker) \(item.text)" : item.text,
                provenance: item.candidate.provenance
            )
        }
    }

    public static func plainText(from fragments: [ReadOnlyContextFragment]) -> String {
        fragments.map(\.text).joined(separator: "\n")
    }

    private struct RankedCandidate {
        let candidate: ReadOnlyContextCandidate
        let text: String
        /// The candidate's own relevance plus whatever its wording earned it.
        let score: Int
        let insertionOrder: Int
    }

    /// Stand-ins for things that are not text at all. A page's images, videos, and
    /// embedded objects each leave one behind in a marker read, and a media-heavy page
    /// can be more of these than words.
    private static let nonTextPlaceholders = CharacterSet(charactersIn: "\u{fffc}\u{fffd}")

    private static func normalized(_ text: String) -> String? {
        // Control characters survive whitespace collapsing because they are not
        // whitespace. They reach here from real interfaces — a recording showed one
        // application answering with its own name wrapped in them — and from there they
        // would travel into a prompt as invisible noise inside a tag.
        let stripped = String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0)
                        && !nonTextPlaceholders.contains($0)
                }
            )
        )
        let normalized = stripped
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func substantiallyOverlaps(_ text: String, anyOf others: [String]) -> Bool {
        let textLength = (text as NSString).length
        return others.contains { other in
            guard !other.isEmpty else { return false }
            if text == other { return true }

            let otherLength = (other as NSString).length
            let shorterLength = min(textLength, otherLength)
            guard shorterLength >= 12 else { return false }

            if text.contains(other) {
                return Double(otherLength) / Double(textLength) >= 0.5
            }
            if other.contains(text) {
                return Double(textLength) / Double(otherLength) >= 0.5
            }
            return false
        }
    }

    private static func truncated(
        _ text: String,
        maximumUTF16Length: Int,
        keepingSuffix: Bool
    ) -> String {
        guard maximumUTF16Length > 0 else { return "" }
        guard (text as NSString).length > maximumUTF16Length else { return text }

        var characters: [Character] = []
        var length = 0
        let sequence: [Character] = keepingSuffix ? Array(text.reversed()) : Array(text)
        for character in sequence {
            let characterLength = String(character).utf16.count
            guard length + characterLength <= maximumUTF16Length else { break }
            characters.append(character)
            length += characterLength
        }
        if keepingSuffix {
            characters.reverse()
        }
        return String(characters)
    }
}
