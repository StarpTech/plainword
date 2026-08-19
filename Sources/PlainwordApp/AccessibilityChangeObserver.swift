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

        addNotification(kAXFocusedUIElementChangedNotification, to: applicationElement)
        addNotification(kAXUIElementDestroyedNotification, to: applicationElement)
        rebindFocusedElement()
        return true
    }

    func stop() {
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
        if element == nil {
            // Electron documents this opt-in for third-party assistive software. Other
            // applications simply reject the unknown attribute without changing state.
            _ = AXUIElementSetAttributeValue(
                applicationElement,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
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
