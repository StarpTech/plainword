import CoreGraphics
import Foundation

/// A recorded Accessibility subtree, sufficient to replay every decision the pipeline
/// makes about it.
///
/// The point of recording one is that the pipeline's hardest question — did it find the
/// right context in this application? — has no answer anyone can check by reasoning. It
/// needs the tree that a real Slack, a real Gmail, a real Mail compose window actually
/// publishes. Captured once, that tree makes every later change to the ranking or the
/// traversal a measurable difference rather than an argument.
public struct AXFixture: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var id: Int
        public var attributes: [String: FixtureValue]
        /// Recorded answers to parameterized reads, keyed by the parameter they were
        /// asked with. See `AXFixture.parameterKey(for:)`.
        public var parameterized: [String: [String: FixtureValue]]
        public var parameterizedNames: [String]
        public var settableAttributes: [String]
        public var children: [Int]

        public init(
            id: Int,
            attributes: [String: FixtureValue] = [:],
            parameterized: [String: [String: FixtureValue]] = [:],
            parameterizedNames: [String] = [],
            settableAttributes: [String] = [],
            children: [Int] = []
        ) {
            self.id = id
            self.attributes = attributes
            self.parameterized = parameterized
            self.parameterizedNames = parameterizedNames
            self.settableAttributes = settableAttributes
            self.children = children
        }
    }

    public var application: String
    public var bundleIdentifier: String?
    public var scenario: String
    public var focusedNode: Int
    public var nodes: [Node]
    /// What the application answered when asked what it had drawn at a point, keyed by
    /// the point. Optional so that a recording made before hit testing existed still
    /// replays — it simply has none to answer with.
    public var hitTests: [String: Int]?
    /// What the field held when the recording was taken, and what kind of request it was
    /// taken for.
    ///
    /// Both are needed for a replay to mean anything. Without the text, a source cannot
    /// tell where the author's own writing begins and hands it back as though the
    /// interface had said it; without the kind, the replay measures itself against the
    /// wrong allowance — a draft at an empty caret needs three times the prose an edit
    /// does before it counts as answered.
    public var capturedText: String?
    public var targetKind: String?

    public init(
        application: String,
        bundleIdentifier: String? = nil,
        scenario: String,
        focusedNode: Int,
        nodes: [Node],
        hitTests: [String: Int]? = nil,
        capturedText: String? = nil,
        targetKind: String? = nil
    ) {
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.scenario = scenario
        self.focusedNode = focusedNode
        self.nodes = nodes
        self.hitTests = hitTests
        self.capturedText = capturedText
        self.targetKind = targetKind
    }

    /// How a hit test is keyed in a recording. Rounded to whole points, which is finer
    /// than any ladder steps and coarse enough to survive the round trip through JSON.
    public static func hitTestKey(for point: CGPoint) -> String {
        "\(Int(point.x.rounded())):\(Int(point.y.rounded()))"
    }

    /// How a parameterized read is keyed in a recording.
    ///
    /// The parameter is an element or a marker, neither of which has a printable form,
    /// so the recording names them by the identity it gave them when it captured them.
    public static func parameterKey(
        for value: ContextValue,
        markerID: (OpaqueRef) -> String?,
        nodeID: (ElementRef) -> Int?
    ) -> String? {
        switch value {
        case let .element(reference):
            return nodeID(reference).map { "element:\($0)" }
        case let .opaque(reference):
            return markerID(reference).map { "marker:\($0)" }
        case let .opaques(references):
            let identifiers = references.compactMap(markerID)
            guard identifiers.count == references.count else { return nil }
            return "markers:" + identifiers.joined(separator: "|")
        case let .string(value):
            return "string:\(value)"
        case let .textRange(location, length):
            return "range:\(location):\(length)"
        case let .number(value):
            return "number:\(value)"
        case let .rect(rect):
            return "rect:\(Int(rect.minX)):\(Int(rect.minY))"
                + ":\(Int(rect.width)):\(Int(rect.height))"
        case let .point(point):
            return "point:\(Int(point.x)):\(Int(point.y))"
        default:
            return nil
        }
    }
}

/// A recorded Accessibility value.
public enum FixtureValue: Codable, Equatable, Sendable {
    case string(String)
    case strings([String])
    case number(Int)
    case boolean(Bool)
    case element(Int)
    case elements([Int])
    case rect(x: Double, y: Double, width: Double, height: Double)
    case point(x: Double, y: Double)
    case textRange(location: Int, length: Int)
    /// A text marker, named by whatever identity the recording gave it. Equal names mean
    /// the application considered the markers equal.
    case marker(String)
    case markers([String])

    public static func point(_ point: CGPoint) -> FixtureValue {
        .point(x: Double(point.x), y: Double(point.y))
    }

    public static func rect(_ rect: CGRect) -> FixtureValue {
        .rect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}
