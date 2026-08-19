import Foundation

/// One step of a correction while it is still arriving.
///
/// Providers send the structured answer a fragment at a time. `partialText` carries the
/// corrected text read out of those fragments so the panel can show the result forming
/// instead of a spinner; `completed` carries the decoded and validated answer, and is
/// the only case a caller has to act on.
public enum CorrectionStreamEvent: Equatable, Sendable {
    case partialText(String)
    case completed(CorrectionResponse)
}

/// Reads the corrected text out of a structured response that has not finished arriving.
///
/// The response is a JSON object whose `corrected_text` member is written out one
/// fragment at a time, so most of the time the accumulated text is not valid JSON. This
/// finds the member, takes as much of its value as has been received, and drops a
/// trailing escape sequence that is still missing characters. Anything it cannot read
/// yet is reported as `nil`, which simply means there is nothing to show.
public enum PartialStructuredCorrection {
    private static let memberName = "\"corrected_text\""

    public static func correctedText(from raw: String) -> String? {
        guard let valueStart = valueStart(in: raw) else { return nil }
        let fragment = receivedFragment(in: raw, from: valueStart)
        guard !fragment.isEmpty else { return nil }
        return decoded(fragment)
    }

    /// The index just past the opening quote of the `corrected_text` value.
    private static func valueStart(in raw: String) -> String.Index? {
        guard let member = raw.range(of: memberName) else { return nil }
        var index = member.upperBound
        guard let colon = skippingWhitespace(in: raw, from: &index), colon == ":" else {
            return nil
        }
        index = raw.index(after: index)
        guard let quote = skippingWhitespace(in: raw, from: &index), quote == "\"" else {
            return nil
        }
        return raw.index(after: index)
    }

    private static func skippingWhitespace(
        in raw: String,
        from index: inout String.Index
    ) -> Character? {
        while index < raw.endIndex, raw[index].isWhitespace {
            index = raw.index(after: index)
        }
        return index < raw.endIndex ? raw[index] : nil
    }

    /// The part of the value that is complete enough to decode, still JSON-escaped.
    private static func receivedFragment(
        in raw: String,
        from valueStart: String.Index
    ) -> Substring {
        var index = valueStart
        var completeEnd = valueStart
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\"" {
                return raw[valueStart..<index]
            }
            guard character == "\\" else {
                index = raw.index(after: index)
                completeEnd = index
                continue
            }
            guard let escapeEnd = escapeEnd(in: raw, startingAt: index) else {
                // The escape is still arriving. Its own characters mean nothing on
                // their own, so the value ends before it.
                return raw[valueStart..<completeEnd]
            }
            index = escapeEnd
            completeEnd = escapeEnd
        }
        return raw[valueStart..<completeEnd]
    }

    /// The index just past a complete escape sequence, or `nil` while one is incomplete.
    private static func escapeEnd(in raw: String, startingAt index: String.Index) -> String.Index? {
        let afterBackslash = raw.index(after: index)
        guard afterBackslash < raw.endIndex else { return nil }
        guard raw[afterBackslash] == "u" else {
            return raw.index(after: afterBackslash)
        }
        guard let end = raw.index(afterBackslash, offsetBy: 5, limitedBy: raw.endIndex),
              raw[raw.index(after: afterBackslash)..<end].allSatisfy(\.isHexDigit) else {
            return nil
        }
        // A leading surrogate only spells a character together with the trailing one
        // that follows it, so it waits for its partner rather than decoding alone.
        let digits = raw[raw.index(after: afterBackslash)..<end]
        if let value = UInt32(digits, radix: 16), (0xD800...0xDBFF).contains(value) {
            guard let pairEnd = raw.index(end, offsetBy: 6, limitedBy: raw.endIndex),
                  raw[end] == "\\",
                  raw[raw.index(after: end)] == "u",
                  raw[raw.index(end, offsetBy: 2)..<pairEnd].allSatisfy(\.isHexDigit) else {
                return nil
            }
            return pairEnd
        }
        return end
    }

    private static func decoded(_ fragment: Substring) -> String? {
        // Some providers leave control characters unescaped, which JSON does not allow.
        // Escaping them here keeps a stray newline from hiding the whole partial value.
        var escaped = ""
        escaped.reserveCapacity(fragment.count)
        for character in fragment {
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1,
                  scalar.value < 0x20 else {
                escaped.append(character)
                continue
            }
            switch scalar {
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped += String(format: "\\u%04x", scalar.value)
            }
        }
        guard let data = "\"\(escaped)\"".data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
}
