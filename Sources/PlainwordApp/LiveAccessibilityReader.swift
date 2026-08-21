import ApplicationServices
import CoreGraphics
import Foundation
import PlainwordCore

/// Answers the context pipeline from running applications.
///
/// This is the only place in the pipeline that talks to the Accessibility API. Above it
/// nothing knows that `AXUIElement` exists, which is what lets a recorded tree stand in
/// for a live one — and what keeps the whole policy layer clear of a CoreFoundation type
/// that carries no concurrency guarantees.
///
/// A reader is built for one assembly and thrown away with it. Its handle tables are
/// therefore bounded by that assembly, and no element outlives the moment it described.
final class LiveAccessibilityReader: AccessibilityReading {
    private let primaryScreenMaxY: CGFloat
    /// Hit testing is asked of the application rather than of an element inside it: a
    /// point is a place on screen, not a place in a subtree, and the application is the
    /// smallest thing that can say what it drew anywhere within its own windows.
    private let hitTestRoot: AXUIElement?

    private var elements: [ElementRef: AXUIElement] = [:]
    private var elementHandles: [AXElementKey: ElementRef] = [:]
    private var opaques: [OpaqueRef: CFTypeRef] = [:]
    private var opaqueHandles: [OpaqueValueKey: OpaqueRef] = [:]
    private var nextHandle = 1

    init(root: AXUIElement, primaryScreenMaxY: CGFloat) {
        self.primaryScreenMaxY = primaryScreenMaxY
        // Taken from the element rather than passed in, so that every caller gets hit
        // testing without having to know it was asking for it.
        var processIdentifier: pid_t = 0
        if AXUIElementGetPid(root, &processIdentifier) == .success, processIdentifier > 0 {
            let application = AXUIElementCreateApplication(processIdentifier)
            Self.applyHarvestTimeout(to: application)
            hitTestRoot = application
        } else {
            hitTestRoot = nil
        }
        rootReference = ElementRef(raw: 0)
        elements[rootReference] = root
        elementHandles[AXElementKey(root)] = rootReference
        Self.applyHarvestTimeout(to: root)
    }

    /// Bounds what any one read here is allowed to cost.
    ///
    /// A timeout set on an element applies to that reference alone — not to its
    /// children, and not to another reference that compares equal to it — so it has to
    /// be applied to each element as it is discovered. That is the whole reason it can
    /// be this tight: the references this reader interns are used for harvesting and
    /// nothing else, and the ones the edit path holds keep the patient global value.
    private static func applyHarvestTimeout(to element: AXUIElement) {
        _ = AXUIElementSetMessagingTimeout(
            element,
            AccessibilityElementReader.harvestMessagingTimeout
        )
    }

    let rootReference: ElementRef

    // MARK: - Handles

    private func reference(for element: AXUIElement) -> ElementRef {
        let key = AXElementKey(element)
        if let existing = elementHandles[key] { return existing }
        let reference = ElementRef(raw: nextHandle)
        nextHandle += 1
        elements[reference] = element
        elementHandles[key] = reference
        Self.applyHarvestTimeout(to: element)
        return reference
    }

    /// Interned so that a value the application considers equal comes back as the same
    /// handle. Walking a document backwards stops when a step answers with the marker it
    /// started from, and without interning that comparison could never be true.
    ///
    /// `CFEqual` on a marker compares the position it encodes. Should an engine ever
    /// answer otherwise, the walk simply runs its full length instead of stopping early.
    private func reference(forOpaque value: CFTypeRef) -> OpaqueRef {
        let key = OpaqueValueKey(value)
        if let existing = opaqueHandles[key] { return existing }
        let reference = OpaqueRef(raw: nextHandle)
        nextHandle += 1
        opaques[reference] = value
        opaqueHandles[key] = reference
        return reference
    }

    private func element(for reference: ElementRef) -> AXUIElement? {
        elements[reference]
    }

    // MARK: - AccessibilityReading

    func attributes(_ names: [String], of element: ElementRef) -> [String: ContextValue] {
        guard let target = self.element(for: element) else { return [:] }

        // The synthetic frame is asked for as its two real halves, then put back
        // together — one round trip rather than two, and already flipped.
        var requested = names.filter { $0 != AXName.frame }
        let wantsFrame = names.contains(AXName.frame)
        if wantsFrame {
            requested.append(kAXPositionAttribute as String)
            requested.append(kAXSizeAttribute as String)
        }
        guard !requested.isEmpty else { return [:] }

        let raw = AccessibilityElementReader.multipleAttributeValues(requested, from: target)
        var mapped: [String: ContextValue] = [:]
        for name in names where name != AXName.frame {
            if let value = raw[name], let converted = contextValue(from: value) {
                mapped[name] = converted
            }
        }
        if wantsFrame,
           let frame = frame(
            position: raw[kAXPositionAttribute as String],
            size: raw[kAXSizeAttribute as String]
           ) {
            mapped[AXName.frame] = .rect(frame)
        }
        return mapped
    }

    func attribute(_ name: String, of element: ElementRef) -> ContextValue? {
        guard let target = self.element(for: element) else { return nil }
        if name == AXName.frame {
            return AccessibilityElementReader.rect(
                of: target,
                primaryScreenMaxY: primaryScreenMaxY
            ).map { ContextValue.rect($0) }
        }
        guard let value = AccessibilityElementReader.attributeValue(name, from: target) else {
            return nil
        }
        return contextValue(from: value)
    }

