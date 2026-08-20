import CoreGraphics
import Foundation

/// Serves a recorded tree to the pipeline, so the real sources and the real ranking can
/// be exercised without the application they were recorded from — or the Accessibility
/// permission needed to talk to it.
public final class FixtureAccessibilityReader: AccessibilityReading {
    public let fixture: AXFixture

    private var nodesByID: [Int: AXFixture.Node] = [:]
    /// Derived from the child links rather than recorded, so the two directions of the
    /// tree cannot disagree and no fixture has to state the same edge twice.
    private var parentByID: [Int: Int] = [:]
    private var refToNode: [ElementRef: Int] = [:]
    private var nodeToRef: [Int: ElementRef] = [:]
    private var refToMarker: [OpaqueRef: String] = [:]
    private var markerToRef: [String: OpaqueRef] = [:]
    private var nextHandle = 1

    /// Every read this reader answered, for asserting that a source did not spend more
    /// than it should have.
    public private(set) var readLog: [String] = []

    public init(fixture: AXFixture) {
        self.fixture = fixture
        for node in fixture.nodes {
            nodesByID[node.id] = node
            for child in node.children {
                parentByID[child] = node.id
            }
        }
    }

    public var focusedElement: ElementRef {
        reference(forNode: fixture.focusedNode)
    }

    public func target(
        targetKind: TextEditTargetKind = .sentence,
        capturedText: String = "",
        targetRange: NSRange = NSRange(location: 0, length: 0)
    ) -> ContextTarget {
        ContextTarget(
            element: focusedElement,
            applicationName: fixture.application,
            bundleIdentifier: fixture.bundleIdentifier,
            targetKind: targetKind,
            capturedText: capturedText,
            targetRange: targetRange
        )
    }

    // MARK: - Handles

    private func reference(forNode id: Int) -> ElementRef {
        if let existing = nodeToRef[id] { return existing }
        let reference = ElementRef(raw: nextHandle)
        nextHandle += 1
        nodeToRef[id] = reference
        refToNode[reference] = id
        return reference
    }

    /// Equal marker names produce the same handle, matching the live requirement that a
    /// marker's identity survives a round trip.
    private func reference(forMarker name: String) -> OpaqueRef {
        if let existing = markerToRef[name] { return existing }
        let reference = OpaqueRef(raw: nextHandle)
        nextHandle += 1
        markerToRef[name] = reference
        refToMarker[reference] = name
        return reference
    }

    private func node(for element: ElementRef) -> AXFixture.Node? {
        refToNode[element].flatMap { nodesByID[$0] }
    }

    private func value(_ recorded: FixtureValue) -> ContextValue {
        switch recorded {
        case let .string(value): .string(value)
        case let .strings(value): .strings(value)
        case let .number(value): .number(value)
        case let .boolean(value): .boolean(value)
        case let .element(id): .element(reference(forNode: id))
        case let .elements(ids): .elements(ids.map(reference(forNode:)))
        case let .rect(x, y, width, height):
            .rect(CGRect(x: x, y: y, width: width, height: height))
        case let .textRange(location, length): .textRange(location: location, length: length)
        case let .marker(name): .opaque(reference(forMarker: name))
        case let .markers(names): .opaques(names.map(reference(forMarker:)))
        }
    }

    /// Attributes the tree itself answers, so a recording only states the edges once.
    private func derivedAttribute(
        _ name: String,
        of node: AXFixture.Node
    ) -> ContextValue? {
        switch name {
        case AXName.children:
            return .elements(node.children.map(reference(forNode:)))
        case AXName.parent:
            return parentByID[node.id].map { .element(reference(forNode: $0)) }
        default:
            return nil
        }
    }

    // MARK: - AccessibilityReading

    public func attributes(
        _ names: [String],
        of element: ElementRef
    ) -> [String: ContextValue] {
        readLog.append("attributes(\(names.joined(separator: ",")))")
        guard let node = node(for: element) else { return [:] }
        var mapped: [String: ContextValue] = [:]
        for name in names {
            if let derived = derivedAttribute(name, of: node) {
                mapped[name] = derived
            } else if let recorded = node.attributes[name] {
                mapped[name] = value(recorded)
            }
        }
        return mapped
    }

    public func attribute(_ name: String, of element: ElementRef) -> ContextValue? {
        readLog.append("attribute(\(name))")
        guard let node = node(for: element) else { return nil }
        if let derived = derivedAttribute(name, of: node) { return derived }
        return node.attributes[name].map(value)
    }

    public func parameterized(
        _ name: String,
        of element: ElementRef,
        parameter: ContextValue
    ) -> ContextValue? {
        readLog.append("parameterized(\(name))")
        guard let node = node(for: element),
              let answers = node.parameterized[name],
              let key = AXFixture.parameterKey(
                for: parameter,
                markerID: { [refToMarker] in refToMarker[$0] },
                nodeID: { [refToNode] in refToNode[$0] }
              ),
              let recorded = answers[key] else {
            return nil
        }
        return value(recorded)
    }

    public func isSettable(_ name: String, of element: ElementRef) -> Bool {
        readLog.append("isSettable(\(name))")
        return node(for: element)?.settableAttributes.contains(name) ?? false
    }

    public func parameterizedAttributeNames(of element: ElementRef) -> Set<String> {
        readLog.append("parameterizedAttributeNames")
        return Set(node(for: element)?.parameterizedNames ?? [])
    }
}
