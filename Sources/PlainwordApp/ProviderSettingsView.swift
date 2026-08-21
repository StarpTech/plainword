import Foundation
import PlainwordCore
import SwiftUI

struct ProviderSettingsView: View {
    private let fieldLabelWidth: CGFloat = 100
    private let fieldSpacing: CGFloat = 12

    private enum Field: Hashable {
        case endpoint
        case model
        case customHeader
        case apiKey
    }

    @EnvironmentObject private var settings: SettingsStore
    @FocusState private var focusedField: Field?

    private var canTest: Bool {
        if settings.provider == .codex {
            return true
        }
        return settings.endpointURL != nil
            && !settings.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!settings.requiresCredential || !settings.apiKey.isEmpty)
    }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Provider",
                subtitle: "The model your suggestions run on."
            )

            providerCards

            VStack(alignment: .leading, spacing: 7) {
                SettingsSectionLabel("Connection")
                SettingsGroup {
                    if settings.provider == .ollama {
                        ollamaConnectionFields
                    } else if settings.provider == .codex {
                        codexConnectionFields
                    } else {
                        compatibleProviderFields
                    }
                }

                if settings.provider == .ollama {
                    ollamaModelsStatus
                } else if settings.provider == .codex {
                    codexStatusNotice
                }
            }

            if settings.provider == .openAICompatible,
               settings.authentication != .none {
                credentialCard
            }

            SettingsSection("Options") {
                SettingsRow(
                    "Thinking mode",
                    detail: "Set reasoning effort for models that support thinking."
                ) {
                    Picker("Thinking mode", selection: $settings.thinkingMode) {
                        ForEach(availableThinkingModes) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(width: 130, alignment: .trailing)
                }

                if settings.provider != .codex {
                    SettingsRow(
                        "Return thinking",
                        detail: "Asks the provider to send the model\u{2019}s reasoning "
                            + "back with the answer, where the call inspector can show "
                            + "it. Gateways such as Vercel AI Gateway and OpenRouter "
                            + "support this; OpenAI\u{2019}s own API rejects the "
                            + "request, so leave it off when pointed straight at it."
                    ) {
                        Toggle("Return thinking", isOn: $settings.includesThinking)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(PlainwordTheme.accent)
                            .disabled(settings.thinkingMode == .off)
                    }
                }
            }

            connectionCard

            Text(
                "Credentials live in the macOS Keychain. "
                    + "With Ollama, your text never leaves this Mac."
            )
            .font(PlainwordFont.ui(11))
            .lineSpacing(2)
            .foregroundStyle(PlainwordTheme.textTertiary)
        }
        .task(id: settings.provider) {
            await settings.loadOllamaModelsIfNeeded()
            await settings.loadCodexStatusIfNeeded()
        }
        .animation(PlainwordMotion.content, value: settings.provider)
        .animation(PlainwordMotion.content, value: settings.authentication)
    }

    /// The provider is the one decision on this page that changes every other one,
    /// so it is shown as three cards rather than hidden inside a menu.
    private var providerCards: some View {
        HStack(spacing: 10) {
            ForEach(LLMProvider.allCases) { provider in
                providerCard(provider)
            }
        }
        // Three cards of one height, so the row reads as one choice rather than as
        // three of differing importance.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func providerCard(_ provider: LLMProvider) -> some View {
        let isSelected = settings.provider == provider
        return Button {
            settings.provider = provider
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(provider.displayName)
                        .font(PlainwordFont.serif(16, weight: .medium))
                        .foregroundStyle(PlainwordTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Circle()
                        .strokeBorder(
                            isSelected
                                ? PlainwordTheme.accent
                                : PlainwordTheme.strongSeparator,
                            lineWidth: 1.5
                        )
                        .background(
                            Circle()
                                .fill(isSelected ? PlainwordTheme.accent : .clear)
                                .padding(3.5)
                        )
                        .frame(width: 14, height: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                Text(blurb(for: provider))
                    .font(PlainwordFont.ui(11))
                    .lineSpacing(1.5)
                    .foregroundStyle(PlainwordTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plainwordCard(
            cornerRadius: PlainwordTheme.cardCornerRadius,
            fill: isSelected ? PlainwordTheme.accentMuted : PlainwordTheme.surface,
            border: isSelected ? PlainwordTheme.accent : PlainwordTheme.separator
        )
        .animation(PlainwordMotion.content, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(provider.displayName)
        .accessibilityHint(blurb(for: provider))
    }

    private func blurb(for provider: LLMProvider) -> String {
        switch provider {
        case .ollama: "A model running on this Mac. Nothing you write leaves it."
        case .codex: "Your ChatGPT account, through the Codex CLI you already signed in to."
        case .openAICompatible: "Any endpoint that speaks chat completions, with your own key."
        }
    }

    private var compatibleProviderFields: some View {
        Group {
            fieldRow("Endpoint") {
                TextField(
                    "https://…/v1/chat/completions",
                    text: $settings.endpoint
                )
                .focused($focusedField, equals: .endpoint)
                .onSubmit { focusedField = .model }
                .plainwordField(isFocused: focusedField == .endpoint, usesMono: true)
            }

            fieldDivider

            fieldRow("Model") {
                TextField("Model identifier", text: $settings.model)
                    .focused($focusedField, equals: .model)
                    .plainwordField(isFocused: focusedField == .model, usesMono: true)
            }

            fieldDivider

            fieldRow("Authentication") {
                Picker("Authentication", selection: $settings.authentication) {
                    ForEach(ProviderAuthentication.allCases) { authentication in
                        Text(authentication.displayName).tag(authentication)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(width: 200)
            }

            if settings.authentication == .customHeader {
                fieldDivider
                fieldRow("Header") {
                    TextField("api-key", text: $settings.customHeaderName)
                        .focused($focusedField, equals: .customHeader)
                        .plainwordField(isFocused: focusedField == .customHeader, usesMono: true)
                }
            }

            if settings.authentication != .none {
                fieldDivider
                fieldRow("API key") {
                    SecureField("Keychain", text: $settings.apiKey)
                        .privacySensitive()
                        .focused($focusedField, equals: .apiKey)
                        .onSubmit { settings.saveAPIKey() }
                        .plainwordField(isFocused: focusedField == .apiKey, usesMono: true)
                }
            }
        }
    }

    private var ollamaConnectionFields: some View {
        Group {
            fieldRow("Server") {
                HStack {
                    Text("localhost:11434")
                        .font(PlainwordFont.mono(11.5))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                    Spacer()
                    StatusPill(
                        title: "Local",
                        color: PlainwordTheme.accent,
                        systemImage: "desktopcomputer",
                        wash: PlainwordTheme.accentMuted
                    )
                }
            }

            fieldDivider

            fieldRow("Model") {
                HStack(spacing: 8) {
                    Picker("Model", selection: $settings.ollamaModel) {
                        if settings.ollamaModelOptions.isEmpty {
                            Text("No local models found").tag("")
                        } else {
                            ForEach(settings.ollamaModelOptions, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(settings.ollamaModelOptions.isEmpty)

                    if settings.ollamaModelsState == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 26, height: 26)
                    } else {
                        QuietGlyphButton(
                            systemImage: "arrow.clockwise",
                            help: "Reload models from Ollama"
                        ) {
                            Task { await settings.refreshOllamaModels() }
                        }
                    }
                }
            }
        }
    }

    private var codexConnectionFields: some View {
        Group {
            fieldRow("Account") {
                HStack(spacing: 10) {
                    codexAccountStatus
                    Spacer()
                    if settings.codexState == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 26, height: 26)
                    } else {
                        QuietGlyphButton(
                            systemImage: "arrow.clockwise",
                            help: "Check Codex CLI account and models"
                        ) {
                            Task { await settings.refreshCodexStatus() }
                        }
                    }
                }
            }

            fieldDivider

            fieldRow("Model", detail: codexModelDetail) {
                Picker("Model", selection: $settings.codexModel) {
                    Text("Codex default").tag("")
                    ForEach(settings.codexModelOptions) { model in
                        Text(
                            model.isLatencyOptimized
                                ? "\(model.displayName) (Fastest)"
                                : model.displayName
                        )
                        .tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(settings.codexState == .loading)
            }
        }
    }

    private var availableThinkingModes: [ThinkingMode] {
        ThinkingMode.allCases
    }

    private var codexModelDetail: String {
        if settings.codexModel == CodexModel.latencyOptimizedModelID {
            return "Optimized for low-latency corrections."
        }
        return "Codex-Spark is recommended for responsive corrections."
    }

    private var credentialCard: some View {
        HStack(spacing: 10) {
            credentialStatus
            Spacer(minLength: 8)
            if !settings.apiKey.isEmpty {
                Button("Clear", role: .destructive) {
                    settings.clearAPIKey()
                }
                .buttonStyle(PlainwordButtonStyle(.danger))
            }
            Button("Save") {
                settings.saveAPIKey()
            }
            .buttonStyle(PlainwordButtonStyle(.primary))
            .disabled(settings.apiKey.isEmpty || settings.credentialState == .saved)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .plainwordCard(cornerRadius: PlainwordTheme.cardCornerRadius)
    }

    private var connectionCard: some View {
        HStack(spacing: 12) {
            connectionStatus
            Spacer(minLength: 12)
            Button {
                Task { await settings.testConnection() }
            } label: {
                if settings.connectionState == .testing {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing…")
                    }
                } else {
                    Text(connectionButtonTitle)
                }
            }
            .disabled(!canTest || settings.connectionState == .testing)
            .buttonStyle(PlainwordButtonStyle(.primary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .plainwordCard(cornerRadius: PlainwordTheme.cardCornerRadius)
    }

    @ViewBuilder
    private var ollamaModelsStatus: some View {
        switch settings.ollamaModelsState {
        case .idle, .loading:
            EmptyView()
        case .loaded where settings.ollamaModels.isEmpty:
            captionText(
                "No local models found. Pull a model in Ollama, then reload.",
                color: PlainwordTheme.textSecondary
            )
        case .loaded:
            captionText(
                "Loaded \(settings.ollamaModels.count) local "
                    + (settings.ollamaModels.count == 1 ? "model." : "models."),
                color: PlainwordTheme.textSecondary
            )
        case .failure(let message):
            HStack(spacing: 10) {
                captionText(message, color: PlainwordTheme.danger)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    Task { await settings.refreshOllamaModels() }
                }
                .buttonStyle(PlainwordButtonStyle(.quiet))
            }
        }
    }

    private func captionText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PlainwordFont.ui(11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 3)
    }

    @ViewBuilder
    private var codexAccountStatus: some View {
        switch settings.codexState {
        case .idle:
            Text("Not checked")
                .font(PlainwordFont.ui(13))
                .foregroundStyle(PlainwordTheme.textSecondary)
        case .loading:
            Text("Checking Codex CLI…")
                .font(PlainwordFont.ui(13))
                .foregroundStyle(PlainwordTheme.textSecondary)
        case .ready(let status):
            VStack(alignment: .leading, spacing: 2) {
                Text(status.email ?? "ChatGPT account")
                    .font(PlainwordFont.ui(13))
                    .lineLimit(1)
                Text("ChatGPT \(status.planDisplayName) · via Codex CLI")
                    .font(PlainwordFont.ui(11))
                    .foregroundStyle(PlainwordTheme.textSecondary)
            }
            .help(status.executablePath)
        case .failure:
            Text("Unavailable")
                .font(PlainwordFont.ui(13))
                .foregroundStyle(PlainwordTheme.danger)
        }
    }

    @ViewBuilder
    private var codexStatusNotice: some View {
        switch settings.codexState {
        case .idle, .loading, .ready:
            EmptyView()
        case .failure(let message):
            HStack(spacing: 10) {
                captionText(message, color: PlainwordTheme.danger)
                    .lineLimit(3)
                Spacer()
                Button("Retry") {
                    Task { await settings.refreshCodexStatus() }
                }
                .buttonStyle(PlainwordButtonStyle(.quiet))
            }
        }
    }

    private func fieldRow<Content: View>(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: fieldSpacing) {
            Text(title)
                .font(PlainwordFont.ui(13, weight: .semibold))
                .foregroundStyle(PlainwordTheme.textSecondary)
                .frame(width: fieldLabelWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    Text(detail)
                        .font(PlainwordFont.ui(11))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.vertical, PlainwordTheme.settingsRowVerticalPadding)
    }

    /// Inset past the label column, so the hairline separates the values rather than
    /// cutting across the names of the fields.
    private var fieldDivider: some View {
        SettingsDivider(leadingInset: fieldLabelWidth + fieldSpacing)
    }

    @ViewBuilder
    private var credentialStatus: some View {
        switch settings.credentialState {
        case .empty:
            StatusPill(title: "No key saved", color: PlainwordTheme.textTertiary)
        case .saved:
            StatusPill(
                title: "Saved in Keychain",
                color: PlainwordTheme.accent,
                systemImage: "checkmark",
                wash: PlainwordTheme.accentMuted
            )
        case .unsaved:
            StatusPill(title: "Unsaved changes", color: PlainwordTheme.warning)
        case .failure(let message):
            Text(message)
                .font(PlainwordFont.ui(11))
                .foregroundStyle(PlainwordTheme.danger)
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: connectionIcon)
                .font(PlainwordFont.ui(13, weight: .semibold))
                .foregroundStyle(connectionColor)
                .frame(width: 32, height: 32)
                .background(
                    connectionWash,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .animation(PlainwordMotion.content, value: connectionWash)

            VStack(alignment: .leading, spacing: 3) {
                Text(connectionTitle)
                    .font(PlainwordFont.ui(13, weight: .bold))
                Text(connectionDetail)
                    .font(PlainwordFont.ui(11))
                    .foregroundStyle(connectionDetailColor)
                    .lineLimit(2)
            }
        }
    }

    private var connectionTitle: String {
        switch settings.connectionState {
        case .idle: "Verify your setup"
        case .testing: "Testing connection"
        case .success: "Connection verified"
        case .failure: "Connection failed"
        }
    }

    private var connectionDetail: String {
        switch settings.connectionState {
        case .idle where canTest:
            "Send a short request to \(connectionTarget)."
        case .idle:
            "Complete the provider details above to enable a connection test."
        case .testing:
            "Waiting for a response from \(connectionTarget)."
        case .success:
            "The provider returned a valid response."
        case .failure(let message):
            message
        }
    }

    private var connectionTarget: String {
        let model = settings.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.provider == .codex, model.isEmpty {
            return "Codex · Default model"
        }
        guard !model.isEmpty else { return settings.provider.displayName }
        return "\(settings.provider.displayName) · \(model)"
    }

    private var connectionIcon: String {
        switch settings.connectionState {
        case .idle: "bolt.horizontal"
        case .testing: "arrow.triangle.2.circlepath"
        case .success: "checkmark"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch settings.connectionState {
        case .idle, .testing: PlainwordTheme.accent
        case .success: PlainwordTheme.accent
        case .failure: PlainwordTheme.danger
        }
    }

    private var connectionWash: Color {
        switch settings.connectionState {
        case .idle, .testing, .success: PlainwordTheme.accentMuted
        case .failure: PlainwordTheme.dangerMuted
        }
    }

    private var connectionDetailColor: Color {
        if case .failure = settings.connectionState {
            return PlainwordTheme.danger
        }
        return PlainwordTheme.textSecondary
    }

    private var connectionButtonTitle: String {
        switch settings.connectionState {
        case .success, .failure: "Test Again"
        case .idle, .testing: "Test Connection"
        }
    }
}

/// A borderless glyph that only shows its surface when the pointer is on it.
struct QuietGlyphButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(PlainwordFont.ui(12, weight: .medium))
                .foregroundStyle(
                    isHovering ? PlainwordTheme.textPrimary : PlainwordTheme.textSecondary
                )
                .frame(width: 26, height: 26)
                .background(
                    isHovering ? PlainwordTheme.raisedSurface : .clear,
                    in: RoundedRectangle(
                        cornerRadius: PlainwordTheme.smallCornerRadius,
                        style: .continuous
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PlainwordMotion.content, value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }
}
