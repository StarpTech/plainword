import Foundation

public enum EditIntent: String, Equatable, Hashable, Sendable {
    case correct
    case correctOrComplete
    /// Write new text from an instruction alone, with no existing text to edit.
    case compose

    /// The classifications a result may carry under this intent. Both providers
    /// constrain their structured output to these, so a value the panel cannot
    /// present never comes back.
    public var allowedClassifications: [WritingSuggestionKind] {
        switch self {
        case .correct: [.correction, .rewrite]
        case .correctOrComplete: [.correction, .rewrite, .completion]
        case .compose: [.rewrite]
        }
    }
}

public enum EditTrigger: Equatable, Sendable {
    case insertedText
    case wordBoundary
    case sentenceBoundary
    case deletion
    case paste
    case cut
    case cancelOnly
    case ignored

    public var debounceMilliseconds: Int? {
        switch self {
        case .wordBoundary:
            250
        case .sentenceBoundary, .paste, .cut:
            400
        case .insertedText, .deletion:
            900
        case .cancelOnly, .ignored:
            nil
        }
    }
}

public enum EditSpecialKey: Equatable, Sendable {
    case deletion
    case enter
    case other
}

/// Classifies a platform key event without deciding whether another application's
/// text actually changed. The caller must still capture and compare the focused field.
public enum EditTriggerClassifier {
    public static func classify(
        characters: String?,
        charactersIgnoringModifiers: String?,
        specialKey: EditSpecialKey?,
        hasCommand: Bool,
        hasControl: Bool
    ) -> EditTrigger {
        if hasControl {
            return .ignored
        }

        if hasCommand {
            switch charactersIgnoringModifiers?.lowercased() {
            case "v":
                return .paste
            case "x":
                return .cut
            case "z":
                return .cancelOnly
            default:
                switch specialKey {
                case .deletion:
                    return .deletion
                case .enter:
                    return .sentenceBoundary
                case .other:
                    return .cancelOnly
                case .none:
                    return .ignored
                }
            }
        }

        switch specialKey {
        case .deletion:
            return .deletion
        case .enter:
            return .sentenceBoundary
        case .other:
            return .cancelOnly
        case .none:
            break
        }

        guard let characters, !characters.isEmpty else {
            return .ignored
        }

        if characters.contains(where: { $0.isNewline }) {
            return .sentenceBoundary
        }
        if characters.allSatisfy({ $0.isWhitespace }) {
            return .wordBoundary
        }
        if let last = characters.last, sentenceEndings.contains(last) {
            return .sentenceBoundary
        }
        if characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .ignored
        }
        return .insertedText
    }

    private static let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？"]
}

public enum LocalTextSignals {
    public static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    public static func wordAtOrBeforeCaret(
        in text: String,
        caretUTF16Offset: Int
    ) -> String? {
        let source = text as NSString
        let boundedOffset = min(max(0, caretUTF16Offset), source.length)
        guard boundedOffset > 0,
              let prefixRange = Range(
                NSRange(location: 0, length: boundedOffset),
                in: text
              ) else {
            return nil
        }

        var result: String?
        text.enumerateSubstrings(
            in: prefixRange,
            options: [.byWords]
        ) { substring, _, _, _ in
            if let substring, substring.contains(where: { !$0.isWhitespace }) {
                result = substring
            }
        }
        return result
    }
}

public enum EditRequestDecision: Equatable, Sendable {
    case none
    case immediate(EditIntent)
    case delayed(EditIntent, additionalMilliseconds: Int)
}

public enum EditRequestRouter {
    public static func decision(
        for trigger: EditTrigger,
        targetKind: TextEditTargetKind,
        completionIsAllowed: Bool,
        currentWordIsSuspicious: Bool,
        wordCount: Int
    ) -> EditRequestDecision {
        if targetKind == .selection {
            return .immediate(.correct)
        }

        // Paragraph review is the automatic cross-app scope. It must not depend on
        // completion eligibility or on NSSpellChecker recognizing the final token: a
        // paragraph can contain clear errors even when its last word is valid (and short
        // fragments such as "hom" are not consistently classified as misspellings).
        // Trigger debouncing still prevents a request while the author keeps typing.
        if targetKind == .paragraph {
            switch trigger {
            case .wordBoundary:
                return .delayed(.correct, additionalMilliseconds: 650)
            case .insertedText, .sentenceBoundary, .deletion, .paste, .cut:
                return .immediate(.correct)
            case .cancelOnly, .ignored:
                return .none
            }
        }

        let contextualIntent: EditIntent = completionIsAllowed
            ? .correctOrComplete
            : .correct

        switch trigger {
        case .sentenceBoundary, .paste, .cut:
            return .immediate(.correct)
        case .wordBoundary:
            if currentWordIsSuspicious {
                return .immediate(contextualIntent)
            }
            guard completionIsAllowed, wordCount >= 2 else { return .none }
            return .delayed(.correctOrComplete, additionalMilliseconds: 650)
        case .insertedText, .deletion:
            if currentWordIsSuspicious {
                return .immediate(contextualIntent)
            }
            guard completionIsAllowed, wordCount >= 2 else { return .none }
            return .immediate(.correctOrComplete)
        case .cancelOnly, .ignored:
            return .none
        }
    }
}
