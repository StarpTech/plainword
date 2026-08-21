import AppKit
import SwiftUI

struct RootView: View {
    private enum AppSection: String, CaseIterable, Identifiable {
        case general
        case provider
        case writing
        case debug

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .provider: "Provider"
            case .writing: "Writing"
            case .debug: "Debug"
            }
        }

        /// SF Symbols rather than the handoff's typographic marks: those characters
        /// come from whichever font on the system happens to carry them, so they
        /// arrive at inconsistent weights and far below their nominal size.
        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .provider: "bolt.horizontal"
            case .writing: "pencil"
            case .debug: "number"
            }
        }
    }

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: AppSection = .general
    @State private var isHoveringIssueLink = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(width: 1)

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PlainwordTheme.surface)
        }
        .background(PlainwordTheme.surface)
        .tint(PlainwordTheme.accent)
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Room for the window's own traffic lights, which sit over this column.
            Color.clear
                .frame(height: 30)

            HStack(spacing: 10) {
                PlainwordBrandMark(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plainword")
                        .font(PlainwordFont.serif(15.5, weight: .medium))
                        .foregroundStyle(PlainwordTheme.textPrimary)
                    Text("Writing assistant")
                        .font(PlainwordFont.ui(10))
                        .foregroundStyle(PlainwordTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)
                .padding(.horizontal, 12)

            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { section in
                    sidebarButton(section)
                }
            }
            .padding(10)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 7) {
                reportIssueButton

                Text(versionLabel)
                    .font(PlainwordFont.mono(9.5))
                    .foregroundStyle(PlainwordTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 196)
        .background(PlainwordTheme.raisedSurface)
    }

    /// Deliberately quiet: this belongs beside the version number, as something to
    /// reach for when the app misbehaves, not a fifth item competing with navigation.
    private var reportIssueButton: some View {
        Button {
            NSWorkspace.shared.open(Self.issueURL)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 10, weight: .medium))
                Text("Report an issue")
                    .font(PlainwordFont.ui(10.5))
            }
            .foregroundStyle(
                isHoveringIssueLink
                    ? PlainwordTheme.textSecondary
                    : PlainwordTheme.textTertiary
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringIssueLink = $0 }
        .animation(PlainwordMotion.content, value: isHoveringIssueLink)
        .help("Open a new issue on the Plainword repository")
        .accessibilityHint("Opens GitHub in your browser")
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(
                        isSelected ? PlainwordTheme.accent : PlainwordTheme.textTertiary
                    )
                Text(section.title)
                    .font(PlainwordFont.ui(13, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? PlainwordTheme.textPrimary : PlainwordTheme.textSecondary
                    )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    selectedBackground
                }
            }
        }
        .buttonStyle(.plain)
        .animation(PlainwordMotion.content, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// In the light the selected item is a lifted sheet, and a soft shadow says so.
    /// Dark mode uses a quiet neutral wash instead: navigation selection stays
    /// distinct without competing with green's enabled and active-state meaning.
    @ViewBuilder
    private var selectedBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: PlainwordTheme.controlCornerRadius,
            style: .continuous
        )
        if colorScheme == .dark {
            shape
                .fill(PlainwordTheme.selectedSurface)
        } else {
            shape
                .fill(PlainwordTheme.surface)
                .shadow(
                    color: Color(
                        nsColor: PlainwordTheme.adaptiveNSColor(
                            light: 0x48381C,
                            dark: 0x000000,
                            lightAlpha: 0.1,
                            darkAlpha: 0.2
                        )
                    ),
                    radius: 2.5,
                    x: 0,
                    y: 1
                )
        }
    }

    private static let issueURL = URL(
        string: "https://github.com/StarpTech/plainword/issues/new"
    )!

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String
        return "v" + (version ?? "1.0.0")
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
        case .provider:
            ProviderSettingsView()
        case .writing:
            WritingSettingsView()
        case .debug:
            LLMDebugSettingsView(logStore: settings.llmDebugLog)
        }
    }
}
