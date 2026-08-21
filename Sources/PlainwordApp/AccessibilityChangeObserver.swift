import Foundation
@preconcurrency import ApplicationServices

enum AccessibilityObservedChange: Equatable {
    case focusedElementChanged
    case valueChanged
    case selectionChanged
    case elementDestroyed
    /// The window holding the focused element moved or was resized. A proposal is
    /// anchored to text, so it has to travel with the window that draws it.
    case windowGeometryChanged
}

/// Observes semantic changes in the active application's Accessibility tree.
/// Keyboard monitoring remains a fallback because AX notifications are optional and
/// some applications return `kAXErrorNotificationUnsupported`.
@MainActor
final class AccessibilityChangeObserver {
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var processIdentifier: pid_t?
    private var onChange: ((AccessibilityObservedChange) -> Void)?
    /// Whether the observed application draws with Chromium, and so has to be told —
    /// and kept being told — that something is reading it.
    private var isChromiumHost = false
    private var keepAliveTimer: Timer?

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    @discardableResult
    func start(
        processIdentifier: pid_t,
        onChange: @escaping (AccessibilityObservedChange) -> Void
    ) -> Bool {
        if self.processIdentifier == processIdentifier, observer != nil {
            self.onChange = onChange
            return true
        }

        stop()

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(applicationElement, 0.75)

        var observer: AXObserver?
        let result = AXObserverCreate(
            processIdentifier,
            accessibilityChangeObserverCallback,
            &observer
        )
        guard result == .success, let observer else { return false }

        self.observer = observer
        self.applicationElement = applicationElement
        self.processIdentifier = processIdentifier
        self.onChange = onChange

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        // Said once on activation rather than only when focus cannot be resolved: a
        // Chromium application can answer with a partial tree instead of none, which
        // looks like success and then yields nothing worth reading.
        isChromiumHost = ChromiumAccessibility.isChromiumHost(
            processIdentifier: processIdentifier
        )
        if isChromiumHost {
            ChromiumAccessibility.activate(processIdentifier: processIdentifier)
        } else {
            // Anything the framework check did not recognise is still offered Electron's
            // opt-in, which an application that does not implement it rejects without
            // changing state. `AXEnhancedUserInterface` is not offered so widely: it is
            // VoiceOver's flag, and native applications change how they lay out and
            // animate when it is set.
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
        }

        addNotification(kAXFocusedUIElementChangedNotification, to: applicationElement)
        addNotification(kAXUIElementDestroyedNotification, to: applicationElement)
        rebindFocusedElement()
        startKeepAlive()
        return true
    }

