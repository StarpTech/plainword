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
    private var hitTests: [String: Int] = [:]
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

    func elementAtPosition(_ point: CGPoint) -> ElementRef? {
        guard let element = base.elementAtPosition(point) else { return nil }
        hitTests[AXFixture.hitTestKey(for: point)] = element.raw
        // A point can land on an element nothing else ever asked about, and a fixture
        // that answered a hit test with a node it did not contain would replay as an
        // element with no facts at all.
        _ = node(for: element)
        return element
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
        case let .point(point): .point(point)
        case let .textRange(location, length): .textRange(location: location, length: length)
        case let .opaque(reference): .marker(Self.markerID(reference))
        case let .opaques(references): .markers(references.map(Self.markerID))
        }
    }

    // MARK: - Output

    func fixture(
        application: String,
        bundleIdentifier: String?,
        scenario: String,
        capturedText: String,
        targetKind: TextEditTargetKind
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
            },
            hitTests: hitTests.isEmpty ? nil : hitTests,
            capturedText: capturedText,
            targetKind: targetKind.rawValue
        )
    }
}

/// Captures the tree behind a field the author pointed at, and writes it to the fixture
/// folder.
///
/// A recording is a verbatim copy of the writing on screen. It stays on this machine, in
/// one named folder stated back to the author after every recording, and nothing there
/// is ever overwritten.
@MainActor
enum AXFixtureCapture {
    struct Result {
        let fixture: AXFixture
        let telemetry: ContextTelemetry
    }

    static func recordTree(
        element: AXUIElement,
        applicationName: String,
        bundleIdentifier: String?,
        targetKind: TextEditTargetKind,
        capturedText: String,
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
            // Larger than any request would allow itself, because every source runs and
            // nothing is waiting for the answer.
            budget: ContextBudget(maximumRoundTrips: 2_000, duration: .seconds(8)),
            target: ContextTarget(
                element: recorder.rootReference,
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                targetKind: targetKind,
                capturedText: capturedText
            ),
            profile: .profile(forBundleIdentifier: bundleIdentifier)
        )
        // Exhaustively, so the recording holds evidence for every strategy rather than
        // only for the one that would have answered first today.
        let harvest = ContextPipeline().harvestExhaustively(workspace)
        let assembly = harvest.assembly(for: workspace.target)
        return Result(
            fixture: recorder.fixture(
                application: applicationName,
                bundleIdentifier: bundleIdentifier,
                scenario: scenario,
                capturedText: capturedText,
                targetKind: targetKind
            ),
            telemetry: assembly.telemetry
        )
    }

    /// Where recordings go, and why they go there without asking.
    ///
    /// A save panel was the first design, and during a session that records a dozen
    /// applications in a row it is the wrong one: the panel belongs to an application
    /// with no windows of its own, so it opens behind whatever is frontmost, or on
    /// another Space when the application being recorded is full screen — and from the
    /// author's side that is indistinguishable from the recording having failed.
    ///
    /// A named folder is the standing decision instead. It is stated in the status line
    /// after every recording, so where the writing went is never a mystery, and nothing
    /// is ever overwritten.
    static var directory: URL {
        URL.homeDirectory.appending(path: "plainword-fixtures")
    }

    /// What a recording is called, given only the application and the clock.
    ///
    /// The author used to type a name before recording. That is one more thing to do
    /// while the case being recorded is waiting on screen, and an empty field made every
    /// file from an application collide. The application and the moment separate them on
    /// their own, and a case worth keeping can be renamed afterwards.
    static func name(application: String, recordedAt: Date) -> String {
        let stamp = recordedAt.formatted(
            .verbatim(
                "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                locale: .init(identifier: "en_US_POSIX"),
                timeZone: .current,
                calendar: .init(identifier: .gregorian)
            )
        )
        let stem = application
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return stem + "-" + stamp
    }

    static func write(_ fixture: AXFixture, named name: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(fixture)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let stem = (name as NSString).deletingPathExtension
        var url = directory.appending(path: stem + ".json")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appending(path: "\(stem)-\(attempt).json")
            attempt += 1
        }
        try data.write(to: url)
        return url
    }
}
