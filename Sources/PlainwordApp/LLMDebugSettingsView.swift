import PlainwordCore
import SwiftUI

struct LLMDebugSettingsView: View {
    @ObservedObject var logStore: LLMDebugLogStore
    @EnvironmentObject private var corrections: CrossAppCorrectionController

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
    @State private var recordingCountdown: Int?
    @State private var recordingStatus: String?

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Debug",
                subtitle: "Inspect the exact prompts and responses used for suggestions."
            )

            VStack(alignment: .leading, spacing: 12) {
                listHeader
                privacyNotice

                if let recordingStatus {
                    Text(recordingStatus)
                        .font(PlainwordFont.ui(11))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .textSelection(.enabled)
                }

                if logStore.entries.isEmpty {
                    emptyState(
                        title: "No LLM calls yet",
                        message: "Review or transform some text, or test your provider connection."
                    )
                } else if visibleEntries.isEmpty {
                    emptyState(
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
        HStack(spacing: 10) {
            SettingsSectionLabel("LLM calls")

            if !logStore.entries.isEmpty {
                PlainwordSegmentedControl(
                    segments: Scope.allCases.map { PlainwordSegment($0, scopeTitle($0)) },
                    selection: $scope,
                    accessibilityLabel: "Filter calls"
                )
            }

            Spacer(minLength: 8)

            Text(callCountLabel)
                .font(PlainwordFont.ui(11))
                .foregroundStyle(PlainwordTheme.textSecondary)

            recordTreeButton

            Button("Clear") {
                logStore.clear()
                inspectedCallID = nil
            }
            .buttonStyle(PlainwordButtonStyle(.quiet))
            .disabled(logStore.entries.isEmpty)
            .help("Remove every recorded call from this session")
        }
    }

    /// Captures the accessibility tree of whatever the author is writing in, so the
    /// context pipeline can be replayed against it offline.
    ///
    /// The countdown exists because pressing this moves focus here. Without it the
    /// recording would faithfully capture this settings window.
    private var recordTreeButton: some View {
        Button(recordingCountdown.map { "Recording in \($0)…" } ?? "Record tree") {
            startRecording()
        }
        .buttonStyle(PlainwordButtonStyle(.quiet))
        .disabled(recordingCountdown != nil)
        .help(
            """
            Switch to the app you are writing in. After five seconds Plainword records \
            what that app exposes about the focused field and offers to save it.
            """
        )
    }

    private func startRecording() {
        recordingStatus = nil
        recordingCountdown = 5
        Task { @MainActor in
            while let remaining = recordingCountdown, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                recordingCountdown = remaining - 1
            }
            recordingCountdown = nil
            recordingStatus = corrections.recordAccessibilityFixture(scenario: "capture")
        }
    }

    /// Deliberately a single quiet line: the reassurance matters, the detail does not
    /// need to outweigh the calls it sits above. The rest lives in the tooltip.
    private var privacyNotice: some View {
        HStack(spacing: 6) {
            Text(verbatim: "⌗")
                .font(PlainwordFont.mono(10))
                .foregroundStyle(PlainwordTheme.textTertiary)
                .accessibilityHidden(true)
            Text("Kept in memory for this session. API keys and auth headers are never recorded.")
                .font(PlainwordFont.ui(11))
        }
        .foregroundStyle(PlainwordTheme.textSecondary)
        .help(
            "The newest 100 calls are kept until Plainword quits or you clear them. "
                + "API keys and authentication headers are never recorded. Endpoint "
                + "query values are redacted. Prompts may contain your writing and "
                + "visible application context."
        )
        .accessibilityElement(children: .combine)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(PlainwordFont.serif(15, weight: .medium))
            Text(message)
                .font(PlainwordFont.ui(11))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .plainwordCard(cornerRadius: PlainwordTheme.cardCornerRadius)
        .accessibilityElement(children: .combine)
    }

    private var clearedCallNotice: some View {
        VStack(spacing: 12) {
            Text("This call is no longer recorded.")
                .font(PlainwordFont.serif(15, weight: .medium))
            Button("Done") { inspectedCallID = nil }
                .buttonStyle(PlainwordButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(minWidth: 320)
        .background(PlainwordTheme.surface)
        .foregroundStyle(PlainwordTheme.textPrimary)
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
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        LLMCallStatusBadge(entry: entry)
                        Text(entry.request.model)
                            .font(PlainwordFont.ui(13, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(entry.request.startedAt, format: .dateTime.hour().minute().second())
                            .font(PlainwordFont.mono(10))
                            .foregroundStyle(PlainwordTheme.textSecondary)
                    }

                    if let subject = entry.subjectPreview {
                        // The author's own words, so they are set the way the author
                        // sees them everywhere else.
                        Text("\u{201C}" + subject + "\u{201D}")
                            .font(PlainwordFont.serif(12.5))
                            .foregroundStyle(PlainwordTheme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let failureMessage = entry.failureMessage {
                        Text(failureMessage)
                            .font(PlainwordFont.ui(11))
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
                    .font(PlainwordFont.ui(11))
                    .foregroundStyle(PlainwordTheme.textTertiary)
                }

                Text(verbatim: "›")
                    .font(PlainwordFont.ui(13))
                    .foregroundStyle(
                        isHovering ? PlainwordTheme.accent : PlainwordTheme.textTertiary
                    )
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(
                RoundedRectangle(cornerRadius: PlainwordTheme.cardCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .plainwordCard(
            cornerRadius: PlainwordTheme.cardCornerRadius,
            fill: isHovering ? PlainwordTheme.raisedSurface : PlainwordTheme.surface,
            border: isHovering ? PlainwordTheme.accent : PlainwordTheme.separator
        )
        .onHover { isHovering = $0 }
        .animation(PlainwordMotion.content, value: isHovering)
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
