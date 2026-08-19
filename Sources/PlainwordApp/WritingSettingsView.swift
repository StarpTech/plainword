import PlainwordCore
import SwiftUI

struct WritingSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Writing",
                subtitle: "Shape the voice of suggestions without changing your meaning.",
                icon: "pencil.and.outline"
            )

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("Voice")
                SettingsGroup {
                    SettingsRow(
                        "Tone",
                        icon: "quote.bubble",
                        detail: "The emotional character of suggestions."
                    ) {
                        Picker("Tone", selection: $settings.tone) {
                            ForEach(Tone.allCases) { tone in
                                Text(tone.displayName).tag(tone)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.large)
                        .frame(width: 190, alignment: .trailing)
                    }

                    SettingsDivider()

                    SettingsRow(
                        "Style",
                        icon: "textformat",
                        detail: "How suggestions are phrased and structured."
                    ) {
                        Picker("Style", selection: $settings.style) {
                            ForEach(WritingStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.large)
                        .frame(width: 190, alignment: .trailing)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("Language")
                SettingsGroup {
                    SettingsRow(
                        "Writing language",
                        icon: "character.book.closed",
                        detail: spellingModeDetail
                    ) {
                        Picker("Writing language", selection: $settings.spellingLanguageMode) {
                            ForEach(SpellingLanguageMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.large)
                        .frame(width: 190, alignment: .trailing)
                    }

                    if settings.spellingLanguageMode == .fixed {
                        SettingsDivider()

                        SettingsRow(
                            "Language",
                            icon: "text.book.closed",
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
                            .controlSize(.large)
                            .frame(width: 190, alignment: .trailing)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("Prompt")
                SettingsGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Additional instructions")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Appended to every writing request.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(PlainwordTheme.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "text.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(PlainwordTheme.accent)
                                .frame(width: 28, height: 28)
                                .background(
                                    PlainwordTheme.accent.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }

                        TextField(
                            "For example: Prefer British English and avoid semicolons.",
                            text: $settings.promptExtension,
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .lineLimit(3...8)
                        .padding(10)
                        .background(
                            PlainwordTheme.fieldSurface,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(PlainwordTheme.separator.opacity(0.8), lineWidth: 1)
                        }
                        .accessibilityLabel("Additional writing instructions")
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("Writing")
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
