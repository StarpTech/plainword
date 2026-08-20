import Foundation
import XCTest
@testable import PlainwordCore

/// Replays recorded accessibility trees through the real pipeline.
///
/// Point it at a directory of recordings:
///
///     PLAINWORD_FIXTURES=~/plainword-fixtures swift test --filter FixtureReplay
///
/// It is a report rather than an assertion because the first thing a corpus is for is
/// looking: which sources answered, what they found, and what it cost. Assertions come
/// after, once a recording has been read and its right answer written down.
final class FixtureReplayTests: XCTestCase {
    func testReplayRecordedFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["PLAINWORD_FIXTURES"] else {
            throw XCTSkip("Set PLAINWORD_FIXTURES to a directory of recordings.")
        }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw XCTSkip("No recordings in \(directory.path).") }

        for file in files {
            let fixture = try JSONDecoder().decode(
                AXFixture.self,
                from: try Data(contentsOf: file)
            )
            report(replay(fixture), for: fixture, file: file)
        }
    }

    private func replay(_ fixture: AXFixture) -> ContextAssembly {
        let reader = FixtureAccessibilityReader(fixture: fixture)
        return ContextPipeline().assemble(
            ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 2_000),
                target: reader.target(targetKind: .sentence),
                profile: .profile(forBundleIdentifier: fixture.bundleIdentifier)
            )
        )
    }

    private func report(
        _ assembly: ContextAssembly,
        for fixture: AXFixture,
        file: URL
    ) {
        let telemetry = assembly.telemetry
        print("""

        ══════════════════════════════════════════════════════════════════
        \(file.lastPathComponent) — \(fixture.application) [\(fixture.scenario)]
        nodes recorded: \(fixture.nodes.count)   reads on replay: \(telemetry.roundTrips)
        answered by:    \(telemetry.contributingSources.joined(separator: ", "))
        skipped:        \(telemetry.skippedSources.joined(separator: ", "))
        satisfied after: \(telemetry.satisfiedAfterTier.map(String.init(describing:)) ?? "never")
        fragments:      \(assembly.fragments.count)
        ──────────────────────────────────────────────────────────────────
        """)
        for fragment in assembly.fragments {
            let origin = fragment.provenance.map {
                "\($0.source)/\($0.confidence == .stated ? "stated" : "inferred")"
            } ?? "—"
            let text = fragment.text
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(150)
            print("  [\(fragment.kind.rawValue)] (\(origin))\n      \(text)")
        }

        // The structural facts worth knowing about a recording, whatever it found.
        let roles = Set(fixture.nodes.compactMap { node -> String? in
            guard case let .string(role)? = node.attributes[AXName.role] else { return nil }
            return role
        })
        let markerCapable = fixture.nodes.filter {
            $0.parameterizedNames.contains { $0.contains("TextMarker") }
        }
        print("""
        ──────────────────────────────────────────────────────────────────
        web area present: \(roles.contains(AXRole.webArea))   \
        window present: \(roles.contains(AXRole.window))
        nodes answering marker attributes: \(markerCapable.count)
        """)
    }
}
