import PlainwordCore
import SwiftUI

struct LLMDebugSettingsView: View {
    @ObservedObject var logStore: LLMDebugLogStore

    private enum Scope: String, CaseIterable, Identifiable {
        case all
        case failures

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .failures: "Failures"
            }
        }
    }

    @State private var scope: Scope = .all
    @State private var inspectedCallID: UUID?

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Debug",
                subtitle: "Inspect the exact prompts and responses used for suggestions.",
                icon: "ladybug"
            )

            VStack(alignment: .leading, spacing: 10) {
                listHeader
                privacyNotice

                if logStore.entries.isEmpty {
                    emptyState(
                        icon: "text.magnifyingglass",
                        title: "No LLM calls yet",
                        message: "Review or transform some text, or test your provider connection."
                    )
                } else if visibleEntries.isEmpty {
                    emptyState(
                        icon: "checkmark.circle",
                        title: "No failed calls",
                        message: "Every recorded call came back successfully."
                    )
                } else {
                    // Rows are a fixed height now that payloads open in a sheet, so the
                    // list can stay lazy without the scroll position jumping around.
                    LazyVStack(spacing: 9) {
                        ForEach(visibleEntries) { entry in
                            LLMCallRow(entry: entry) {
                                inspectedCallID = entry.id
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Debug")
        .sheet(isPresented: isInspecting) {
            if let entry = inspectedCall {
                LLMCallDetailView(entry: entry) {
                    inspectedCallID = nil
                }
            } else {
                clearedCallNotice
            }
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                SettingsSectionLabel("LLM calls")
                Spacer()
                Text(callCountLabel)
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.textSecondary)
                Button("Clear") {
                    logStore.clear()
                    inspectedCallID = nil
                }
                .buttonStyle(PlainwordButtonStyle(.quiet))
                .disabled(logStore.entries.isEmpty)
                .help("Remove every recorded call from this session")
            }

            if !logStore.entries.isEmpty {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scopeTitle(scope)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240, alignment: .leading)
                .accessibilityLabel("Filter calls")
            }
        }
    }

    /// Deliberately a single quiet line: the reassurance matters, the detail does not
    /// need to outweigh the calls it sits above. The rest lives in the tooltip.
    private var privacyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "memorychip")
                .font(.system(size: 10, weight: .medium))
                .accessibilityHidden(true)
            Text("Kept in memory for this session. API keys and auth headers are never recorded.")
        }
        .font(.caption)
        .foregroundStyle(PlainwordTheme.textSecondary)
        .help(
            "The newest 100 calls are kept until Plainword quits or you clear them. "
                + "API keys and authentication headers are never recorded. Endpoint "
                + "query values are redacted. Prompts may contain your writing and "
                + "visible application context."
        )
        .accessibilityElement(children: .combine)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(PlainwordTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .plainwordGlass(cornerRadius: PlainwordTheme.cardCornerRadius, shadow: true)
        .accessibilityElement(children: .combine)
    }

    private var clearedCallNotice: some View {
        VStack(spacing: 12) {
            Text("This call is no longer recorded.")
                .font(.system(size: 13, weight: .medium))
            Button("Done") { inspectedCallID = nil }
                .buttonStyle(PlainwordButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(minWidth: 320)
        .background(PlainwordTheme.canvas)
    }

    private var visibleEntries: [LLMDebugLogEntry] {
        switch scope {
        case .all: logStore.entries
        case .failures: logStore.entries.filter(\.isFailure)
        }
    }

    private var inspectedCall: LLMDebugLogEntry? {
        logStore.entries.first { $0.id == inspectedCallID }
    }

    private var isInspecting: Binding<Bool> {
        Binding(
            get: { inspectedCallID != nil },
            set: { isPresented in
                if !isPresented { inspectedCallID = nil }
            }
        )
    }

    private func scopeTitle(_ scope: Scope) -> String {
        switch scope {
        case .all:
            "\(scope.title) (\(logStore.entries.count))"
        case .failures:
            "\(scope.title) (\(logStore.entries.filter(\.isFailure).count))"
        }
    }

    private var callCountLabel: String {
        "\(logStore.entries.count) " + (logStore.entries.count == 1 ? "call" : "calls")
    }
}

/// One call in the list: a whole-card button that opens the inspector.
///
/// The card is the target, rather than a disclosure triangle, so the click area matches
/// what the row looks like and the row never grows to swallow the page.
private struct LLMCallRow: View {
    let entry: LLMDebugLogEntry
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 11) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        LLMCallStatusBadge(entry: entry)
                        Text(entry.request.model)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(entry.request.startedAt, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PlainwordTheme.textSecondary)
                    }

                    if let subject = entry.subjectPreview {
                        Text("\u{201C}" + subject + "\u{201D}")
                            .font(.system(size: 12))
                            .foregroundStyle(PlainwordTheme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let failureMessage = entry.failureMessage {
                        Text(failureMessage)
                            .font(.caption)
                            .foregroundStyle(PlainwordTheme.danger)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if case .inProgress = entry.state {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        }
                        Text(entry.listSummary)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.textTertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        isHovering ? PlainwordTheme.accent : PlainwordTheme.textTertiary
                    )
                    .accessibilityHidden(true)
            }
            .padding(13)
            .contentShape(
                RoundedRectangle(cornerRadius: PlainwordTheme.cardCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .background {
            if isHovering {
                RoundedRectangle(
                    cornerRadius: PlainwordTheme.cardCornerRadius,
                    style: .continuous
                )
                .fill(PlainwordTheme.accent.opacity(0.06))
            }
        }
        .plainwordGlass(cornerRadius: PlainwordTheme.cardCornerRadius, shadow: true)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens the full request and response for this call")
        .help("Open this call")
    }

    private var accessibilityLabel: String {
        var parts = [
            entry.statusDescription,
            entry.request.model,
            entry.request.startedAt.formatted(date: .omitted, time: .standard),
            entry.listSummary
        ]
        if let subject = entry.subjectPreview {
            parts.append("Text: " + subject)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
