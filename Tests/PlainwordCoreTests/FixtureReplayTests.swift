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

    /// What each source finds on its own.
    ///
    /// The pipeline stops as soon as a request has what it needs, so its result says
    /// which strategy answered first — not which one answered best. A recording made
    /// exhaustively holds the evidence for all of them, and this is what reads it: one
    /// line per source, whether or not it would ever have been reached.
    private func perSource(_ fixture: AXFixture) {
        print("──────────────────────────────────────────────────────────────────")
        print("what each source finds on its own:")
        for source in ContextPipeline.standardSources {
            let reader = FixtureAccessibilityReader(fixture: fixture)
            let workspace = ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 2_000),
                target: reader.target(),
                profile: .profile(forBundleIdentifier: fixture.bundleIdentifier)
            )
            guard source.supports(workspace.target) else {
                print("  \(source.name): does not apply here")
                continue
            }
            let produced = source.read(workspace)
            let prose = ContextSufficiency.proseLength(of: produced)
            let reads = workspace.budget.spentRoundTrips
            guard !produced.isEmpty else {
                print("  \(source.name): nothing, in \(reads) reads")
                continue
            }
            print("  \(source.name): \(produced.count) candidates, \(prose) chars of "
                + "prose, \(reads) reads")
            for candidate in produced.prefix(4) {
                let flattened = candidate.text.replacingOccurrences(of: "\n", with: " ")
                let text = flattened.count <= 200
                    ? flattened
                    : flattened.prefix(90) + " …… " + flattened.suffix(90)
                print("      [\(candidate.kind.rawValue)] \(text)")
            }
            if produced.count > 4 {
                print("      … and \(produced.count - 4) more")
            }
        }
    }

    private func replay(_ fixture: AXFixture) -> ContextAssembly {
        let reader = FixtureAccessibilityReader(fixture: fixture)
        return ContextPipeline().assemble(
            ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 2_000),
                target: reader.target(),
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
        engine:         \(telemetry.engine?.rawValue ?? "none")
        prose found:    \(telemetry.harvestedProseLength) of \
        \(telemetry.requiredProseLength) needed\(telemetry.isUnderfed ? "   ← UNDERFED" : "")
        fragments:      \(assembly.fragments.count)
        ──────────────────────────────────────────────────────────────────
        """)
        for fragment in assembly.fragments {
            let origin = fragment.provenance.map {
                "\($0.source)/\($0.confidence == .stated ? "stated" : "inferred")"
            } ?? "—"
            // Both ends, because for a passage the useful question is what sits nearest
            // the caret — and that is at the end, where a preview of the opening never
            // shows it.
            let flattened = fragment.text.replacingOccurrences(of: "\n", with: " ")
            let text = flattened.count <= 260
                ? flattened
                : flattened.prefix(120) + "  …\(flattened.count - 240) more…  "
                    + flattened.suffix(120)
            print("  [\(fragment.kind.rawValue)] (\(origin)) \(flattened.count) chars\n      \(text)")
        }

        perSource(fixture)

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
        hit tests recorded: \(fixture.hitTests?.count ?? 0)
        """)
    }
}
