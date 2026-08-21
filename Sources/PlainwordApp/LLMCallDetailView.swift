import PlainwordCore
import SwiftUI

/// The full record of one LLM call, shown in its own sheet.
///
/// The debug list stays scannable because nothing expands in place: every payload is
/// read here, in one column of panes that each scroll on their own.
///
/// A flat column rather than a rail of sections: a call has a variable number of
/// messages, and a second level of navigation inside a sheet reads as a hierarchy
/// that isn't there.
struct LLMCallDetailView: View {
    let entry: LLMDebugLogEntry
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)

            Text(entry.transportSummary)
                .font(PlainwordFont.ui(11))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let failureMessage = entry.failureMessage {
                        failureBanner(failureMessage)
                    }

                    metadataPane

                    ForEach(Array(entry.request.messages.enumerated()), id: \.offset) {
                        _, message in
                        DebugPayloadPane(
                            title: message.role.capitalized + " message",
                            text: message.content
                        )
                    }

                    DebugPayloadPane(
                        title: "Request payload",
                        text: prettyPrintedJSON(entry.request.payloadJSON)
                    )

                    DebugPayloadPane(title: "Response", text: responseText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.automatic)

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)

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
        .frame(width: 640, height: 560)
        .background(PlainwordTheme.surface)
        .foregroundStyle(PlainwordTheme.textPrimary)
        .tint(PlainwordTheme.accent)
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

            QuietGlyphButton(systemImage: "xmark", help: "Close") {
                onClose()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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

    private var metadataPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            metadataRow("Started", value: startedAtLabel)
            metadataRow("Endpoint", value: entry.request.endpoint)
            metadataRow("Model", value: entry.request.model)
            metadataRow("Reasoning", value: entry.request.reasoningEffort)
            metadataRow("Transport", value: entry.request.isStreaming ? "SSE stream" : "JSON")
            metadataRow(
                "TTFB",
                value: entry.timeToFirstByte.map { String(format: "%.2f s", $0) }
                    ?? "Not reported"
            )
            metadataRow("Duration", value: entry.durationLabel ?? "In progress")
            if let usage = entry.tokenUsage {
                metadataRow("Tokens", value: usage.totalDescription)
                metadataRow("Cache", value: usage.cacheDescription)
            }
        }
        .padding(12)
        .plainwordCard(
            cornerRadius: 10,
            fill: PlainwordTheme.raisedSurface
        )
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(PlainwordFont.mono(9.5))
                .tracking(0.8)
                .foregroundStyle(PlainwordTheme.textTertiary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(PlainwordFont.mono(10.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var responseText: String {
        switch entry.state {
        case .inProgress:
            return ""
        case .succeeded, .failed:
            let body = entry.responseBody ?? ""
            return body.isEmpty ? "" : prettyPrintedJSON(body)
        }
    }

    private var startedAtLabel: String {
        entry.request.startedAt.formatted(date: .omitted, time: .standard)
    }
}
