import AppKit
import ApplicationServices
import CoreGraphics

/// Transfers an `AXUIElement` across an isolation boundary.
///
/// `AXUIElement` is a CoreFoundation type with no `Sendable` conformance, but the
/// Accessibility API is safe to call from any thread — Apple's own guidance is to keep
/// these round trips off the main thread, because each one is a synchronous message to
/// another process that can block for as long as the messaging timeout allows.
struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }
}

/// A hashable identity for an `AXUIElement`, so that traversals can use a set instead of
/// a linear scan over everything they have already seen.
struct AXElementKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// Thread-safe primitives for reading the Accessibility API.
///
/// These are the only place that talks to `AXUIElementCopy…`, so the retry policy and
/// the value coercions have a single definition shared by the main-actor capture path
/// and the off-actor context harvester.
enum AccessibilityElementReader {
    /// Ceiling for every Accessibility message this process sends.
    ///
    /// The timeout is set on the system-wide element because a timeout set on any other
    /// element applies only to that one reference — not to its parents, siblings, or
    /// children, and not even to another reference that compares equal to it. Without a
    /// global value, every element discovered while traversing would fall back to the
    /// API's multi-second default and could stall the caller for as long as it took.
    static let messagingTimeout: Float = 0.75

    /// Ceiling for the reads a context harvest makes.
    ///
    /// Tighter than the global value, and deliberately so. A responsive application
    /// answers an attribute read in single-digit milliseconds; a timeout is only ever
    /// reached by one that has stopped answering, and waiting three quarters of a second
    /// for that verdict spends nearly four times the entire time budget of a request on
    /// learning nothing. Set per element rather than globally, which is the only scope
    /// the API offers below the whole process — and the right one here, because the path
    /// that applies an edit wants the patient value.
    static let harvestMessagingTimeout: Float = 0.12

    static func applyGlobalMessagingTimeout() {
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    // MARK: - Attribute access

    static func attributeValue(
        _ attribute: String,
        from element: AXUIElement
    ) -> CFTypeRef? {
        for attempt in 0..<2 {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if result == .success {
                return value
            }
            guard result == .cannotComplete, attempt == 0 else { return nil }
        }
        return nil
    }

    static func multipleAttributeValues(
        _ attributes: [String],
        from element: AXUIElement
    ) -> [String: Any] {
        for attempt in 0..<2 {
            var rawValues: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                element,
                attributes as CFArray,
                [],
                &rawValues
            )
            if result == .success, let values = rawValues as? [Any] {
                var mapped: [String: Any] = [:]
                for (attribute, value) in zip(attributes, values) {
                    if !(value is NSNull) {
                        mapped[attribute] = value
                    }
                }
                return mapped
            }
            if result == .cannotComplete {
                guard attempt == 0 else {
                    // The application is not answering. Reading the same attributes one
                    // at a time would time out once more per attribute, turning an
                    // unresponsive node into a multi-second stall for the caller.
                    return [:]
                }
                continue
            }
            break
        }

        // Some applications reject the batch call outright. Those answer individual
        // reads immediately, so the per-attribute fallback is cheap for them.
        var fallback: [String: Any] = [:]
        for attribute in attributes {
            if let value = attributeValue(attribute, from: element) {
                fallback[attribute] = value
            }
        }
        return fallback
    }

    static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        guard let value = attributeValue(attribute, from: element) else { return nil }
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    static func integerAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        (attributeValue(attribute, from: element) as? NSNumber)?.intValue
    }

    static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool {
        (attributeValue(attribute, from: element) as? NSNumber)?.boolValue ?? false
    }

    static func rangeAttribute(_ attribute: String, from element: AXUIElement) -> CFRange? {
        guard let value = attributeValue(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    static func rangeArrayAttribute(_ attribute: String, from element: AXUIElement) -> [CFRange] {
        guard let values = attributeValue(attribute, from: element) as? [Any] else {
            return []
        }
        return values.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
            let axValue = unsafeDowncast(cfValue, to: AXValue.self)
            guard AXValueGetType(axValue) == .cfRange else { return nil }
            var range = CFRange()
            return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
        }
    }

    static func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    // MARK: - Value coercion

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return (value as? NSAttributedString)?.string
    }

    static func boolValue(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    static func integerValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    static func axValue(_ value: Any?) -> AXValue? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(cfValue, to: AXValue.self)
    }

    static func uiElementValue(_ value: Any?) -> AXUIElement? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(cfValue, to: AXUIElement.self)
    }

    static func uiElementArray(_ value: Any?) -> [AXUIElement] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(uiElementValue)
    }

    static func elementsAreEqual(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    // MARK: - Capability checks

    static func hasAttribute(_ attribute: String, on element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names = names as? [String] else {
            return false
        }
        return names.contains(attribute)
    }

    static func supportsParameterizedAttribute(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let names = names as? [String] else {
            return false
        }
        return names.contains(attribute)
    }

    static func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    static func isProtected(_ element: AXUIElement) -> Bool {
        boolAttribute(protectedContentAttribute, from: element)
    }

    /// `NSAccessibility.Attribute.containsProtectedContent`, spelled out so that it can
    /// be read from any isolation domain.
    static let protectedContentAttribute = "AXContainsProtectedContent"

    static func isWritableTextElement(_ element: AXUIElement) -> Bool {
        if isAttributeSettable(kAXValueAttribute as String, on: element) {
            return true
        }

        // Chromium/WebKit contenteditable roots commonly expose a writable selection
        // range but make AXSelectedText read-only. They are still safely editable via
        // the existing range-selection + keyboard-input replacement path. Requiring a
        // direct AXSelectedText write here prevented capture before that fallback ran.
        guard boolAttribute(kAXIsEditableAttribute as String, from: element),
              isAttributeSettable(kAXSelectedTextRangeAttribute as String, on: element) else {
            return false
        }
        return hasAttribute(kAXValueAttribute as String, on: element)
            || supportsParameterizedAttribute(
                kAXStringForRangeParameterizedAttribute as String,
                on: element
            )
    }

    // MARK: - Content

    static func readableText(from element: AXUIElement) -> String? {
        let attributes = [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String
        ]
        let values = multipleAttributeValues(attributes, from: element)
        for attribute in attributes {
            if let text = stringValue(values[attribute])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: - Geometry

    /// Converts an Accessibility rect, whose origin is the top-left of the primary
    /// display, into AppKit screen coordinates, whose origin is the bottom-left.
    ///
    /// `primaryScreenMaxY` is passed in rather than read from `NSScreen` so that callers
    /// off the main actor can convert frames too.
    static func appKitRect(
        fromAccessibilityRect rect: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func rect(
        of element: AXUIElement,
        primaryScreenMaxY: CGFloat
    ) -> CGRect? {
        guard let positionValue = axValue(attributeValue(kAXPositionAttribute as String, from: element)),
              let sizeValue = axValue(attributeValue(kAXSizeAttribute as String, from: element)) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return appKitRect(
            fromAccessibilityRect: CGRect(origin: position, size: size),
            primaryScreenMaxY: primaryScreenMaxY
        )
    }
}
