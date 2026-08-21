import PlainwordCore
import SwiftUI

/// The full record of one LLM call, shown in its own sheet.
///
/// The debug list stays scannable because nothing expands in place: every payload is
/// read here.
///
/// One payload at a time, not all of them at once. A call carries the same text three
/// times over — each message on its own, the request body that contains those messages,
/// and the response — so stacking them in one column made the sheet a scroll through
/// duplicates with no landmark. The facts that describe the call are stated once at the
/// top, and the picker below chooses which payload gets the rest of the height.
struct LLMCallDetailView: View {
    let entry: LLMDebugLogEntry
    let onClose: () -> Void

    /// Which payload the body is showing. Each prompt message is its own choice rather
    /// than a second picker beside the first: they are all just payloads of one call,
    /// and one row of equal-sized choices is easier to aim at than two controls of
    /// different sizes competing for the same corner.
    private enum Payload: Hashable {
        case message(Int)
        case request
        case reasoning
        case response
    }

    @State private var payload: Payload

    init(entry: LLMDebugLogEntry, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onClose = onClose
        _payload = State(initialValue: Self.openingPayload(for: entry))
    }

    /// A failed call is opened to read what came back, so start there. Otherwise the
    /// prompt is what matters, and the author's own message is the last one: the system
    /// prompt is the same on every call.
    private static func openingPayload(for entry: LLMDebugLogEntry) -> Payload {
        if entry.isFailure { return .response }
        let messages = entry.request.messages
        return messages.isEmpty ? .request : .message(messages.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            divider

            summary

            divider

            payloadPicker

            payloadBody
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            divider

            HStack {
                Spacer()
                Button(action: onClose) {
                    PlainwordShortcutLabel("Done", shortcut: "esc")
                }
                .buttonStyle(PlainwordButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                .hoverTip("Close this call and return to the list")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 680, height: 620)
        .background(PlainwordTheme.surface)
        .foregroundStyle(PlainwordTheme.textPrimary)
        .tint(PlainwordTheme.accent)
    }

    private var divider: some View {
        Rectangle()
            .fill(PlainwordTheme.separator)
            .frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LLMCallStatusBadge(entry: entry)

            Text(entry.request.model)
                .font(PlainwordFont.serif(17, weight: .medium))
                .textSelection(.enabled)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(startedAtLabel)
                .font(PlainwordFont.mono(10))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .textSelection(.enabled)
                .accessibilityLabel("Started at \(startedAtLabel)")

            QuietGlyphButton(systemImage: "xmark", help: "Close") {
                onClose()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Everything about the call that is not a payload, stated once.
    ///
    /// The measurements read across as figures because that is how they are compared
    /// between calls; how the call was addressed and configured reads as a sentence
    /// underneath, because it is the same on every call until something is changed.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(measurements.enumerated()), id: \.offset) { index, measurement in
                    if index > 0 {
                        Rectangle()
                            .fill(PlainwordTheme.separator)
                            .frame(width: 1, height: separatorHeight)
                    }
                    measurementColumn(measurement)
                }
            }

            Text(configurationLine)
                .font(PlainwordFont.ui(11))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let failureMessage = entry.failureMessage {
                failureBanner(failureMessage)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private struct Measurement {
        let label: String
        let value: String
        /// A second, quieter line under the figure, for a part of it worth naming. Only
        /// the calls that have one grow the row; the rest read exactly as before.
        let detail: String?
        /// Spelled out for VoiceOver, where "1.2 s" under "TTFB" has no reading order.
        let spokenValue: String

        init(
            label: String,
            value: String?,
            detail: String? = nil,
            spokenValue: String? = nil
        ) {
            self.label = label
            self.value = value ?? "\u{2014}"
            self.detail = detail
            self.spokenValue = [spokenValue ?? value ?? "not reported", detail]
                .compactMap { $0 }
                .joined(separator: ", ")
        }
    }

    private var measurements: [Measurement] {
        [
            Measurement(
                label: "TTFB",
                value: entry.timeToFirstByte.map { String(format: "%.2f s", $0) },
                spokenValue: entry.timeToFirstByte.map {
                    String(format: "%.2f seconds to first byte", $0)
                }
            ),
            Measurement(
                label: "Duration",
                value: entry.durationLabel ?? (entry.isInProgress ? "Running" : nil),
                spokenValue: entry.duration.map { String(format: "%.2f seconds", $0) }
                    ?? (entry.isInProgress ? "still running" : nil)
            ),
            Measurement(
                label: "Tokens",
                value: entry.tokenUsage?.compactDescription,
                detail: entry.tokenUsage?.thinkingDescription
            ),
            Measurement(label: "Cache", value: entry.tokenUsage?.compactCacheDescription)
        ]
    }

    /// The rules stop where the figures do, so a call that reports a breakdown has
    /// taller rules rather than short ones floating above a third line.
    private var separatorHeight: CGFloat {
        measurements.contains { $0.detail != nil } ? 38 : 26
    }

    private func measurementColumn(_ measurement: Measurement) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(measurement.label.uppercased())
                .font(PlainwordFont.mono(9.5))
                .tracking(0.8)
                .foregroundStyle(PlainwordTheme.textTertiary)
            Text(measurement.value)
                .font(PlainwordFont.mono(11.5))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail = measurement.detail {
                Text(detail)
                    .font(PlainwordFont.mono(10))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(measurement.label): \(measurement.spokenValue)")
    }

    /// How the call was addressed and configured: the endpoint, the transport, and the
    /// thinking mode that was asked for.
    private var configurationLine: String {
        [
            entry.request.endpoint,
            entry.request.isStreaming ? "SSE stream" : "JSON",
            LLMDebugLogEntry.thinkingLabel(for: entry.request.reasoningEffort)
        ].joined(separator: "  ·  ")
    }

    private func failureBanner(_ message: String) -> some View {
        Text(message)
            .font(PlainwordFont.ui(11))
            .foregroundStyle(PlainwordTheme.danger)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                PlainwordTheme.dangerMuted,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityLabel("Error: \(message)")
    }

    private var payloadPicker: some View {
        HStack(spacing: 10) {
            PlainwordSegmentedControl(
                segments: payloadSegments,
                selection: $payload,
                accessibilityLabel: "Payload to show"
            )
            .hoverTip("Choose which part of the call to read")

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    /// Thinking sits between what was asked and what came back, which is the order it
    /// happened in, and it is offered only when the provider reported some: a dead
    /// choice on every call by a model that does not think is one more thing to aim past.
    private var payloadSegments: [PlainwordSegment<Payload>] {
        messageTabs.map { PlainwordSegment(Payload.message($0.index), $0.label) }
            + [PlainwordSegment(Payload.request, "Request")]
            + (hasReasoning ? [PlainwordSegment(Payload.reasoning, "Thinking")] : [])
            + [PlainwordSegment(Payload.response, "Response")]
    }

    private var hasReasoning: Bool {
        !(entry.reasoning ?? "").isEmpty
    }

    @ViewBuilder
    private var payloadBody: some View {
        switch payload {
        case .message(let index):
            DebugPayloadPane(
                title: messageTitle(index),
                text: message(at: index)?.content ?? "",
                emptyMessage: "This message was recorded empty."
            )
        case .request:
            DebugPayloadPane(
                title: "Request payload",
                text: prettyPrintedJSON(entry.request.payloadJSON),
                emptyMessage: "The request body was not recorded."
            )
        case .reasoning:
            DebugPayloadPane(
                title: "Thinking",
                text: entry.reasoning ?? "",
                emptyMessage: "This model reported no thinking."
            )
        case .response:
            DebugPayloadPane(
                title: "Response",
                text: responseText,
                emptyMessage: entry.isInProgress
                    ? "Waiting for the provider to answer."
                    : "Nothing came back in the response body."
            )
        }
    }

    private struct MessageTab {
        let index: Int
        let label: String
    }

    /// Message labels, made unambiguous only where they need to be: a prompt with one
    /// user turn says "User", a prompt with three says "User 1", "User 2", "User 3".
    ///
    /// Long conversations fall back to numbers, because the picker is one row and a
    /// dozen spelled-out roles would push the last choices off the sheet.
    private var messageTabs: [MessageTab] {
        let roles = entry.request.messages.map { $0.role.capitalized }
        guard roles.count <= 4 else {
            return roles.indices.map { MessageTab(index: $0, label: "\($0 + 1)") }
        }
        var totals: [String: Int] = [:]
        for role in roles {
            totals[role, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return roles.enumerated().map { index, role in
            seen[role, default: 0] += 1
            let label = (totals[role] ?? 0) > 1 ? "\(role) \(seen[role] ?? 1)" : role
            return MessageTab(index: index, label: label)
        }
    }

    /// The pane spells out what the picker abbreviates, so a numbered choice still
    /// says which role it is once it is open.
    private func messageTitle(_ index: Int) -> String {
        guard let message = message(at: index) else { return "Message" }
        let position = entry.request.messages.count > 1 ? " \(index + 1)" : ""
        return message.role.capitalized + " message" + position
    }

    private func message(at index: Int) -> LLMCallDebugRequest.Message? {
        let messages = entry.request.messages
        return messages.indices.contains(index) ? messages[index] : nil
    }

    private var responseText: String {
        guard let body = entry.responseBody, !body.isEmpty else { return "" }
        return prettyPrintedJSON(body)
    }

    private var startedAtLabel: String {
        entry.request.startedAt.formatted(date: .omitted, time: .standard)
    }
}
