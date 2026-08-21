import AppKit
import Combine
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
        settings.applyDockIconVisibility()
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

/// The menu-bar dropdown, in the same paper card language as everything else:
/// a raised surface, hairline rules, and mono shortcuts down the right.
private struct PlainwordMenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var crossAppCorrections: CrossAppCorrectionController
    let onReviewSelectionOrField: () -> Void
    let onTransformSelectionOrField: () -> Void
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            MenuRow(title: "Suggestions", isEmphasized: true) {
                Toggle("Suggestions", isOn: listeningBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(PlainwordTheme.accent)
            }

            if crossAppCorrections.isListeningEnabled,
               !crossAppCorrections.isAccessibilityTrusted {
                MenuActionButton(title: "Allow Accessibility") {
                    crossAppCorrections.requestAccessibilityAccess()
                }
            }

            if crossAppCorrections.isListeningEnabled, !settings.isLLMConfigured {
                MenuActionButton(title: "Configure Provider") {
                    onOpenMainWindow()
                }
            }

            if let activeApplication = crossAppCorrections.activeApplication {
                MenuActionButton(
                    title: crossAppCorrections.isActiveApplicationExcluded
                        ? "Enable in \(activeApplication.name)"
                        : "Ignore \(activeApplication.name)",
                    // The row names one specific app, so it carries that app's own
                    // icon: the reader recognises it before they read the sentence.
                    icon: activeApplication.icon,
                    isChecked: crossAppCorrections.isActiveApplicationExcluded
                ) {
                    crossAppCorrections.toggleExclusionForActiveApplication()
                }

                if crossAppCorrections.isReady,
                   !crossAppCorrections.isActiveApplicationExcluded {
                    menuDivider

                    MenuActionButton(
                        title: "Review text",
                        shortcut: settings.popoverShortcut?.displayText
                    ) {
                        onReviewSelectionOrField()
                    }
                    MenuActionButton(
                        title: "Rewrite…",
                        shortcut: settings.transformShortcut?.displayText
                    ) {
                        onTransformSelectionOrField()
                    }
                }
            }

            menuDivider

            MenuActionButton(title: "Settings…", shortcut: "⌘,") {
                onOpenMainWindow()
            }

            MenuActionButton(title: "Quit Plainword") {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 244)
        .foregroundStyle(PlainwordTheme.textPrimary)
        .background(PlainwordTheme.raisedSurface)
    }

    private var listeningBinding: Binding<Bool> {
        Binding(
            get: { crossAppCorrections.isListeningEnabled },
            set: { crossAppCorrections.setListeningEnabled($0) }
        )
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(PlainwordTheme.strongSeparator)
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

/// A row of the dropdown that carries a control rather than an action.
private struct MenuRow<Accessory: View>: View {
    let title: String
    var isEmphasized = false
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(PlainwordFont.ui(12.5, weight: isEmphasized ? .bold : .regular))
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct MenuActionButton: View {
    let title: String
    var shortcut: String?
    var icon: NSImage?
    var isChecked = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(PlainwordFont.ui(12.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(PlainwordFont.ui(10, weight: .bold))
                        .foregroundStyle(PlainwordTheme.accent)
                }
                if let shortcut {
                    Text(shortcut)
                        .font(PlainwordFont.mono(11))
                        .foregroundStyle(PlainwordTheme.textTertiary)
                }
            }
            .foregroundStyle(
                isHovering ? PlainwordTheme.textPrimary : PlainwordTheme.textSecondary
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isHovering ? PlainwordTheme.fieldSurface : .clear,
                in: RoundedRectangle(
                    cornerRadius: PlainwordTheme.pillCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PlainwordMotion.content, value: isHovering)
    }
}

@MainActor
private final class StatusBarController: NSObject, ObservableObject {
    private let settings: SettingsStore
    private let crossAppCorrections: CrossAppCorrectionController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private weak var mainWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var glyphActivity: PlainwordMenuBarGlyph.Activity = .idle
    /// Drives the amber full stop while a request is in flight.
    private var pulseTask: Task<Void, Never>?

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
        observeActivity()
    }

    deinit {
        pulseTask?.cancel()
    }

    func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        guard window !== mainWindow else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        // The sidebar runs to the top of the window, with the traffic lights over it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(PlainwordTheme.surface)
    }

    /// The glyph is the only place the app's state is shown when its windows are
    /// closed, so it is rebuilt whenever that state moves.
    private func observeActivity() {
        crossAppCorrections.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)
    }

    private func refreshStatusItem() {
        let activity = currentGlyphActivity
        guard activity != glyphActivity else { return }
        glyphActivity = activity
        pulseTask?.cancel()
        pulseTask = nil
        setStatusItemImage(activity: activity, stopOpacity: 1)

        guard activity == .working, !PlainwordMotion.reducesMotion else { return }
        pulseTask = Task { [weak self] in
            var isDim = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                isDim.toggle()
                self?.setStatusItemImage(activity: .working, stopOpacity: isDim ? 0.3 : 1)
            }
        }
    }

    private var currentGlyphActivity: PlainwordMenuBarGlyph.Activity {
        guard crossAppCorrections.isListeningEnabled,
              !crossAppCorrections.isActiveApplicationExcluded else {
            return .paused
        }
        if case .correcting = crossAppCorrections.activity { return .working }
        return .idle
    }

    private func setStatusItemImage(
        activity: PlainwordMenuBarGlyph.Activity,
        stopOpacity: CGFloat
    ) {
        statusItem.button?.image = PlainwordMenuBarGlyph.image(
            activity: activity,
            stopOpacity: stopOpacity
        )
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = PlainwordMenuBarGlyph.image(activity: currentGlyphActivity)
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
            title: "Rewrite Selection or Field…",
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
        suggestionsItem.image = PlainwordMenuBarGlyph.menuItemImage()
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
