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
                // Five tones do not fit beside their own name, so the choice takes the
                // full width of the card rather than being squeezed against the label.
                SettingsStackedRow(
                    "Tone",
                    detail: "The emotional character of suggestions."
                ) {
                    PlainwordSegmentedControl(
                        segments: Tone.allCases.map { PlainwordSegment($0, $0.displayName) },
                        selection: $settings.tone,
                        accessibilityLabel: "Tone"
                    )
                }

                SettingsDivider()

                SettingsStackedRow(
                    "Style",
                    detail: "How suggestions are phrased and structured."
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .plainwordCard(cornerRadius: PlainwordTheme.cardCornerRadius)
            }
        }
        .animation(PlainwordMotion.content, value: settings.spellingLanguageMode)
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
