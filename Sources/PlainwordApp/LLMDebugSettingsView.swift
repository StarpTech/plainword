import AppKit
import PlainwordCore
import SwiftUI

struct LLMDebugSettingsView: View {
    @ObservedObject var logStore: LLMDebugLogStore

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Debug",
                subtitle: "Inspect the exact prompts and responses used for suggestions.",
                icon: "ladybug"
            )

            privacyNotice

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SettingsSectionLabel("LLM calls")
                    Spacer()
                    Text(callCountLabel)
                        .font(.caption)
                        .foregroundStyle(PlainwordTheme.textSecondary)
                    Button("Clear") {
                        logStore.clear()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PlainwordTheme.accent)
                    .disabled(logStore.entries.isEmpty)
                }

                if logStore.entries.isEmpty {
                    emptyState
                } else {
                    // Debug rows can grow substantially when their payloads are expanded.
                    // Keeping their layout alive prevents LazyVStack from changing its
                    // height estimate mid-scroll and making the scroll position jump.
                    VStack(spacing: 10) {
                        ForEach(logStore.entries) { entry in
                            LLMCallDebugView(entry: entry)
                        }
                    }
                }
            }
        }
        .navigationTitle("Debug")
    }

    private var privacyNotice: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "memorychip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PlainwordTheme.accent)
                .frame(width: 28, height: 28)
                .background(
                    PlainwordTheme.accent.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Stored in memory for this session")
                    .font(.system(size: 13, weight: .medium))
                Text(
                    "The newest 100 calls are kept until Plainword quits or you clear them. "
                        + "API keys and authentication headers are never recorded. Endpoint "
                        + "query values are redacted. Prompts may contain your writing and "
                        + "visible application context."
                )
                .font(.caption)
                .foregroundStyle(PlainwordTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .plainwordGlass(cornerRadius: PlainwordTheme.cornerRadius, shadow: true)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(PlainwordTheme.textSecondary)
            Text("No LLM calls yet")
                .font(.system(size: 14, weight: .medium))
            Text("Review or transform some text, or test your provider connection.")
                .font(.caption)
                .foregroundStyle(PlainwordTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .plainwordGlass(cornerRadius: PlainwordTheme.cardCornerRadius, shadow: true)
    }

    private var callCountLabel: String {
        "\(logStore.entries.count) " + (logStore.entries.count == 1 ? "call" : "calls")
    }
}

private struct LLMCallDebugView: View {
    let entry: LLMDebugLogEntry

    @State private var isExpanded = false
    @State private var showsRawPayload = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                metadata

                ForEach(Array(entry.request.messages.enumerated()), id: \.offset) {
                    _, message in
                    debugTextBlock(
                        title: message.role.capitalized + " message",
                        text: message.content
                    )
                }

                DisclosureGroup("Raw JSON payload", isExpanded: $showsRawPayload) {
                    debugTextBlock(
                        title: "Request payload",
                        text: entry.request.payloadJSON
                    )
                    .padding(.top, 8)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PlainwordTheme.textSecondary)

                responseSection
            }
            .padding(.top, 14)
        } label: {
            callHeader
        }
        .padding(14)
        .plainwordGlass(cornerRadius: PlainwordTheme.cardCornerRadius, shadow: true)
    }

    private var callHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                statusBadge
                Text(entry.request.model)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(entry.request.startedAt, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PlainwordTheme.textSecondary)
            }

            HStack(spacing: 7) {
                Text(entry.request.isStreaming ? "Streaming" : "Standard")
                Text("·")
                Text(entry.request.reasoningEffort.capitalized + " thinking")
                if let duration = entry.duration {
                    Text("·")
                    Text(String(format: "%.2f s", duration))
                }
            }
            .font(.caption)
            .foregroundStyle(PlainwordTheme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            metadataRow("Endpoint", value: entry.request.endpoint)
            metadataRow("Model", value: entry.request.model)
            metadataRow("Reasoning", value: entry.request.reasoningEffort)
            metadataRow("Transport", value: entry.request.isStreaming ? "SSE stream" : "JSON")
            if let usage = entry.tokenUsage {
                metadataRow("Tokens", value: tokenUsageDescription(usage))
                metadataRow("Cache", value: cacheUsageDescription(usage))
            }
        }
        .padding(11)
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
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tokenUsageDescription(_ usage: LLMTokenUsage) -> String {
        var parts: [String] = []
        if let inputTokens = usage.inputTokens {
            parts.append("\(inputTokens.formatted()) input")
        }
        if let outputTokens = usage.outputTokens {
            parts.append("\(outputTokens.formatted()) output")
        }
        if let totalTokens = usage.totalTokens {
            parts.append("\(totalTokens.formatted()) total")
        }
        return parts.isEmpty ? "Not reported" : parts.joined(separator: " · ")
    }

    private func cacheUsageDescription(_ usage: LLMTokenUsage) -> String {
        let reads = usage.cacheReadTokens.map { $0.formatted() } ?? "Not reported"
        let writes = usage.cacheWriteTokens.map { $0.formatted() } ?? "Not reported"
        return "\(reads) read · \(writes) written"
    }

    @ViewBuilder
    private var responseSection: some View {
        switch entry.state {
        case .inProgress:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the provider…")
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.textSecondary)
            }

        case .succeeded:
            debugTextBlock(
                title: "Provider response",
                text: Self.readableJSON(entry.responseBody ?? "")
            )

        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.danger)
                    .textSelection(.enabled)
                if let responseBody = entry.responseBody, !responseBody.isEmpty {
                    debugTextBlock(
                        title: "Provider response",
                        text: Self.readableJSON(responseBody)
                    )
                }
            }
        }
    }

    private func debugTextBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    copyToPasteboard(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(PlainwordTheme.textSecondary)
            }
            debugText(text)
        }
    }

    private func debugText(_ text: String) -> some View {
        let preview = Self.boundedPreview(of: text)

        return VStack(alignment: .leading, spacing: 8) {
            Text(preview.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PlainwordTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if preview.isTruncated {
                Label(
                    "Preview truncated to keep the debug view responsive. "
                        + "Copy includes the complete contents.",
                    systemImage: "ellipsis.rectangle"
                )
                .font(.caption)
                .foregroundStyle(PlainwordTheme.textSecondary)
            }
        }
        .padding(11)
        .background(
            PlainwordTheme.raisedSurface.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private static func boundedPreview(of text: String) -> (text: String, isTruncated: Bool) {
        guard !text.isEmpty else {
            return ("<empty>", false)
        }

        let maximumCharacterCount = 20_000
        guard let endIndex = text.index(
            text.startIndex,
            offsetBy: maximumCharacterCount,
            limitedBy: text.endIndex
        ) else {
            return (text, false)
        }
        guard endIndex != text.endIndex else {
            return (text, false)
        }

        return (String(text[..<endIndex]), true)
    }

    private var statusBadge: some View {
        Text(statusTitle)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                statusColor.opacity(0.12),
                in: Capsule()
            )
    }

    private var statusTitle: String {
        switch entry.state {
        case .inProgress:
            "Sending"
        case .succeeded(let statusCode):
            "HTTP \(statusCode)"
        case .failed(let statusCode, _):
            statusCode.map { "HTTP \($0)" } ?? "Failed"
        }
    }

    private var statusColor: Color {
        switch entry.state {
        case .inProgress:
            PlainwordTheme.accent
        case .succeeded:
            PlainwordTheme.success
        case .failed:
            PlainwordTheme.danger
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func readableJSON(_ value: String) -> String {
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
}
