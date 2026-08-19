import Foundation

public enum WritingSuggestionKind: String, Codable, Equatable, Sendable {
    case correction
    case completion
    case rewrite
    /// Text written from an instruction rather than revised from existing text. It has
    /// no original to diff against, so it is presented and applied as a whole draft.
    case composition
}

public struct WritingTextChange: Equatable, Sendable {
    public let original: String
    public let replacement: String

    public init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }
}

public struct WritingSuggestion: Equatable, Sendable {
    public let kind: WritingSuggestionKind
    public let originalText: String
    public let replacementText: String
    public let changes: [WritingTextChange]

    public init(
        kind: WritingSuggestionKind,
        originalText: String,
        replacementText: String,
        changes: [WritingTextChange]
    ) {
        self.kind = kind
        self.originalText = originalText
        self.replacementText = replacementText
        self.changes = changes
    }
}

public enum WritingSuggestionPlanner {
    private enum TokenKind {
        case word
        case whitespace
        case punctuation
    }

    private struct Token: Equatable {
        let text: String
        let kind: TokenKind
    }

    public static func make(
        originalText: String,
        replacementText: String,
        completionIsAllowed: Bool = true,
        classifiedAs classification: WritingSuggestionKind? = nil,
        allowsNewConcreteDetails: Bool = false,
        allowsLanguageChange: Bool = false
    ) -> WritingSuggestion? {
        guard replacementText.contains(where: { !$0.isWhitespace }),
              originalText != replacementText,
              allowsNewConcreteDetails || !introducesConcreteDetail(
                originalText: originalText,
                replacementText: replacementText
              ),
              allowsLanguageChange || !changesDetectedLanguage(
                originalText: originalText,
                replacementText: replacementText
              ) else {
            return nil
        }

        if replacementText.hasPrefix(originalText),
           classification == nil || classification == .completion {
            let suffix = String(replacementText.dropFirst(originalText.count))
            let addedWords = tokens(in: suffix).filter { $0.kind == .word }
            if !addedWords.isEmpty {
                guard completionIsAllowed,
                      addedWords.count <= 8,
                      !suffix.contains(where: { $0.isNewline }) else {
                    return nil
                }
                return WritingSuggestion(
                    kind: .completion,
                    originalText: originalText,
                    replacementText: replacementText,
                    changes: [.init(original: "", replacement: suffix)]
                )
            }
        }

        // A completion must only append to the existing text. Reject a malformed
        // model classification rather than presenting a replacement as ghost text.
        if classification == .completion {
            return nil
        }

        let originalTokens = tokens(in: originalText)
        let replacementTokens = tokens(in: replacementText)
        let changes = difference(from: originalTokens, to: replacementTokens)
        guard !changes.isEmpty else { return nil }

        // `correction` drives the compact "Small correction" presentation, so it
        // must describe the shape of the diff rather than merely repeat the model's
        // semantic label. Count a replacement by its larger side: counting both the
        // removed and inserted spelling would make a single typo look like two edits.
        let changedTokenCount = changes.reduce(into: 0) { count, change in
            let removedCount = tokens(in: change.original)
                .filter { $0.kind != .whitespace }
                .count
            let insertedCount = tokens(in: change.replacement)
                .filter { $0.kind != .whitespace }
                .count
            count += max(removedCount, insertedCount)
        }
        let originalTokenCount = max(
            1,
            originalTokens.filter { $0.kind != .whitespace }.count
        )
        let correctionBudget = max(3, originalTokenCount / 2)
        let isFocusedCorrection = changes.count <= 3
            && changedTokenCount <= correctionBudget
        let kind: WritingSuggestionKind
        switch classification {
        case .correction:
            // Treat the model classification as semantic input, not permission to
            // squeeze a distributed or sentence-wide edit into the compact UI.
            kind = isFocusedCorrection ? .correction : .rewrite
        case .rewrite:
            kind = .rewrite
        case .completion:
            return nil
        case .composition:
            // Composition never comes from an edit request; it is built by
            // `makeComposition` for a field that had nothing to edit.
            return nil
        case nil:
            kind = isFocusedCorrection ? .correction : .rewrite
        }

        return WritingSuggestion(
            kind: kind,
            originalText: originalText,
            replacementText: replacementText,
            changes: changes
        )
    }

