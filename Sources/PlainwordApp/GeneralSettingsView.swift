import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var corrections: CrossAppCorrectionController
    @State private var exclusionErrorMessage = ""
    @State private var isShowingExclusionError = false

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "General",
                subtitle: "Control when and where Plainword helps."
            )

            SettingsSection("Setup") {
                SettingsRow(
                    "Provider",
                    detail: "The language model that powers your suggestions."
                ) {
                    StatusPill(
                        title: settings.isLLMConfigured ? "Configured" : "Not configured",
                        color: settings.isLLMConfigured
                            ? PlainwordTheme.accent
                            : PlainwordTheme.warning,
                        systemImage: settings.isLLMConfigured ? "checkmark" : "exclamationmark",
                        wash: settings.isLLMConfigured
                            ? PlainwordTheme.accentMuted
                            : PlainwordTheme.fieldSurface
                    )
                }

                SettingsDivider()

                SettingsRow(
                    "Accessibility",
                    detail: "Lets Plainword read the focused text and nearby context, "
                        + "and replace only the focused text."
                ) {
                    if corrections.isAccessibilityTrusted {
                        StatusPill(
                            title: "Allowed",
                            color: PlainwordTheme.accent,
                            systemImage: "checkmark",
                            wash: PlainwordTheme.accentMuted
                        )
                    } else {
                        HStack(spacing: 8) {
                            Button("Allow Access") {
                                corrections.requestAccessibilityAccess()
                            }
                            .buttonStyle(PlainwordButtonStyle(.primary))

                            Button("Open Settings") {
                                corrections.openAccessibilitySettings()
                            }
                            .buttonStyle(PlainwordButtonStyle())
                        }
                    }
                }
            }

            SettingsSection("Suggestions") {
                SettingsRow(
                    "Suggestions",
                    detail: "Enable explicit review and transform shortcuts."
                ) {
                    Toggle("Suggestions", isOn: listeningBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(PlainwordTheme.accent)
                }

                SettingsDivider()

                SettingsRow(
                    "Review text",
                    detail: "Requests a correction for the selection or current paragraph."
                ) {
                    PopoverShortcutRecorder(
                        shortcut: $settings.popoverShortcut,
                        conflictingShortcut: settings.transformShortcut
                    )
                }

                SettingsDivider()

                SettingsRow(
                    "Transform text",
                    detail: "Opens transform mode for the selection or whole focused field."
                ) {
                    PopoverShortcutRecorder(
                        shortcut: $settings.transformShortcut,
                        conflictingShortcut: settings.popoverShortcut
                    )
                }

                SettingsDivider()

                SettingsRow("Status") {
                    StatusPill(
                        title: corrections.activity.label,
                        color: statusColor,
                        wash: isListening ? PlainwordTheme.accentMuted : PlainwordTheme.fieldSurface
                    )
                }
            }

            SettingsSection("Appearance") {
                SettingsRow("Theme", detail: "Choose how Plainword appears.") {
                    PlainwordSegmentedControl(
                        segments: AppAppearance.allCases.map {
                            PlainwordSegment($0, $0.title)
                        },
                        selection: $settings.appearance,
                        accessibilityLabel: "Theme"
                    )
                }

                SettingsDivider()

                SettingsRow(
                    "Show in Dock",
                    detail: "Turn this off to keep Plainword out of the Dock and the "
                        + "app switcher. The menu-bar item stays."
                ) {
                    Toggle("Show in Dock", isOn: $settings.showsDockIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(PlainwordTheme.accent)
                }
            }

            SettingsSection("Excluded apps") {
                if corrections.excludedApplications.isEmpty {
                    SettingsRow(
                        "No excluded apps",
                        detail: "Use the menu-bar item while another app is active to ignore it."
                    ) {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(corrections.excludedApplications.enumerated()), id: \.element.id) {
                        index, application in
                        ExcludedApplicationRow(
                            application: application,
                            icon: corrections.icon(for: application)
                        ) {
                            corrections.allowSuggestions(in: application)
                        }

                        if index < corrections.excludedApplications.count - 1 {
                            SettingsDivider()
                        }
                    }
                }

                SettingsDivider()

                SettingsRow(
                    "Add an app",
                    detail: "Choose an installed app that Plainword should ignore."
                ) {
                    Button("Add App…") {
                        chooseApplicationToExclude()
                    }
                    .buttonStyle(PlainwordButtonStyle())
                }
            }
        }
        .animation(PlainwordMotion.content, value: settings.appearance)
        .alert("Couldn’t Add App", isPresented: $isShowingExclusionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exclusionErrorMessage)
        }
    }

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { corrections.isListeningEnabled },
            set: { corrections.setListeningEnabled($0) }
        )
    }

    private var isListening: Bool {
        corrections.isListeningEnabled
            && !corrections.isActiveApplicationExcluded
            && corrections.isReady
    }

    private var statusColor: Color {
        if !corrections.isListeningEnabled { return PlainwordTheme.textTertiary }
        if corrections.isActiveApplicationExcluded { return PlainwordTheme.textTertiary }
        return corrections.isReady ? PlainwordTheme.accent : PlainwordTheme.warning
    }

    private func chooseApplicationToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App to Ignore"
        panel.prompt = "Ignore App"
        panel.message = "Plainword will not read or suggest changes in this application."
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard let settingsWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            showExclusionError("The settings window is not available.")
            return
        }

        panel.beginSheetModal(for: settingsWindow) { response in
            guard response == .OK, let applicationURL = panel.url else { return }
            Task { @MainActor in
                do {
                    try corrections.excludeApplication(at: applicationURL)
                } catch {
                    showExclusionError(error.localizedDescription)
                }
            }
        }
    }

    private func showExclusionError(_ message: String) {
        exclusionErrorMessage = message
        isShowingExclusionError = true
    }
}

