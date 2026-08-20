import Foundation

/// Judgements about a candidate's text that position cannot make.
///
/// Ranking used to be purely geometric, which is how a timestamp sitting beside a note
/// came to outrank the note. Where something sits says how likely it is to be related;
/// what it says is how likely it is to be *useful*, and the two are different questions.
public enum ContextRelevance {
    /// Text that is only a date or a time, and nothing else.
    ///
    /// Interfaces are full of these — a note's header, a message's timestamp, a
    /// "last edited" line — and none of them help write a sentence. Recognising them
    /// with the system's own date detector rather than a pattern keeps it working in
    /// every language the author might be writing in.
    public static func isBareTimestamp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        guard let detector = Self.dateDetector else { return false }

        let whole = NSRange(location: 0, length: (trimmed as NSString).length)
        let covered = detector
            .matches(in: trimmed, options: [], range: whole)
            .reduce(into: 0) { total, match in total += match.range.length }
        // A date with a sentence around it is a sentence; a date with a stray word or
        // two around it is a header.
        return Double(covered) / Double(whole.length) >= 0.6
    }

    /// Text carrying no letters at all — a count, a bare number, a row of separators.
    public static func isWordless(_ text: String) -> Bool {
        !text.contains { $0.isLetter }
    }

    public static func isNoise(_ text: String) -> Bool {
        isWordless(text) || isBareTimestamp(text)
    }

    /// How much a candidate looks like it is about the same thing as the text being
    /// edited.
    ///
    /// Deliberately a small nudge rather than a ranking of its own. Shared words are
    /// evidence, not proof: a reply often introduces the very words the message above it
    /// never used, and demoting it for that would be worse than ignoring words entirely.
    public static func lexicalBoost(for text: String, relatedTo target: String) -> Int {
        let candidateWords = significantWords(in: text)
        let targetWords = significantWords(in: target)
        guard !candidateWords.isEmpty, !targetWords.isEmpty else { return 0 }

        let shared = candidateWords.intersection(targetWords).count
        guard shared > 0 else { return 0 }
        let overlap = Double(shared) / Double(min(candidateWords.count, targetWords.count))
        return Int((overlap * 120).rounded())
    }

    /// Words long enough to mean something. Short ones are mostly grammar, and they
    /// overlap between any two pieces of text in the same language.
    static func significantWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .filter { $0.count >= 4 }
                .map(String.init)
        )
    }

    private static let dateDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
    )
}
