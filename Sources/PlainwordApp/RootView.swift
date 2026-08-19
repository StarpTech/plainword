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

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .provider: "server.rack"
            case .writing: "pencil.and.outline"
            case .debug: "ladybug"
            }
        }
    }

    @EnvironmentObject private var settings: SettingsStore
    @State private var selection: AppSection = .general
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        ZStack {
            PlainwordBackdrop()

            NavigationSplitView(columnVisibility: $columnVisibility) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        PlainwordBrandMark(size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Plainword")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(PlainwordTheme.textPrimary)
                            Text("Writing assistant")
                                .font(.system(size: 10))
                                .foregroundStyle(PlainwordTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 15)

                    Rectangle()
                        .fill(PlainwordTheme.separator.opacity(0.55))
                        .frame(height: 1)
                        .padding(.horizontal, 10)

                    VStack(spacing: 5) {
                        ForEach(AppSection.allCases) { section in
                            sidebarButton(section)
                        }
                    }
                    .padding(9)

                    Spacer(minLength: 16)
                }
                .background(PlainwordTheme.sidebar)
                .navigationSplitViewColumnWidth(min: 170, ideal: 188, max: 205)
            } detail: {
                detailView
                    .background(.clear)
            }
            .background(.clear)
            .navigationSplitViewStyle(.balanced)
            .tint(PlainwordTheme.accent)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func sidebarButton(_ section: AppSection) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(
                selection == section
                    ? PlainwordTheme.textPrimary
                    : PlainwordTheme.textSecondary
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background {
                if selection == section {
                    Color.clear
                        .plainwordGlass(
                            cornerRadius: 10,
                            tint: PlainwordTheme.accent.opacity(0.13),
                            interactive: true,
                            shadow: true
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
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