struct PopoverShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let keyLabel: String

    static let defaultReview = PopoverShortcut(
        keyCode: 120,
        modifiers: NSEvent.ModifierFlags.command.rawValue,
        keyLabel: "F2"
    )

    static let defaultTransform = PopoverShortcut(
        keyCode: 120,
        modifiers: NSEvent.ModifierFlags.command.union(.shift).rawValue,
        keyLabel: "F2"
    )

    var displayText: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && Self.shortcutModifiers(in: event) == modifiers
    }

    static func make(from event: NSEvent) -> PopoverShortcut? {
        let modifiers = shortcutModifiers(in: event)
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        guard !flags.isDisjoint(with: [.command, .control, .option]),
              let keyLabel = keyLabel(for: event) else {
            return nil
        }
        return PopoverShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            keyLabel: keyLabel
        )
    }

    var isReservedApplyShortcut: Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return flags == .command && (keyLabel == "↩" || keyLabel == "⌅")
    }

    private static func shortcutModifiers(in event: NSEvent) -> UInt {
        event.modifierFlags
            .intersection([.command, .control, .option, .shift])
            .rawValue
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        if event.keyCode == 53 { return "⎋" }
        if event.keyCode == 49 { return "Space" }

        switch event.specialKey {
        case .carriageReturn: return "↩"
        case .enter: return "⌅"
        case .tab: return "⇥"
        case .backTab: return "⇤"
        case .backspace: return "⌫"
        case .delete: return "⌦"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        case .some(let key):
            let rawValue = key.rawValue
            if rawValue >= NSEvent.SpecialKey.f1.rawValue,
               rawValue <= NSEvent.SpecialKey.f35.rawValue {
                return "F\(rawValue - NSEvent.SpecialKey.f1.rawValue + 1)"
            }
        case .none:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !characters.isEmpty else {
            return nil
        }
        return characters.uppercased()
    }
}

