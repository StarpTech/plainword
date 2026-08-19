import AppKit
import SwiftUI

@main
struct PlainwordApp: App {
    @NSApplicationDelegateAdaptor(PlainwordApplicationDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var crossAppCorrections: CrossAppCorrectionController
    @StateObject private var statusBarController: StatusBarController

    @MainActor
    init() {
        let settings = SettingsStore()
        let crossAppCorrections = CrossAppCorrectionController(settings: settings)
        let statusBarController = StatusBarController(
            settings: settings,
            crossAppCorrections: crossAppCorrections
        )
        _settings = StateObject(wrappedValue: settings)
        _crossAppCorrections = StateObject(wrappedValue: crossAppCorrections)
        _statusBarController = StateObject(wrappedValue: statusBarController)

        appDelegate.shutdownHandler = { [weak settings] in
            await settings?.shutdown()
        }
        settings.appearance.apply()
        crossAppCorrections.start()
    }

    var body: some Scene {
        Window("Plainword", id: "main") {
            RootView()
                .environmentObject(settings)
                .environmentObject(crossAppCorrections)
                .tint(PlainwordTheme.accent)
                .background {
                    WindowReader { [weak statusBarController] window in
                        statusBarController?.registerMainWindow(window)
                    }
                }
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class PlainwordApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (() async -> Void)?
    private var isTerminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownHandler else { return .terminateNow }
        guard !isTerminationPending else { return .terminateLater }
        isTerminationPending = true

        Task {
            await shutdownHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct PlainwordMenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var crossAppCorrections: CrossAppCorrectionController
    let onReviewSelectionOrField: () -> Void
    let onTransformSelectionOrField: () -> Void
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PlainwordBrandMark(size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Plainword")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(PlainwordTheme.textPrimary)
                    Text(crossAppCorrections.activity.label)
                        .font(.caption)
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Toggle("Suggestions", isOn: listeningBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(PlainwordTheme.accent)
            }
            .padding(14)
            .background(PlainwordTheme.raisedSurface.opacity(0.5))

            if crossAppCorrections.isListeningEnabled,
               !crossAppCorrections.isAccessibilityTrusted {
                menuDivider
                menuButton("Allow Accessibility", systemImage: "accessibility") {
                    crossAppCorrections.requestAccessibilityAccess()
                }
            }

            if crossAppCorrections.isListeningEnabled, !settings.isLLMConfigured {
                menuDivider
                menuButton("Configure Provider", systemImage: "server.rack") {
                    onOpenMainWindow()
                }
            }

            if let activeApplication = crossAppCorrections.activeApplication {
                menuDivider

                if crossAppCorrections.isReady,
                   !crossAppCorrections.isActiveApplicationExcluded {
                    menuButton(
                        "Review Selection or Field",
                        systemImage: "text.magnifyingglass"
                    ) {
                        onReviewSelectionOrField()
                    }
                    menuButton(
                        "Transform Selection or Field…",
                        systemImage: "wand.and.stars"
                    ) {
                        onTransformSelectionOrField()
                    }
                }

                ApplicationMenuActionButton(
                    title: crossAppCorrections.isActiveApplicationExcluded
                        ? "Enable in \(activeApplication.name)"
                        : "Ignore \(activeApplication.name)",
                    icon: activeApplication.icon,
                    isExcluded: crossAppCorrections.isActiveApplicationExcluded
                ) {
                    crossAppCorrections.toggleExclusionForActiveApplication()
                }
            }

            menuDivider

            menuButton("Settings…", systemImage: "gearshape") {
                onOpenMainWindow()
            }

            menuButton("Quit Plainword", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .frame(width: 280)
        .foregroundStyle(PlainwordTheme.textPrimary)
        .background(PlainwordTheme.surface)
    }

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { crossAppCorrections.isListeningEnabled },
            set: { crossAppCorrections.setListeningEnabled($0) }
        )
    }

    private func menuButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        MenuActionButton(
            title: title,
            systemImage: systemImage,
            action: action
        )
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(PlainwordTheme.separator.opacity(0.8))
            .frame(height: 1)
            .padding(.horizontal, 8)
    }
}

@MainActor
private final class StatusBarController: NSObject, ObservableObject {
    private let settings: SettingsStore
    private let crossAppCorrections: CrossAppCorrectionController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private weak var mainWindow: NSWindow?

    init(
        settings: SettingsStore,
        crossAppCorrections: CrossAppCorrectionController
    ) {
        self.settings = settings
        self.crossAppCorrections = crossAppCorrections
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        configurePopover()
    }

    func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        guard window !== mainWindow else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(PlainwordTheme.canvas)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = PlainwordMenuBarGlyph.image()
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Plainword"
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let rootView = PlainwordMenuView(
            onReviewSelectionOrField: { [weak self] in
                self?.reviewSelectionOrField()
            },
            onTransformSelectionOrField: { [weak self] in
                self?.transformSelectionOrField()
            },
            onOpenMainWindow: { [weak self] in
                self?.openMainWindow()
            }
        )
        .environmentObject(settings)
        .environmentObject(crossAppCorrections)
        .tint(PlainwordTheme.accent)

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
    }

    @objc private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isContextClick {
            crossAppCorrections.prepareManualReview()
            showContextMenu()
        } else {
            if !popover.isShown {
                crossAppCorrections.prepareManualReview()
            }
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        popover.performClose(nil)
        makeContextMenu().popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
            in: button
        )
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let reviewItem = NSMenuItem(
            title: "Review Selection or Field",
            action: #selector(reviewSelectionOrFieldFromContextMenu),
            keyEquivalent: ""
        )
        reviewItem.image = NSImage(
            systemSymbolName: "text.magnifyingglass",
            accessibilityDescription: nil
        )
        reviewItem.isEnabled = crossAppCorrections.isReady
            && !crossAppCorrections.isActiveApplicationExcluded
        reviewItem.target = self
        menu.addItem(reviewItem)

        let transformItem = NSMenuItem(
            title: "Transform Selection or Field…",
            action: #selector(transformSelectionOrFieldFromContextMenu),
            keyEquivalent: ""
        )
        transformItem.image = NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: nil
        )
        transformItem.isEnabled = crossAppCorrections.isReady
            && !crossAppCorrections.isActiveApplicationExcluded
        transformItem.target = self
        menu.addItem(transformItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromContextMenu),
            keyEquivalent: ""
        )
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)

        let suggestionsItem = NSMenuItem(
            title: "Suggestions",
            action: #selector(toggleSuggestionsFromContextMenu),
            keyEquivalent: ""
        )
        suggestionsItem.image = PlainwordMenuBarGlyph.image(size: 16)
        suggestionsItem.state = crossAppCorrections.isListeningEnabled ? .on : .off
        suggestionsItem.target = self
        menu.addItem(suggestionsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Plainword",
            action: #selector(quitFromContextMenu),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openSettingsFromContextMenu() {
        openMainWindow()
    }

    @objc private func reviewSelectionOrFieldFromContextMenu() {
        crossAppCorrections.reviewSelectionOrDocument()
    }

    @objc private func transformSelectionOrFieldFromContextMenu() {
        crossAppCorrections.transformSelectionOrDocument()
    }

    @objc private func toggleSuggestionsFromContextMenu() {
        crossAppCorrections.setListeningEnabled(!crossAppCorrections.isListeningEnabled)
    }

    @objc private func quitFromContextMenu() {
        NSApp.terminate(nil)
    }

    private func openMainWindow() {
        popover.performClose(nil)
        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reviewSelectionOrField() {
        popover.performClose(nil)
        crossAppCorrections.reviewSelectionOrDocument()
    }

    private func transformSelectionOrField() {
        popover.performClose(nil)
        crossAppCorrections.transformSelectionOrDocument()
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReadingView {
        let view = WindowReadingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowReadingView, context: Context) {
        nsView.onWindowChange = onWindowChange
        onWindowChange(nsView.window)
    }
}

private final class WindowReadingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private struct ApplicationMenuActionButton: View {
    let title: String
    let icon: NSImage?
    let isExcluded: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app")
                    }
                }
                .frame(width: 17, height: 17)

                Text(title)
                    .lineLimit(1)
                Spacer()
                if isExcluded {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PlainwordTheme.accent)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? PlainwordTheme.hoverSurface : .clear)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

private struct MenuActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(PlainwordTheme.textSecondary)
                    .frame(width: 17)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? PlainwordTheme.hoverSurface : .clear)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}
