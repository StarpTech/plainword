import AppKit
import ApplicationServices
import Foundation
import PlainwordCore

/// Records the Accessibility tree an assembly actually read, as a replayable fixture.
///
/// It records by watching rather than by crawling. A recorder that tried to dump
/// everything would have to guess which parameterized reads matter — and the marker
/// calls take opaque parameters that cannot be enumerated at all. Sitting between the
/// pipeline and a live application instead, it captures exactly the questions that were
/// asked and the answers that came back.
///
/// The trade that comes with that: a fixture answers the questions the pipeline asked
/// when it was recorded. Change what the pipeline asks and the recording has to be made
/// again — which is the ordinary bargain of recorded fixtures, and cheap next to having
/// no way to test against a real application at all.
final class RecordingAccessibilityReader: AccessibilityReading {
    private let base: LiveAccessibilityReader

    private final class MutableNode {
        var attributes: [String: FixtureValue] = [:]
        var parameterized: [String: [String: FixtureValue]] = [:]
        var parameterizedNames: [String] = []
        var settableAttributes: [String] = []
        var children: [Int] = []
    }

    private var nodes: [Int: MutableNode] = [:]
    /// Recorded so that a child discovered only through its parent still ends up in the
    /// tree the fixture describes.
    private var parents: [Int: Int] = [:]

    private let childBearingAttributes: Set<String> = [
        AXName.children,
        AXName.visibleChildren,
        AXName.childrenInNavigationOrder,
        AXName.contents,
        AXName.rows,
        AXName.visibleRows
    ]

    init(base: LiveAccessibilityReader) {
        self.base = base
    }

    var rootReference: ElementRef { base.rootReference }

    // MARK: - AccessibilityReading

    func attributes(_ names: [String], of element: ElementRef) -> [String: ContextValue] {
        let values = base.attributes(names, of: element)
        for (name, value) in values {
            record(name: name, value: value, of: element)
        }
        return values
    }

    func attribute(_ name: String, of element: ElementRef) -> ContextValue? {
        let value = base.attribute(name, of: element)
        if let value {
            record(name: name, value: value, of: element)
        }
        return value
    }

    func parameterized(
        _ name: String,
        of element: ElementRef,
        parameter: ContextValue
    ) -> ContextValue? {
        let value = base.parameterized(name, of: element, parameter: parameter)
        guard let value,
              let key = AXFixture.parameterKey(
                for: parameter,
                markerID: Self.markerID,
                nodeID: { $0.raw }
              ),
              let recorded = fixtureValue(value) else {
            return value
        }
        node(for: element).parameterized[name, default: [:]][key] = recorded
        return value
    }

    func isSettable(_ name: String, of element: ElementRef) -> Bool {
        let settable = base.isSettable(name, of: element)
        if settable {
            let node = node(for: element)
            if !node.settableAttributes.contains(name) {
                node.settableAttributes.append(name)
            }
        }
        return settable
    }

    func parameterizedAttributeNames(of element: ElementRef) -> Set<String> {
        let names = base.parameterizedAttributeNames(of: element)
        node(for: element).parameterizedNames = names.sorted()
        return names
    }

    // MARK: - Recording

    private func node(for element: ElementRef) -> MutableNode {
        if let existing = nodes[element.raw] { return existing }
        let created = MutableNode()
        nodes[element.raw] = created
        return created
    }

    private func record(name: String, value: ContextValue, of element: ElementRef) {
        let target = node(for: element)
        if let recorded = fixtureValue(value) {
            target.attributes[name] = recorded
        }

        // The fixture describes its tree once, through child links, and derives every
        // parent from them. Both directions of a read therefore feed the same edges.
        switch (name, value) {
        case (AXName.parent, let .element(parent)):
            parents[element.raw] = parent.raw
            append(child: element.raw, to: parent.raw)
        case (let name, let .elements(children)) where childBearingAttributes.contains(name):
            for child in children {
                append(child: child.raw, to: element.raw)
            }
        default:
            break
        }
    }

    private func append(child: Int, to parent: Int) {
        let node = node(for: ElementRef(raw: parent))
        guard !node.children.contains(child) else { return }
        node.children.append(child)
    }

    private static func markerID(_ reference: OpaqueRef) -> String {
        "m\(reference.raw)"
    }

    private func fixtureValue(_ value: ContextValue) -> FixtureValue? {
        switch value {
        case let .string(text): .string(text)
        case let .strings(texts): .strings(texts)
        case let .number(number): .number(number)
        case let .boolean(flag): .boolean(flag)
        case let .element(reference): .element(reference.raw)
        case let .elements(references): .elements(references.map(\.raw))
        case let .rect(rect): .rect(rect)
        case let .textRange(location, length): .textRange(location: location, length: length)
        case let .opaque(reference): .marker(Self.markerID(reference))
        case let .opaques(references): .markers(references.map(Self.markerID))
        }
    }

    // MARK: - Output

    func fixture(
        application: String,
        bundleIdentifier: String?,
        scenario: String
    ) -> AXFixture {
        AXFixture(
            application: application,
            bundleIdentifier: bundleIdentifier,
            scenario: scenario,
            focusedNode: rootReference.raw,
            nodes: nodes.keys.sorted().map { id in
                let node = nodes[id]!
                return AXFixture.Node(
                    id: id,
                    attributes: node.attributes,
                    parameterized: node.parameterized,
                    parameterizedNames: node.parameterizedNames,
                    settableAttributes: node.settableAttributes,
                    children: node.children
                )
            }
        )
    }
}

/// Captures the tree behind whatever is focused right now, and hands it to the author to
/// save.
///
/// A recording is a verbatim copy of the writing on screen, so it is never written
/// anywhere on its own: the save panel is how the author says which one they meant to
/// keep and where it should go.
@MainActor
enum AXFixtureCapture {
    struct Result {
        let fixture: AXFixture
        let telemetry: ContextTelemetry
    }

    static func recordFocusedTree(
        element: AXUIElement,
        applicationName: String,
        bundleIdentifier: String?,
        targetKind: TextEditTargetKind,
        scenario: String,
        primaryScreenMaxY: CGFloat
    ) -> Result {
        let recorder = RecordingAccessibilityReader(
            base: LiveAccessibilityReader(
                root: element,
                primaryScreenMaxY: primaryScreenMaxY
            )
        )
        let workspace = ContextWorkspace(
            reader: recorder,
            budget: ContextBudget(maximumRoundTrips: 600, duration: .seconds(3)),
            target: ContextTarget(
                element: recorder.rootReference,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                targetKind: targetKind
            ),
            profile: .profile(forBundleIdentifier: bundleIdentifier)
        )
        let assembly = ContextPipeline().assemble(workspace)
        return Result(
            fixture: recorder.fixture(
                application: applicationName,
                bundleIdentifier: bundleIdentifier,
                scenario: scenario
            ),
            telemetry: assembly.telemetry
        )
    }

    static func save(_ fixture: AXFixture, suggestedName: String) throws -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fixture)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.title = "Save accessibility recording"
        panel.message = """
        This file contains the text that was on screen in \(fixture.application). \
        Read it before sharing it.
        """
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url)
        return url
    }
}
