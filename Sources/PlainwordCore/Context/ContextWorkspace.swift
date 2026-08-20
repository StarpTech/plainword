import CoreGraphics
import Foundation

/// What one read of an element tells the pipeline about it.
public struct ElementFacts: Equatable, Sendable {
    public let role: String?
    public let subrole: String?
    public let frame: CGRect?
    public let isHidden: Bool
    public let isEditable: Bool
    public let isProtected: Bool
    /// A region the page updates on its own — a toast, a timer, an unread count. Its
    /// text is real but it is never what the author is writing about.
    public let isLiveRegion: Bool

    public init(
        role: String? = nil,
        subrole: String? = nil,
        frame: CGRect? = nil,
        isHidden: Bool = false,
        isEditable: Bool = false,
        isProtected: Bool = false,
        isLiveRegion: Bool = false
    ) {
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.isHidden = isHidden
        self.isEditable = isEditable
        self.isProtected = isProtected
        self.isLiveRegion = isLiveRegion
    }

    /// Whether a subtree should be left alone entirely.
    public var isExcludedFromContext: Bool {
        if isHidden || isProtected || isLiveRegion { return true }
        if let subrole, AXRole.chromeLandmarks.contains(subrole) { return true }
        return false
    }
}

public struct ContextAncestor: Sendable {
    public let element: ElementRef
    /// The child of this ancestor that lies on the path down to the focused field.
    public let childOnFocusedPath: ElementRef
    public let facts: ElementFacts
    public let distance: Int
}

/// The shared state of one context assembly: who to ask, what is left to spend, and
/// whatever has already been learned.
///
/// Memoising is the point as much as the plumbing is. Several sources want the same
/// ancestors and the same handful of element facts, and re-reading them would have each
/// source paying for the last one's work out of a budget they share.
public final class ContextWorkspace {
    public let reader: AccessibilityReading
    public let budget: ContextBudget
    public let target: ContextTarget
    public let profile: ApplicationProfile
    public var telemetry = ContextTelemetry()

    private var cachedAncestry: [ContextAncestor]?
    private var cachedFacts: [ElementRef: ElementFacts] = [:]
    private var cachedParameterizedNames: [ElementRef: Set<String>] = [:]

    /// How far up to look for a window.
    ///
    /// The traversal this replaces used fourteen, and a recording of a GitHub pull
    /// request showed what that costs: fifteen levels of nested `AXGroup` from the
    /// comment box reach only as far as the page's `<main>` landmark — still inside the
    /// document, with the web area and the window further up again. Stopping there meant
    /// no web area, so no text markers; no window, so no title; and no viewport, so the
    /// traversal could not even clip itself to the page.
    ///
    /// Each level is one cheap read and the walk ends the moment it finds a window,
    /// which in a browser is around twenty. The ceiling is only a guard against a tree
    /// that never ends, so it can afford to be far above what any real one needs.
    private let maximumAncestorDepth = 64

    public init(
        reader: AccessibilityReading,
        budget: ContextBudget,
        target: ContextTarget,
        profile: ApplicationProfile = .generic
    ) {
        self.reader = reader
        self.budget = budget
        self.target = target
        self.profile = profile
    }

    // MARK: - Metered reads

    /// Every read the sources make goes through here, so the budget cannot be forgotten
    /// by one of them and the round-trip count is the truth rather than an estimate.
    public func attributes(
        _ names: [String],
        of element: ElementRef
    ) -> [String: ContextValue] {
        guard budget.charge() else { return [:] }
        telemetry.roundTrips += 1
        return reader.attributes(names, of: element)
    }

    public func attribute(_ name: String, of element: ElementRef) -> ContextValue? {
        guard budget.charge() else { return nil }
        telemetry.roundTrips += 1
        return reader.attribute(name, of: element)
    }

    public func parameterized(
        _ name: String,
        of element: ElementRef,
        parameter: ContextValue
    ) -> ContextValue? {
        guard budget.charge() else { return nil }
        telemetry.roundTrips += 1
        return reader.parameterized(name, of: element, parameter: parameter)
    }

    public func isSettable(_ name: String, of element: ElementRef) -> Bool {
        guard budget.charge() else { return false }
        telemetry.roundTrips += 1
        return reader.isSettable(name, of: element)
    }

    public func parameterizedAttributeNames(of element: ElementRef) -> Set<String> {
        if let cached = cachedParameterizedNames[element] { return cached }
        guard budget.charge() else { return [] }
        telemetry.roundTrips += 1
        let names = reader.parameterizedAttributeNames(of: element)
        cachedParameterizedNames[element] = names
        return names
    }

    public func string(_ name: String, of element: ElementRef) -> String? {
        attribute(name, of: element)?.stringValue
    }

    public func element(_ name: String, of element: ElementRef) -> ElementRef? {
        attribute(name, of: element)?.elementValue
    }

    // MARK: - Derived reads

    private static let factAttributes = [
        AXName.role,
        AXName.subrole,
        AXName.frame,
        AXName.hidden,
        AXName.isEditable,
        AXName.containsProtectedContent,
        AXName.ariaLive
    ]