    func parameterized(
        _ name: String,
        of element: ElementRef,
        parameter: ContextValue
    ) -> ContextValue? {
        guard let target = self.element(for: element),
              let argument = coreFoundationValue(from: parameter) else {
            return nil
        }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            target,
            name as CFString,
            argument,
            &result
        ) == .success, let result else {
            return nil
        }
        return contextValue(from: result)
    }

    func isSettable(_ name: String, of element: ElementRef) -> Bool {
        guard let target = self.element(for: element) else { return false }
        return AccessibilityElementReader.isAttributeSettable(name, on: target)
    }

    func elementAtPosition(_ point: CGPoint) -> ElementRef? {
        guard let hitTestRoot else { return nil }
        var found: AXUIElement?
        // The point arrives in AppKit coordinates, as every rectangle in this pipeline
        // does. The Accessibility API measures downwards from the top of the primary
        // display, which is the same flip the reader performs for rectangles.
        guard AXUIElementCopyElementAtPosition(
            hitTestRoot,
            Float(point.x),
            Float(primaryScreenMaxY - point.y),
            &found
        ) == .success, let found else {
            return nil
        }
        return reference(for: found)
    }

    func parameterizedAttributeNames(of element: ElementRef) -> Set<String> {
        guard let target = self.element(for: element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(target, &names) == .success,
              let names = names as? [String] else {
            return []
        }
        return Set(names)
    }

    // MARK: - Conversion

    private func frame(position: Any?, size: Any?) -> CGRect? {
        guard let positionValue = AccessibilityElementReader.axValue(position),
              let sizeValue = AccessibilityElementReader.axValue(size) else {
            return nil
        }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &extent) else {
            return nil
        }
        return AccessibilityElementReader.appKitRect(
            fromAccessibilityRect: CGRect(origin: origin, size: extent),
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    /// Anything the API can answer with, in the pipeline's own vocabulary.
    ///
    /// The final case is the important one. Text markers have no public type and no
    /// printable form, so rather than trying to recognise them they are simply whatever
    /// did not match anything else — handed a handle and passed back untouched.
    private func contextValue(from value: Any) -> ContextValue? {
        if let string = value as? String { return .string(string) }
        if let attributed = value as? NSAttributedString { return .string(attributed.string) }
        if let url = value as? URL { return .string(url.absoluteString) }
        if let strings = value as? [String] { return .strings(strings) }

        let raw = value as CFTypeRef
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return .boolean((value as? NSNumber)?.boolValue ?? false)
        }
        if let number = value as? NSNumber { return .number(number.intValue) }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return .element(reference(for: unsafeDowncast(raw, to: AXUIElement.self)))
        }
        if let array = value as? [Any] {
            let converted = array.compactMap { item -> AXUIElement? in
                let element = item as CFTypeRef
                guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast(element, to: AXUIElement.self)
            }
            if converted.count == array.count, !array.isEmpty {
                return .elements(converted.map(reference(for:)))
            }
            return nil
        }
        if CFGetTypeID(raw) == AXValueGetTypeID() {
            let axValue = unsafeDowncast(raw, to: AXValue.self)
            switch AXValueGetType(axValue) {
            case .cfRange:
                var range = CFRange()
                guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
                return .textRange(location: range.location, length: range.length)
            case .cgPoint:
                var point = CGPoint.zero
                guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
                return .point(
                    CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
                )
            case .cgRect:
                var rect = CGRect.zero
                guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
                return .rect(
                    AccessibilityElementReader.appKitRect(
                        fromAccessibilityRect: rect,
                        primaryScreenMaxY: primaryScreenMaxY
                    )
                )
            default:
                return nil
            }
        }
        return .opaque(reference(forOpaque: raw))
    }

    private func coreFoundationValue(from value: ContextValue) -> CFTypeRef? {
        switch value {
        case let .element(reference):
            return element(for: reference)
        case let .opaque(reference):
            return opaques[reference]
        case let .opaques(references):
            let resolved = references.compactMap { opaques[$0] }
            guard resolved.count == references.count else { return nil }
            return resolved as CFArray
        case let .string(text):
            return text as CFString
        case let .textRange(location, length):
            var range = CFRange(location: location, length: length)
            return AXValueCreate(.cfRange, &range)
        case let .number(value):
            return value as CFNumber
        case let .point(point):
            var flipped = CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
            return AXValueCreate(.cgPoint, &flipped)
        case let .rect(rect):
            // Rectangles arrive from the pipeline in AppKit coordinates and have to go
            // back the way they came. The conversion is its own inverse.
            var flipped = AccessibilityElementReader.appKitRect(
                fromAccessibilityRect: rect,
                primaryScreenMaxY: primaryScreenMaxY
            )
            return AXValueCreate(.cgRect, &flipped)
        default:
            return nil
        }
    }
}

/// A hashable identity for a value whose type this process does not know.
private struct OpaqueValueKey: Hashable {
    let value: CFTypeRef

    init(_ value: CFTypeRef) {
        self.value = value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.value, rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(value))
    }
}
