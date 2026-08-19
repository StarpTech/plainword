import Foundation

public enum ReadOnlyContextKind: String, Equatable, Hashable, Sendable {
    case sourceApplication
    case fieldLabel
    case fieldIdentity
    case fieldPlaceholder
    case fieldDescription
    case fieldHelp
    case documentTitle
    case relatedPrecedingContent
    case relatedFollowingContent
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
        case .relatedFollowingContent:
            "related_following_content"
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
        case .relatedFollowingContent: 8
        case .relatedContent: 9
        }
    }

    fileprivate var keepsNearestSuffixWhenTruncated: Bool {
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
        case .relatedFollowingContent:
            480
        case .relatedPrecedingContent, .relatedContent:
            900
        }
    }
}

public struct ReadOnlyContextFragment: Equatable, Hashable, Sendable {
    public let kind: ReadOnlyContextKind
    public let text: String

    public init(kind: ReadOnlyContextKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct ReadOnlyContextCandidate: Equatable, Sendable {
    public let kind: ReadOnlyContextKind
    public let text: String
    public let relevance: Int
    public let readingOrder: Int

    public init(
        kind: ReadOnlyContextKind,
        text: String,
        relevance: Int,
        readingOrder: Int
    ) {
        self.kind = kind
        self.text = text
        self.relevance = relevance
        self.readingOrder = readingOrder
    }
}

public enum ReadOnlyContextRanker {
    public static func select(
        from candidates: [ReadOnlyContextCandidate],
        excluding excludedTexts: [String] = [],
        maximumUTF16Length: Int,
        maximumFragments: Int = 6,
        minimumRelevance: Int = 300
    ) -> [ReadOnlyContextFragment] {
        guard maximumUTF16Length > 0, maximumFragments > 0 else { return [] }

        let excluded = excludedTexts.compactMap(normalized)
        let normalizedCandidates = candidates.enumerated().compactMap {
            index, candidate -> RankedCandidate? in
            guard candidate.relevance >= minimumRelevance,
                  let text = normalized(candidate.text),
                  !substantiallyOverlaps(text, anyOf: excluded) else {
                return nil
            }
            return RankedCandidate(candidate: candidate, text: text, insertionOrder: index)
        }.sorted { lhs, rhs in
            if lhs.candidate.relevance != rhs.candidate.relevance {
                return lhs.candidate.relevance > rhs.candidate.relevance
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
                    insertionOrder: rankedCandidate.insertionOrder
                )
            )
            remainingLength -= (text as NSString).length + separatorLength
        }

        return selected.sorted { lhs, rhs in
            let lhsKind = lhs.candidate.kind.presentationOrder
            let rhsKind = rhs.candidate.kind.presentationOrder
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            if lhs.candidate.readingOrder != rhs.candidate.readingOrder {
                return lhs.candidate.readingOrder < rhs.candidate.readingOrder
            }
            return lhs.insertionOrder < rhs.insertionOrder
        }.map {
            ReadOnlyContextFragment(kind: $0.candidate.kind, text: $0.text)
        }
    }

    public static func plainText(from fragments: [ReadOnlyContextFragment]) -> String {
        fragments.map(\.text).joined(separator: "\n")
    }

    private struct RankedCandidate {
        let candidate: ReadOnlyContextCandidate
        let text: String
        let insertionOrder: Int
    }

    private static func normalized(_ text: String) -> String? {
        let normalized = text
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