    public func facts(of element: ElementRef) -> ElementFacts {
        if let cached = cachedFacts[element] { return cached }
        let facts = makeFacts(from: attributes(Self.factAttributes, of: element))
        cachedFacts[element] = facts
        telemetry.nodesExamined += 1
        return facts
    }

    private func makeFacts(from values: [String: ContextValue]) -> ElementFacts {
        let live = values[AXName.ariaLive]?.stringValue
        return ElementFacts(
            role: values[AXName.role]?.stringValue,
            subrole: values[AXName.subrole]?.stringValue,
            frame: values[AXName.frame]?.rectValue,
            isHidden: values[AXName.hidden]?.boolValue ?? false,
            isEditable: values[AXName.isEditable]?.boolValue ?? false,
            isProtected: values[AXName.containsProtectedContent]?.boolValue ?? false,
            isLiveRegion: live.map { $0 != "off" && !$0.isEmpty } ?? false
        )
    }

    /// The text an element carries, if any, preferring what it holds over what it is
    /// called.
    public func readableText(of element: ElementRef) -> String? {
        let names = [AXName.value, AXName.title, AXName.description]
        let values = attributes(names, of: element)
        for name in names {
            if let text = values[name]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// The chain from the focused field up to its window.
    ///
    /// One read per level, not two: the parent pointer is asked for alongside the facts
    /// of the node it belongs to, and those facts are kept for whoever wants them next.
    /// That matters because a browser puts twenty levels of markup between a composer
    /// and its page, and the walk has to be able to afford all of them.
    public func ancestry() -> [ContextAncestor] {
        if let cachedAncestry { return cachedAncestry }

        var chain: [(element: ElementRef, facts: ElementFacts)] = []
        var current = target.element
        var parents: [ElementRef] = []

        for _ in 0...maximumAncestorDepth {
            guard !budget.isExhausted else { break }
            let values = attributes(Self.factAttributes + [AXName.parent], of: current)
            let nodeFacts = makeFacts(from: values)
            if cachedFacts[current] == nil {
                cachedFacts[current] = nodeFacts
                telemetry.nodesExamined += 1
            }
            chain.append((current, nodeFacts))
            if nodeFacts.role == AXRole.window { break }
            guard let parent = values[AXName.parent]?.elementValue else { break }
            parents.append(parent)
            current = parent
        }

        // The first entry is the field itself, which is not one of its own ancestors.
        var levels: [ContextAncestor] = []
        for index in 1..<max(1, chain.count) {
            levels.append(
                ContextAncestor(
                    element: chain[index].element,
                    childOnFocusedPath: chain[index - 1].element,
                    facts: chain[index].facts,
                    distance: index - 1
                )
            )
        }
        cachedAncestry = levels
        return levels
    }

    public func focusedFrame() -> CGRect? {
        let frame = facts(of: target.element).frame
        return frame == .zero ? nil : frame
    }

    /// The nearest enclosing ancestor with one of the given roles.
    public func nearestAncestor(withRoleIn roles: Set<String>) -> ContextAncestor? {
        ancestry().first { level in
            guard let role = level.facts.role else { return false }
            return roles.contains(role)
        }
    }

    /// The children worth visiting, in the order the application says they read.
    public func childElements(of element: ElementRef) -> [ElementRef] {
        let names = [
            AXName.contents,
            AXName.childrenInNavigationOrder,
            AXName.visibleChildren
        ]
        let values = attributes(names, of: element)
        let contents = values[AXName.contents]?.elementsValue ?? []
        let navigationOrder = values[AXName.childrenInNavigationOrder]?.elementsValue ?? []
        let visible = values[AXName.visibleChildren]?.elementsValue ?? []

        if !contents.isEmpty {
            let visibleSet = Set(visible)
            let visibleContents = visibleSet.isEmpty
                ? contents
                : contents.filter { visibleSet.contains($0) }
            let eligible = visibleContents.isEmpty ? contents : visibleContents
            return ordering(eligible, by: navigationOrder)
        }
        if !navigationOrder.isEmpty, !visible.isEmpty {
            return ordering(visible, by: navigationOrder)
        }
        if !visible.isEmpty { return visible }
        if !navigationOrder.isEmpty { return navigationOrder }
        return attribute(AXName.children, of: element)?.elementsValue ?? []
    }

    private func ordering(
        _ elements: [ElementRef],
        by preferredOrder: [ElementRef]
    ) -> [ElementRef] {
        guard !preferredOrder.isEmpty else { return elements }
        let eligible = Set(elements)
        var ordered = preferredOrder.filter { eligible.contains($0) }
        var placed = Set(ordered)
        for element in elements where placed.insert(element).inserted {
            ordered.append(element)
        }
        return ordered.isEmpty ? elements : ordered
    }

    /// Whether a text element is a place the author writes, and so not context.
    ///
    /// Chromium's contenteditable roots often leave `AXIsEditable` unset while still
    /// accepting a selection, so the settable check is what actually separates a
    /// composer from a read-only field displaying a value.
    public func isWritableTextElement(_ element: ElementRef, role: String?) -> Bool {
        guard let role,
              role == AXRole.textField || role == AXRole.textArea || role == AXRole.comboBox
        else {
            return false
        }
        return isSettable(AXName.value, of: element)
            || isSettable(AXName.selectedTextMarkerRange, of: element)
    }
}
