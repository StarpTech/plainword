import PlainwordCore
import SwiftUI

struct WritingSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Writing",
                subtitle: "Shape the voice of suggestions without changing your meaning."
            )

            SettingsSection("Voice") {
                // Three choices fit beside their own name, so these read like every
                // other settings row rather than stacking under a full-width control.
                SettingsRow(
                    "Tone",
                    detail: "How suggestions come across to the reader."
                ) {
                    PlainwordSegmentedControl(
                        segments: Tone.allCases.map { PlainwordSegment($0, $0.displayName) },
                        selection: $settings.tone,
                        accessibilityLabel: "Tone"
                    )
                }

                SettingsDivider()

                SettingsRow(
                    "Style",
                    detail: "How much a suggestion says."
                ) {
                    PlainwordSegmentedControl(
                        segments: WritingStyle.allCases.map {
                            PlainwordSegment($0, $0.displayName)
                        },
                        selection: $settings.style,
                        accessibilityLabel: "Style"
                    )
                }
            }

            SettingsSection("Language") {
                SettingsRow("Writing language", detail: spellingModeDetail) {
                    Picker("Writing language", selection: $settings.spellingLanguageMode) {
                        ForEach(SpellingLanguageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(width: 170, alignment: .trailing)
                }

                if settings.spellingLanguageMode == .fixed {
                    SettingsDivider()

                    SettingsRow(
                        "Language",
                        detail: "Uses this language as guidance for reviews."
                    ) {
                        Picker(
                            "Dictionary",
                            selection: $settings.fixedSpellingLanguageIdentifier
                        ) {
                            ForEach(settings.availableSpellingLanguages, id: \.self) { language in
                                Text(settings.spellingLanguageDisplayName(language))
                                    .tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.regular)
                        .frame(width: 170, alignment: .trailing)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                SettingsSectionLabel("Prompt")
                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Additional instructions")
                            .font(PlainwordFont.ui(13, weight: .bold))
                        Text("Appended to every writing request.")
                            .font(PlainwordFont.ui(11))
                            .foregroundStyle(PlainwordTheme.textSecondary)
                    }

                    // Standing instructions are writing, so they are set in the
                    // writing voice rather than the interface's.
                    TextField(
                        "For example: Prefer British English and avoid semicolons.",
                        text: $settings.promptExtension,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(PlainwordFont.serif(13.5))
                    .lineSpacing(3)
                    .lineLimit(3...8)
                    .padding(10)
                    .background(
                        PlainwordTheme.fieldSurface,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(PlainwordTheme.strongSeparator, lineWidth: 1)
                    }
                    .accessibilityLabel("Additional writing instructions")

                    if showsThinkingHint {
                        thinkingHint
                    }
                }
                .animation(PlainwordMotion.content, value: showsThinkingHint)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .plainwordCard(cornerRadius: PlainwordTheme.cardCornerRadius)
            }
        }
        .animation(PlainwordMotion.content, value: settings.spellingLanguageMode)
    }

    /// Instructions are followed more closely when the model reasons about them, but
    /// thinking is off by default so suggestions come back quickly. The trade is only
    /// worth raising once there are instructions for it to follow.
    private var showsThinkingHint: Bool {
        settings.thinkingMode == .off
            && !settings.promptExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    private var thinkingHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb")
                .font(PlainwordFont.ui(11))
                .foregroundStyle(PlainwordTheme.textTertiary)
            Text(
                "Thinking is off so suggestions stay fast. "
                    + "Models follow these instructions more closely with it on."
            )
            .font(PlainwordFont.ui(11))
            .lineSpacing(2)
            .foregroundStyle(PlainwordTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Turn on thinking") {
                settings.thinkingMode = .low
            }
            .buttonStyle(PlainwordButtonStyle(.secondary))
            .help("Sets thinking mode to Low. Provider settings has the full range.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            PlainwordTheme.raisedSurface,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .transition(.opacity)
    }

    private var spellingModeDetail: String {
        switch settings.spellingLanguageMode {
        case .automatic:
            "Detects the reviewed text locally and uses it as model guidance."
        case .fixed:
            "Always uses the selected language as model guidance."
        case .disabled:
            "Does not send language guidance."
        }
    }
}
