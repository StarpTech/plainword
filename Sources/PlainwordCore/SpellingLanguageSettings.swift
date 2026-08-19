import Foundation
import NaturalLanguage

public enum SpellingLanguageMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case fixed
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .fixed: "Fixed language"
        case .disabled: "Disabled"
        }
    }
}

public struct SpellingLanguageSettings: Codable, Equatable, Sendable {
    public var mode: SpellingLanguageMode
    public var fixedLanguageIdentifier: String

    public init(
        mode: SpellingLanguageMode = .automatic,
        fixedLanguageIdentifier: String = ""
    ) {
        self.mode = mode
        self.fixedLanguageIdentifier = fixedLanguageIdentifier
    }
}

public enum TextLanguageDetector {
    public static func dominantLanguageIdentifier(
        in text: String,
        minimumConfidence: Double = 0.6,
        minimumConfidenceMargin: Double = 0.15
    ) -> String? {
        let letterCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) {
                count += 1
            }
        }
        guard letterCount >= 6 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let ranked = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let strongest = ranked.first,
              strongest.value >= minimumConfidence else {
            return nil
        }
        if ranked.count > 1,
           strongest.value - ranked[1].value < minimumConfidenceMargin {
            return nil
        }
        return strongest.key.rawValue
    }

    public static func dominantLanguageIdentifier(in context: TextEditContext) -> String? {
        // The editable target is authoritative. Application context can contain
        // localized UI labels, menus, and help text that have no relationship to
        // the language the author is writing in.
        if let targetLanguage = dominantLanguageIdentifier(in: context.text) {
            return targetLanguage
        }

        // A short or ambiguous target may borrow evidence from prose immediately
        // beside it in the same field, but never from application-level context.
        return dominantLanguageIdentifier(
            in: [context.leadingContext, context.trailingContext]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        )
    }
}

public enum SpellingDictionaryResolver {
    public static func resolve(
        languageIdentifier: String?,
        availableLanguages: [String],
        preferredLocaleIdentifier: String = Locale.current.identifier
    ) -> String? {
        guard let languageIdentifier = languageIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !languageIdentifier.isEmpty else {
            return nil
        }

        let normalizedRequest = normalize(languageIdentifier)
        if let exact = availableLanguages.first(where: {
            normalize($0) == normalizedRequest
        }) {
            return exact
        }

        guard let languageCode = Locale(identifier: languageIdentifier)
            .language.languageCode?.identifier.lowercased() else {
            return nil
        }
        let candidates = availableLanguages.filter {
            let normalized = normalize($0)
            return normalized == languageCode || normalized.hasPrefix("\(languageCode)-")
        }
        guard !candidates.isEmpty else { return nil }

        let normalizedPreferred = normalize(preferredLocaleIdentifier)
        if let preferred = candidates.first(where: {
            normalize($0) == normalizedPreferred
        }) {
            return preferred
        }
        if let base = candidates.first(where: { normalize($0) == languageCode }) {
            return base
        }
        return candidates.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.first
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
