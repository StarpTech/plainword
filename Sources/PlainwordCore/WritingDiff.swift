import Foundation

public enum WritingDiffSegmentKind: Equatable, Sendable {
    case unchanged
    case removed
    case inserted
}

public struct WritingDiffSegment: Equatable, Sendable {
    public let kind: WritingDiffSegmentKind
    public let text: String
    /// The segment's position in the original text. Insertions use a zero-length
    /// range at their insertion point.
    public let originalUTF16Range: NSRange

    public init(
        kind: WritingDiffSegmentKind,
        text: String,
        originalUTF16Range: NSRange
    ) {
        self.kind = kind
        self.text = text
        self.originalUTF16Range = originalUTF16Range
    }
}

public enum WritingDiffPlanner {
    private enum TokenKind: Equatable {
        case word
        case whitespace
        case punctuation
    }

    private struct Token: Equatable {
        let text: String
        let kind: TokenKind
    }

    private struct UnpositionedSegment {
        let kind: WritingDiffSegmentKind
        var text: String
    }

    public static func make(
        original: String,
        replacement: String
    ) -> [WritingDiffSegment] {
        let originalTokens = tokens(in: original)
        let replacementTokens = tokens(in: replacement)
        let rowCount = originalTokens.count + 1
        let columnCount = replacementTokens.count + 1
        var lengths = Array(
            repeating: Array(repeating: 0, count: columnCount),
            count: rowCount
        )

        if !originalTokens.isEmpty, !replacementTokens.isEmpty {
            for originalIndex in stride(from: originalTokens.count - 1, through: 0, by: -1) {
                for replacementIndex in stride(
                    from: replacementTokens.count - 1,
                    through: 0,
                    by: -1
                ) {
                    if originalTokens[originalIndex] == replacementTokens[replacementIndex] {
                        lengths[originalIndex][replacementIndex] =
                            lengths[originalIndex + 1][replacementIndex + 1] + 1
                    } else {
                        lengths[originalIndex][replacementIndex] = max(
                            lengths[originalIndex + 1][replacementIndex],
                            lengths[originalIndex][replacementIndex + 1]
                        )
                    }
                }
            }
        }

        var unpositioned: [UnpositionedSegment] = []
        var originalIndex = 0
        var replacementIndex = 0

        func append(_ kind: WritingDiffSegmentKind, _ text: String) {
            guard !text.isEmpty else { return }
            if unpositioned.last?.kind == kind {
                unpositioned[unpositioned.count - 1].text += text
            } else {
                unpositioned.append(UnpositionedSegment(kind: kind, text: text))
            }
        }

        while originalIndex < originalTokens.count
            || replacementIndex < replacementTokens.count {
            if originalIndex < originalTokens.count,
               replacementIndex < replacementTokens.count,
               originalTokens[originalIndex] == replacementTokens[replacementIndex] {
                append(.unchanged, originalTokens[originalIndex].text)
                originalIndex += 1
                replacementIndex += 1
            } else if replacementIndex < replacementTokens.count,
                      originalIndex == originalTokens.count
                        || lengths[originalIndex][replacementIndex + 1]
                            > lengths[originalIndex + 1][replacementIndex] {
                append(.inserted, replacementTokens[replacementIndex].text)
                replacementIndex += 1
            } else if originalIndex < originalTokens.count {
                append(.removed, originalTokens[originalIndex].text)
                originalIndex += 1
            }
        }

        var originalUTF16Offset = 0
        return unpositioned.map { segment in
            let length = segment.kind == .inserted
                ? 0
                : (segment.text as NSString).length
            defer { originalUTF16Offset += length }
            return WritingDiffSegment(
                kind: segment.kind,
                text: segment.text,
                originalUTF16Range: NSRange(
                    location: originalUTF16Offset,
                    length: length
                )
            )
        }
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []

        for character in text {
            let kind = tokenKind(for: character)
            if let last = result.last,
               last.kind == kind,
               kind != .punctuation {
                result[result.count - 1] = Token(
                    text: last.text + String(character),
                    kind: kind
                )
            } else {
                result.append(Token(text: String(character), kind: kind))
            }
        }

        return result
    }

    private static func tokenKind(for character: Character) -> TokenKind {
        if character.isWhitespace { return .whitespace }
        if character == "'" || character == "’" { return .word }
        if character.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
        }) {
            return .word
        }
        return .punctuation
    }
}
