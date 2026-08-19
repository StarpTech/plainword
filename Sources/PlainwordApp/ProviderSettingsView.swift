import Foundation
import PlainwordCore
import SwiftUI

struct ProviderSettingsView: View {
    private let fieldLabelWidth: CGFloat = 92
    private let fieldSpacing: CGFloat = 14

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
                subtitle: "Connect the language model that powers your suggestions.",
                icon: "server.rack"
            )

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("Connection")
                SettingsGroup {
                    fieldRow(
                        "Provider",
                        detail: "Choose the service that powers your suggestions."
                    ) {
                        Picker("Provider", selection: $settings.provider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.large)
                        .frame(width: 200, alignment: .leading)
                    }

                    fieldDivider

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

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("Options")
                SettingsGroup {
                    SettingsRow(
                        "Thinking mode",
                        detail: "Set reasoning effort for models that support thinking."
                    ) {
                        Picker("Thinking mode", selection: $settings.thinkingMode) {
                            ForEach(ThinkingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.large)
                        .frame(width: 130, alignment: .trailing)
                    }

                }
            }

            connectionCard
        }
        .navigationTitle("Provider")
        .task(id: settings.provider) {
            await settings.loadOllamaModelsIfNeeded()
            await settings.loadCodexStatusIfNeeded()
        }
        .animation(.snappy(duration: 0.2), value: settings.provider)
        .animation(.snappy(duration: 0.2), value: settings.authentication)
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
                .plainwordField()
            }

            fieldDivider

            fieldRow("Model") {
                TextField("Model identifier", text: $settings.model)
                    .focused($focusedField, equals: .model)
                    .plainwordField()
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
                .controlSize(.large)
                .frame(width: 200)
            }

            if settings.authentication == .customHeader {
                fieldDivider
                fieldRow("Header") {
                    TextField("api-key", text: $settings.customHeaderName)
                        .focused($focusedField, equals: .customHeader)
                        .plainwordField()
                }
            }

            if settings.authentication != .none {
                fieldDivider
                fieldRow("API key") {
                    SecureField("Keychain", text: $settings.apiKey)
                        .privacySensitive()
                        .focused($focusedField, equals: .apiKey)
                        .onSubmit { settings.saveAPIKey() }
                        .plainwordField()
                }
            }
        }
    }

    private var ollamaConnectionFields: some View {
        Group {
            fieldRow("Server") {
                HStack {
                    Text("localhost:11434")
                        .foregroundStyle(PlainwordTheme.textSecondary)
                    Spacer()
                    StatusPill(
                        title: "Local",
                        color: PlainwordTheme.success,
                        systemImage: "desktopcomputer"
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
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(settings.ollamaModelOptions.isEmpty)

                    if settings.ollamaModelsState == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 24)
                    } else {
                        Button {
                            Task { await settings.refreshOllamaModels() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .help("Reload models from Ollama")
                    }
                }
            }
        }
    }

    private var codexConnectionFields: some View {
        Group {
            fieldRow(
                "Account",
                detail: "Uses the ChatGPT account already signed in through Codex CLI."
            ) {
                HStack(spacing: 10) {
                    codexAccountStatus
                    Spacer()
                    if settings.codexState == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 24)
                    } else {
                        Button {
                            Task { await settings.refreshCodexStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .help("Check Codex CLI account and models")
                    }
                }
            }

            fieldDivider

            fieldRow(
                "Model",
                detail: "Codex default follows your CLI configuration."
            ) {
                Picker("Model", selection: $settings.codexModel) {
                    Text("Codex default").tag("")
                    ForEach(settings.codexModelOptions) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(settings.codexState == .loading)
            }
        }
    }

    private var credentialCard: some View {
        HStack {
            credentialStatus
            Spacer()
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
        .plainwordGlass(cornerRadius: PlainwordTheme.cornerRadius, shadow: true)
    }

    private var connectionCard: some View {
        HStack(spacing: 14) {
            connectionStatus
            Spacer(minLength: 16)
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
        .plainwordGlass(cornerRadius: PlainwordTheme.cornerRadius, shadow: true)
    }

    @ViewBuilder
    private var ollamaModelsStatus: some View {
        switch settings.ollamaModelsState {
        case .idle, .loading:
            EmptyView()
        case .loaded where settings.ollamaModels.isEmpty:
            Label(
                "No local models found. Pull a model in Ollama, then reload.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(PlainwordTheme.textSecondary)
            .padding(.horizontal, 3)
        case .loaded:
            Text(
                "Loaded \(settings.ollamaModels.count) local "
                    + (settings.ollamaModels.count == 1 ? "model." : "models.")
            )
            .font(.caption)
            .foregroundStyle(PlainwordTheme.textSecondary)
            .padding(.horizontal, 3)
        case .failure(let message):
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.danger)
                    .lineLimit(2)
                Spacer()
                Button("Retry") {
                    Task { await settings.refreshOllamaModels() }
                }
                .buttonStyle(PlainwordButtonStyle(.quiet))
            }
            .padding(.horizontal, 3)
        }
    }

    @ViewBuilder
    private var codexAccountStatus: some View {
        switch settings.codexState {
        case .idle:
            Text("Not checked")
                .foregroundStyle(PlainwordTheme.textSecondary)
        case .loading:
            Text("Checking Codex CLI…")
                .foregroundStyle(PlainwordTheme.textSecondary)
        case .ready(let status):
            VStack(alignment: .leading, spacing: 2) {
                Text(status.email ?? "ChatGPT account")
                    .lineLimit(1)
                Text("ChatGPT \(status.planDisplayName)")
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.textSecondary)
            }
            .help(status.executablePath)
        case .failure:
            Text("Unavailable")
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
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PlainwordTheme.danger)
                    .lineLimit(3)
                Spacer()
                Button("Retry") {
                    Task { await settings.refreshCodexStatus() }
                }
                .buttonStyle(PlainwordButtonStyle(.quiet))
            }
            .padding(.horizontal, 3)
        }
    }

    private func fieldRow<Content: View>(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: fieldSpacing) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                    .frame(width: fieldLabelWidth, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                    .padding(.leading, fieldLabelWidth + fieldSpacing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.vertical, PlainwordTheme.settingsRowVerticalPadding)
    }

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
                color: PlainwordTheme.success,
                systemImage: "checkmark"
            )
        case .unsaved:
            StatusPill(title: "Unsaved changes", color: PlainwordTheme.warning)
        case .failure(let message):
            Text(message)
                .foregroundStyle(PlainwordTheme.danger)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        HStack(spacing: 11) {
            Image(systemName: connectionIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(connectionColor)
                .frame(width: 32, height: 32)
                .background(
                    connectionColor.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(connectionTitle)
                    .font(.system(size: 13, weight: .medium))
                Text(connectionDetail)
                    .font(.system(size: 11))
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
        case .idle: "bolt.horizontal.circle"
        case .testing: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch settings.connectionState {
        case .idle, .testing: PlainwordTheme.accent
        case .success: PlainwordTheme.success
        case .failure: PlainwordTheme.danger
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
