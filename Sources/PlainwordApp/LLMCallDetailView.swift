import PlainwordCore
import SwiftUI

/// The full record of one LLM call, shown in its own sheet.
///
/// The debug list stays scannable because nothing expands in place: every payload is
/// read here, in a fixed frame where each section scrolls on its own.
///
/// Sections are one flat list rather than tabs within tabs. A call has a variable number
/// of messages, so a second row of controls under the first would both read as a
/// hierarchy that isn't there and run out of room as soon as a prompt gains a turn.
struct LLMCallDetailView: View {
    let entry: LLMDebugLogEntry
    let onClose: () -> Void

    private enum Pane: Hashable, Identifiable {
        case overview
        case message(Int)
        case response
        case payload

        var id: Self { self }

        var symbol: String {
            switch self {
            case .overview: "info.circle"
            case .message: "text.alignleft"
            case .response: "text.quote"
            case .payload: "curlybraces"
            }
        }
    }

    @State private var pane: Pane = .overview

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(PlainwordTheme.separator.opacity(0.7))
                .frame(height: 1)

            HStack(spacing: 0) {
                sectionRail

                Rectangle()
                    .fill(PlainwordTheme.separator.opacity(0.7))
                    .frame(width: 1)

                paneContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }
        }
        .frame(minWidth: 660, idealWidth: 780, minHeight: 440, idealHeight: 560)
        .background(PlainwordTheme.canvas)
        .foregroundStyle(PlainwordTheme.textPrimary)
        .tint(PlainwordTheme.accent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    LLMCallStatusBadge(entry: entry)
                    Text(entry.request.model)
                        .font(.system(size: 15, weight: .semibold))
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Text(startedAtLabel + " · " + entry.transportSummary)
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.textSecondary)
            }

            Spacer(minLength: 12)

            Button("Done", action: onClose)
                .buttonStyle(PlainwordButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                .help("Close this call and return to the list")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// A native list, so arrow keys move between sections and VoiceOver reports the
    /// selection without any of it having to be reimplemented.
    private var sectionRail: some View {
        List(selection: $pane) {
            railRow(.overview, title: "Overview")

            if !entry.request.messages.isEmpty {
                Section("Prompt") {
                    ForEach(Array(entry.request.messages.enumerated()), id: \.offset) {
                        index, message in
                        railRow(
                            .message(index),
                            title: message.role.capitalized,
                            detail: compactCount(message.content)
                        )
                    }
                }
            }

            Section("Result") {
                railRow(.response, title: "Response", detail: responseCountLabel)
                railRow(
                    .payload,
                    title: "Raw JSON",
                    detail: compactCount(entry.request.payloadJSON)
                )
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(PlainwordTheme.sidebar.opacity(0.6))
        .frame(width: 186)
        .accessibilityLabel("Call sections")
    }

    private func railRow(
        _ pane: Pane,
        title: String,
        detail: String? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: pane.symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 15)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PlainwordTheme.textTertiary)
            }
        }
        .tag(pane)
        .accessibilityLabel(detail.map { "\(title), \($0) characters" } ?? title)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .overview:
            overviewPane
        case .message(let index):
            messagePane(at: index)
        case .response:
            responsePane
        case .payload:
            DebugPayloadPane(
                title: "Request payload",
                text: prettyPrintedJSON(entry.request.payloadJSON)
            )
        }
    }

    private var overviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let failureMessage = entry.failureMessage {
                    failureBanner(failureMessage)
                }

                metadataCard

                if !entry.request.messages.isEmpty {
                    messageIndexCard
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private func failureBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(PlainwordTheme.danger)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                PlainwordTheme.danger.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityLabel("Error: \(message)")
    }

    private var metadataCard: some View {
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
        .background(
            PlainwordTheme.raisedSurface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(PlainwordTheme.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Message sizes up front, so a large prompt is a known quantity before it is opened.
    private var messageIndexCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionLabel("Messages")
            ForEach(Array(entry.request.messages.enumerated()), id: \.offset) { index, message in
                Button {
                    pane = .message(index)
                } label: {
                    HStack(spacing: 8) {
                        Text(message.role.capitalized)
                            .font(.system(size: 12, weight: .medium))
                        Text(characterCountLabel(message.content))
                            .font(.caption)
                            .foregroundStyle(PlainwordTheme.textSecondary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PlainwordTheme.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(
                    PlainwordTheme.raisedSurface.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .accessibilityLabel(
                    "\(message.role.capitalized) message, \(characterCountLabel(message.content))"
                )
                .accessibilityHint("Opens this message")
            }
        }
    }

    @ViewBuilder
    private func messagePane(at index: Int) -> some View {
        if entry.request.messages.indices.contains(index) {
            let message = entry.request.messages[index]
            DebugPayloadPane(
                title: message.role.capitalized + " message",
                text: message.content
            )
        } else {
            placeholder("This message is no longer recorded.")
        }
    }

    @ViewBuilder
    private var responsePane: some View {
        switch entry.state {
        case .inProgress:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the provider…")
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)

        case .succeeded, .failed:
            let body = entry.responseBody ?? ""
            if body.isEmpty {
                placeholder("The provider returned no response body.")
            } else {
                DebugPayloadPane(title: "Provider response", text: prettyPrintedJSON(body))
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(PlainwordTheme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func characterCountLabel(_ text: String) -> String {
        let count = text.count
        return "\(count.formatted()) " + (count == 1 ? "character" : "characters")
    }

    /// Sizes have to fit beside a role name in the rail, so thousands are abbreviated.
    private func compactCount(_ text: String) -> String {
        let count = text.count
        guard count >= 1_000 else { return "\(count)" }
        return String(format: "%.1fk", Double(count) / 1_000)
    }

    private var responseCountLabel: String? {
        guard let responseBody = entry.responseBody, !responseBody.isEmpty else { return nil }
        return compactCount(responseBody)
    }

    private var startedAtLabel: String {
        entry.request.startedAt.formatted(date: .omitted, time: .standard)
    }
}
