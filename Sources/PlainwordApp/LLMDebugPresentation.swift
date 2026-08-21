import PlainwordCore
import SwiftUI

/// Display vocabulary shared by the debug list and the call inspector, so a call
/// reads the same way wherever it is shown.
extension LLMDebugLogEntry {
    var statusTitle: String {
        switch state {
        case .inProgress:
            "Sending"
        case .succeeded(let statusCode):
            "HTTP \(statusCode)"
        case .failed(let statusCode, _):
            statusCode.map { "HTTP \($0)" } ?? "Failed"
        }
    }

    /// Status is also carried by a mark, so it never depends on colour alone.
    var statusMark: String {
        switch state {
        case .inProgress: "\u{2191}"
        case .succeeded: "\u{2713}"
        case .failed: "\u{25B3}"
        }
    }

    var statusColor: Color {
        switch state {
        case .inProgress: PlainwordTheme.textSecondary
        case .succeeded: PlainwordTheme.accent
        case .failed: PlainwordTheme.danger
        }
    }

    /// The wash the capsule sits on, matched to the colour it carries.
    var statusWash: Color {
        switch state {
        case .inProgress: PlainwordTheme.fieldSurface
        case .succeeded: PlainwordTheme.accentMuted
        case .failed: PlainwordTheme.dangerMuted
        }
    }

    var statusDescription: String {
        switch state {
        case .inProgress:
            "Sending, waiting for the provider"
        case .succeeded(let statusCode):
            "Succeeded, HTTP \(statusCode)"
        case .failed(let statusCode, let message):
            statusCode.map { "Failed, HTTP \($0), \(message)" } ?? "Failed, \(message)"
        }
    }

    var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    var isInProgress: Bool {
        if case .inProgress = state { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(_, let message) = state { return message }
        return nil
    }

    var durationLabel: String? {
        duration.map { String(format: "%.2f s", $0) }
    }

    /// Time to first byte, kept separate from the total so a call that is slow to start
    /// can be told apart from one that is slow to finish.
    var timeToFirstByteLabel: String? {
        timeToFirstByte.map { String(format: "TTFB %.2f s", $0) }
    }

    /// Reasoning efforts are wire values ("xhigh"), so prefer the mode's own label
    /// and only fall back to the raw string for values the app does not model.
    static func thinkingLabel(for reasoningEffort: String) -> String {
        let name = ThinkingMode(rawValue: reasoningEffort)?.displayName
            ?? reasoningEffort.capitalized
        return name + " thinking"
    }

    var tokenSummary: String? { tokenUsage?.compactDescription }

    /// What the author asked for, read from the prompt's own delimiters.
    var taskLabel: String? {
        guard let content = authorMessage else { return nil }
        if content.contains("<write_instruction>") { return "Compose" }
        if content.contains("<edit_instruction>") { return "Rewrite" }
        if content.contains("<text_to_edit>") { return "Correct" }
        return nil
    }

    var sourceApplication: String? {
        authorMessage.flatMap { taggedValue("source_application", in: $0) }
    }

    /// The author's own text, so a row says which piece of writing it belongs to.
    ///
    /// Only the delimited payload is shown. The surrounding prompt scaffolding is
    /// identical from one call to the next, so previewing it tells the reader nothing
    /// and buries the part that differs.
    var subjectPreview: String? {
        guard let content = authorMessage else { return nil }
        for tag in ["text_to_edit", "write_instruction", "edit_instruction"] {
            if let value = taggedValue(tag, in: content) {
                return value
            }
        }
        return nil
    }

    /// The row's supporting line: what the call did, where, and what it cost.
    var listSummary: String {
        var parts: [String] = []
        if let taskLabel {
            parts.append(taskLabel)
        }
        if let sourceApplication {
            parts.append(sourceApplication)
        }
        if let timeToFirstByteLabel {
            parts.append(timeToFirstByteLabel)
        }
        if let durationLabel {
            parts.append(durationLabel)
        }
        if let tokenSummary {
            parts.append(tokenSummary)
        }
        if parts.isEmpty {
            parts.append(request.isStreaming ? "Streaming" : "Standard")
        }
        return parts.joined(separator: " · ")
    }

    private var authorMessage: String? {
        (request.messages.last { $0.role.lowercased() == "user" } ?? request.messages.last)?
            .content
    }

    private func taggedValue(_ tag: String, in content: String) -> String? {
        guard let opening = content.range(of: "<\(tag)>"),
              let closing = content.range(
                  of: "</\(tag)>",
                  range: opening.upperBound..<content.endIndex
              ) else {
            return nil
        }
        // A preview is one truncated line, so only the head of a long passage is needed.
        let value = content[opening.upperBound..<closing.lowerBound].prefix(400)
        let condensed = value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return condensed.isEmpty ? nil : condensed
    }
}

extension LLMTokenUsage {
    /// What the call spent, in the fewest words that still say which way each figure
    /// runs. `nil` when the provider reported nothing, so the inspector can print one
    /// dash instead of spelling out "Not reported" in every column.
    var compactDescription: String? {
        var parts: [String] = []
        if let inputTokens {
            parts.append("\(inputTokens.formatted()) in")
        }
        if let outputTokens {
            parts.append("\(outputTokens.formatted()) out")
        }
        // A provider that reports only a total still has something worth showing.
        if parts.isEmpty, let totalTokens {
            parts.append("\(totalTokens.formatted()) total")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The thinking share of the output, kept apart from `compactDescription` because
    /// it is a breakdown of the figure beside it rather than another figure to add up.
    var thinkingDescription: String? {
        reasoningTokens.map { "\($0.formatted()) thinking" }
    }

    var compactCacheDescription: String? {
        var parts: [String] = []
        if let cacheReadTokens {
            parts.append("\(cacheReadTokens.formatted()) read")
        }
        if let cacheWriteTokens {
            parts.append("\(cacheWriteTokens.formatted()) written")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Re-indents JSON so payloads are readable; anything else is shown untouched.
func prettyPrintedJSON(_ value: String) -> String {
    guard let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let formatted = try? JSONSerialization.data(
              withJSONObject: object,
              options: [.prettyPrinted, .sortedKeys]
          ) else {
        return value
    }
    return String(decoding: formatted, as: UTF8.self)
}

/// A capsule that states the outcome in words and a mark, not just a colour.
struct LLMCallStatusBadge: View {
    let entry: LLMDebugLogEntry

    var body: some View {
        HStack(spacing: 4) {
            Text(entry.statusMark)
            Text(entry.statusTitle)
        }
        .font(PlainwordFont.ui(10, weight: .bold))
        .foregroundStyle(entry.statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(entry.statusWash, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel(entry.statusDescription)
    }
}