    /// Returns a draft written for an empty field.
    ///
    /// None of `make`'s guards apply here: there is no original meaning to preserve, no
    /// language to keep, and inventing concrete detail is the point rather than a
    /// failure. All that is left to check is that the model wrote something.
    public static func makeComposition(_ replacementText: String) -> WritingSuggestion? {
        let draft = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return nil }
        return WritingSuggestion(
            kind: .composition,
            originalText: "",
            replacementText: draft,
            changes: [.init(original: "", replacement: draft)]
        )
    }

    private static func changesDetectedLanguage(
        originalText: String,
        replacementText: String
    ) -> Bool {
        guard let originalLanguage = TextLanguageDetector.dominantLanguageIdentifier(
            in: originalText
        ),
        let replacementLanguage = TextLanguageDetector.dominantLanguageIdentifier(
            in: replacementText
        ) else {
            return false
        }
        return originalLanguage != replacementLanguage
    }

    private static func difference(
        from original: [Token],
        to replacement: [Token]
    ) -> [WritingTextChange] {
        let rowCount = original.count + 1
        let columnCount = replacement.count + 1
        var lengths = Array(
            repeating: Array(repeating: 0, count: columnCount),
            count: rowCount
        )

        if !original.isEmpty, !replacement.isEmpty {
            for originalIndex in stride(from: original.count - 1, through: 0, by: -1) {
                for replacementIndex in stride(from: replacement.count - 1, through: 0, by: -1) {
                    if original[originalIndex] == replacement[replacementIndex] {
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

        var changes: [WritingTextChange] = []
        var removed = ""
        var inserted = ""
        var originalIndex = 0
        var replacementIndex = 0

        func flush() {
            guard !removed.isEmpty || !inserted.isEmpty else { return }
            changes.append(.init(original: removed, replacement: inserted))
            removed = ""
            inserted = ""
        }

        while originalIndex < original.count || replacementIndex < replacement.count {
            if originalIndex < original.count,
               replacementIndex < replacement.count,
               original[originalIndex] == replacement[replacementIndex] {
                flush()
                originalIndex += 1
                replacementIndex += 1
            } else if replacementIndex < replacement.count,
                      originalIndex == original.count
                        || lengths[originalIndex][replacementIndex + 1]
                            > lengths[originalIndex + 1][replacementIndex] {
                inserted += replacement[replacementIndex].text
                replacementIndex += 1
            } else if originalIndex < original.count {
                removed += original[originalIndex].text
                originalIndex += 1
            }
        }
        flush()

        return changes.filter { !$0.original.isEmpty || !$0.replacement.isEmpty }
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []

        for character in text {
            let kind = tokenKind(for: character)
            if let last = result.last,
               last.kind == kind,
               kind != .punctuation {
                result[result.count - 1] = Token(text: last.text + String(character), kind: kind)
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

    private static func introducesConcreteDetail(
        originalText: String,
        replacementText: String
    ) -> Bool {
        let originalDetails = concreteDetails(in: originalText)
        let replacementDetails = concreteDetails(in: replacementText)
        return !replacementDetails.isSubset(of: originalDetails)
    }

    private static func concreteDetails(in text: String) -> Set<String> {
        let calendarWords: Set<String> = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "june", "july", "august",
            "september", "october", "november", "december", "today", "tomorrow", "tonight"
        ]

        var details = Set(tokens(in: text).compactMap { token in
            let normalized = token.text.lowercased()
            if token.text.contains(where: { $0.isNumber }) {
                return "number:\(normalized)"
            }
            if let calendarWord = calendarWords.first(where: {
                isSameOrLikelyMisspelling(normalized, of: $0)
            }) {
                return "calendar:\(calendarWord)"
            }
            return nil
        })

        for rawToken in text.split(whereSeparator: { $0.isWhitespace }) {
            let normalized = rawToken
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            if normalized.contains("://")
                || normalized.hasPrefix("www.")
                || (normalized.contains("@") && normalized.contains(".")) {
                details.insert("link:\(normalized)")
            }
        }
        return details
    }

    private static func isSameOrLikelyMisspelling(
        _ candidate: String,
        of expected: String
    ) -> Bool {
        if candidate == expected { return true }
        guard candidate.first == expected.first,
              abs(candidate.count - expected.count) <= 2 else {
            return false
        }
        return editDistance(candidate, expected) <= 2
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[right.count]
    }
}