    func stop() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        isChromiumHost = false
        if let observer {
            if let focusedElement {
                removeFocusedNotifications(from: focusedElement, observer: observer)
            }
            if let windowElement {
                removeWindowNotifications(from: windowElement, observer: observer)
            }
            if let applicationElement {
                _ = AXObserverRemoveNotification(
                    observer,
                    applicationElement,
                    kAXFocusedUIElementChangedNotification as CFString
                )
                _ = AXObserverRemoveNotification(
                    observer,
                    applicationElement,
                    kAXUIElementDestroyedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        observer = nil
        applicationElement = nil
        focusedElement = nil
        windowElement = nil
        processIdentifier = nil
        onChange = nil
    }

    fileprivate func receive(
        element: AXUIElement,
        notification: String
    ) {
        switch notification {
        case kAXFocusedUIElementChangedNotification:
            rebindFocusedElement()
            onChange?(.focusedElementChanged)
        case kAXValueChangedNotification:
            onChange?(.valueChanged)
        case kAXSelectedTextChangedNotification:
            onChange?(.selectionChanged)
        case kAXUIElementDestroyedNotification:
            if let focusedElement, CFEqual(focusedElement, element) {
                rebindFocusedElement()
            }
            onChange?(.elementDestroyed)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            onChange?(.windowGeometryChanged)
        default:
            break
        }
    }

    private func rebindFocusedElement() {
        guard let observer, let applicationElement else { return }

        if let focusedElement {
            removeFocusedNotifications(from: focusedElement, observer: observer)
        }
        if let windowElement {
            removeWindowNotifications(from: windowElement, observer: observer)
        }
        focusedElement = nil
        windowElement = nil

        var element = focusedElement(from: applicationElement)
        if element == nil, let processIdentifier {
            // A second attempt after re-asserting the opt-in, for an application that
            // was still building its tree when this observer started.
            ChromiumAccessibility.activate(processIdentifier: processIdentifier)
            element = focusedElement(from: applicationElement)
        }
        if let candidate = element,
           let editableAncestor = editableAncestor(from: candidate) {
            // Browser accessibility trees may focus a text descendant while value and
            // selection notifications are emitted by its contenteditable root.
            element = editableAncestor
        }
        guard let element else {
            return
        }
        focusedElement = element
        addNotification(kAXValueChangedNotification, to: element)
        addNotification(kAXSelectedTextChangedNotification, to: element)
        addNotification(kAXUIElementDestroyedNotification, to: element)
        bindWindow(of: element)
    }

    /// Reads one attribute from web content every so often, for as long as a Chromium
    /// application is the one being observed.
    ///
    /// Chromium counts input events against accessibility calls to decide whether the
    /// client that switched accessibility on is still there. This tool only reads when
    /// the author asks it to, which from that side looks exactly like having left — so
    /// an author who types for a minute before pressing the shortcut finds the tree
    /// already gone. One read a quarter of the interval keeps the count from ever
    /// starting, and costs a single message every fifteen seconds.
    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        guard isChromiumHost else { return }

        keepAliveTimer = Timer.scheduledTimer(
            withTimeInterval: ChromiumAccessibility.keepAliveInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sendKeepAlive()
            }
        }
    }

    /// The focused element is the right thing to touch: in a browser it is a node inside
    /// the page, so reading it is web-content traffic — which is the only kind the rule
    /// counts. A read against the application element would leave the page's own tree
    /// looking just as unused as before.
    private func sendKeepAlive() {
        guard let focusedElement else {
            rebindFocusedElement()
            return
        }
        // Off the main thread, because this is the one read here that nothing is waiting
        // for. An application that has stopped answering would otherwise hold the
        // interface still for as long as the messaging timeout allows, every fifteen
        // seconds, to accomplish nothing at all.
        let box = AXElementBox(focusedElement)
        Task.detached(priority: .utility) {
            ChromiumAccessibility.ping(box.element)
        }
    }

    /// Follows the window that contains the focused element. Dragging or resizing it
    /// moves the text without changing it, which no other notification reports.
    private func bindWindow(of element: AXUIElement) {
        guard let window = window(from: element) else { return }
        windowElement = window
        addNotification(kAXWindowMovedNotification, to: window)
        addNotification(kAXWindowResizedNotification, to: window)
    }

    private func window(from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func focusedElement(from applicationElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func editableAncestor(from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXEditableAncestorAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func addNotification(_ name: String, to element: AXUIElement) {
        guard let observer else { return }
        let result = AXObserverAddNotification(
            observer,
            element,
            name as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        // Unsupported notifications are expected; the global keyboard monitor remains
        // active as the compatibility fallback.
        guard result == .success
                || result == .notificationAlreadyRegistered
                || result == .notificationUnsupported else {
            return
        }
    }

    private func removeWindowNotifications(
        from element: AXUIElement,
        observer: AXObserver
    ) {
        for notification in [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification
        ] {
            _ = AXObserverRemoveNotification(
                observer,
                element,
                notification as CFString
            )
        }
    }

    private func removeFocusedNotifications(
        from element: AXUIElement,
        observer: AXObserver
    ) {
        for notification in [
            kAXValueChangedNotification,
            kAXSelectedTextChangedNotification,
            kAXUIElementDestroyedNotification
        ] {
            _ = AXObserverRemoveNotification(
                observer,
                element,
                notification as CFString
            )
        }
    }
}

private func accessibilityChangeObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let changeObserver = Unmanaged<AccessibilityChangeObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let notificationName = notification as String
    MainActor.assumeIsolated {
        changeObserver.receive(element: element, notification: notificationName)
    }
}