/// A shortcut that reads as a key: the recorder is the keycap itself, so the row
/// shows the binding rather than a control that talks about it.
private struct PopoverShortcutRecorder: View {
    @Binding var shortcut: PopoverShortcut?
    let conflictingShortcut: PopoverShortcut?
    @StateObject private var recorder = PopoverShortcutRecorderController()
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if recorder.isRecording {
                        recorder.cancel()
                    } else {
                        recorder.begin(conflictingShortcut: conflictingShortcut) {
                            shortcut = $0
                        }
                    }
                } label: {
                    keycap
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .help("Click to record a new shortcut")
                .accessibilityLabel("Review shortcut")
                .accessibilityValue(shortcut?.displayText ?? "None")

                if shortcut != nil, !recorder.isRecording {
                    Button {
                        shortcut = nil
                        recorder.clearError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(PlainwordFont.ui(10, weight: .bold))
                    }
                    .buttonStyle(PlainwordButtonStyle(.quiet))
                    .help("Clear shortcut")
                    .accessibilityLabel("Clear shortcut")
                }
            }

            if let errorMessage = recorder.errorMessage {
                Text(errorMessage)
                    .font(PlainwordFont.ui(10))
                    .foregroundStyle(PlainwordTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(PlainwordMotion.content, value: recorder.isRecording)
        .onDisappear { recorder.cancel() }
    }

    private var keycap: some View {
        HStack(spacing: 6) {
            if recorder.isRecording {
                Circle()
                    .fill(PlainwordTheme.accent)
                    .frame(width: 6, height: 6)
            }
            Text(recorder.isRecording
                ? "Press shortcut…"
                : shortcut?.displayText ?? "Record")
                .font(PlainwordFont.mono(12))
                .foregroundStyle(
                    recorder.isRecording
                        ? PlainwordTheme.accent
                        : PlainwordTheme.textPrimary
                )
        }
        .frame(minWidth: 46)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            recorder.isRecording
                ? PlainwordTheme.accentMuted
                : (isHovering ? PlainwordTheme.raisedSurface : PlainwordTheme.fieldSurface),
            in: RoundedRectangle(cornerRadius: PlainwordTheme.pillCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PlainwordTheme.pillCornerRadius, style: .continuous)
                .strokeBorder(
                    recorder.isRecording
                        ? PlainwordTheme.accent
                        : PlainwordTheme.strongSeparator,
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
    }
}

@MainActor
private final class PopoverShortcutRecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?

    private var keyMonitor: Any?
    private var onRecord: ((PopoverShortcut?) -> Void)?
    private var conflictingShortcut: PopoverShortcut?

    func begin(
        conflictingShortcut: PopoverShortcut?,
        onRecord: @escaping (PopoverShortcut?) -> Void
    ) {
        cancel()
        self.onRecord = onRecord
        self.conflictingShortcut = conflictingShortcut
        errorMessage = nil
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.capture(event)
            }
            return nil
        }
    }

    func cancel() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        onRecord = nil
        conflictingShortcut = nil
        isRecording = false
    }

    func clearError() {
        errorMessage = nil
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancel()
            return
        }

        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (event.specialKey == .backspace || event.specialKey == .delete), flags.isEmpty {
            let completion = onRecord
            cancel()
            completion?(nil)
            return
        }

        guard let shortcut = PopoverShortcut.make(from: event) else {
            errorMessage = "Use ⌘, ⌥, or ⌃ with another key."
            return
        }
        guard !shortcut.isReservedApplyShortcut else {
            errorMessage = "⌘↩ is reserved for applying a suggestion."
            return
        }
        if shortcut == conflictingShortcut {
            errorMessage = "Choose a different shortcut for each action."
            return
        }

        let completion = onRecord
        cancel()
        completion?(shortcut)
    }
}

private struct ExcludedApplicationRow: View {
    let application: ExcludedApplication
    let icon: NSImage?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app")
                        .foregroundStyle(PlainwordTheme.textTertiary)
                }
            }
            .frame(width: 21, height: 21)

            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .font(PlainwordFont.ui(13, weight: .bold))
                Text(application.id)
                    .font(PlainwordFont.mono(10))
                    .foregroundStyle(PlainwordTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            Button("Remove") {
                onRemove()
            }
            .buttonStyle(PlainwordButtonStyle(.danger))
        }
        .frame(minHeight: 48)
        .padding(.vertical, PlainwordTheme.settingsRowVerticalPadding)
    }
}
