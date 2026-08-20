import CoreGraphics
import Foundation
import XCTest
@testable import PlainwordCore

/// Drives the real sources and the real ranking against recorded trees.
///
/// These are the tests the old traversal could not have: it mixed reading with deciding,
/// so the only thing reachable from a test was the geometry scoring, and only with
/// invented rectangles. Everything here runs the code that runs in production.
final class ContextPipelineTests: XCTestCase {
    // MARK: - Fixtures

    /// A Chromium-backed chat client: composer inside a web area, conversation above it.
    ///
    /// The marker vocabulary is the one a real Chrome recording showed — notably without
    /// `AXStartTextMarkerForTextMarkerRange`, which WebKit has and Chromium does not.
    private func electronChatFixture(
        supportsFieldBoundary: Bool = true
    ) -> AXFixture {
        let conversation = """
        Priya: The staging deploy went out at four and the error rate is flat. \
        Marcus: Nice. Did the migration finish before the cutover? \
        Priya: It did, about twenty minutes early. I have not written the summary yet.
        """
        let fieldText = "I can write that up"

        var rangesForElement: [String: FixtureValue] = ["element:2": .marker("area-range")]
        var strings: [String: FixtureValue] = [
            "marker:area-range": .string(conversation + " " + fieldText)
        ]
        var lengths: [String: FixtureValue] = [
            "marker:area-range": .number((conversation + " " + fieldText).utf16.count)
        ]
        if supportsFieldBoundary {
            rangesForElement["element:3"] = .marker("field-range")
            strings["marker:field-range"] = .string(fieldText)
            lengths["marker:field-range"] = .number(fieldText.utf16.count)
        }

        let vocabulary = [
            AXName.textMarkerRangeForUIElement,
            AXName.stringForTextMarkerRange,
            AXName.lengthForTextMarkerRange
        ]

        return AXFixture(
            application: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            scenario: "reply-in-channel",
            focusedNode: 3,
            nodes: [
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.title: .string("Slack — #release"),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 800))
                    ],
                    children: [2]
                ),
                .init(
                    id: 2,
                    attributes: [
                        AXName.role: .string(AXRole.webArea),
                        AXName.url: .string("https://app.slack.com/client/T01/C02?thread=17"),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 760))
                    ],
                    parameterized: [
                        AXName.textMarkerRangeForUIElement: rangesForElement,
                        AXName.stringForTextMarkerRange: strings,
                        AXName.lengthForTextMarkerRange: lengths
                    ],
                    parameterizedNames: vocabulary,
                    children: [3]
                ),
                .init(
                    id: 3,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(CGRect(x: 40, y: 20, width: 900, height: 60)),
                        AXName.isEditable: .boolean(true),
                        AXName.placeholder: .string("Message #release")
                    ],
                    settableAttributes: [AXName.value],
                    children: []
                )
            ]
        )
    }

    /// A native note: everything is inside one text area, and the only thing near it is
    /// the date header that used to be attached as a field hint.
    private func nativeNoteFixture(bundleIdentifier: String?) -> AXFixture {
        AXFixture(
            application: "Notes",
            bundleIdentifier: bundleIdentifier,
            scenario: "draft-at-end",
            focusedNode: 3,
            nodes: [
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.title: .string("Notes — 12 notes"),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 900, height: 700))
                    ],
                    children: [2]
                ),
                .init(
                    id: 2,
                    attributes: [
                        AXName.role: .string(AXRole.scrollArea),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 900, height: 660))
                    ],
                    children: [3, 4, 5]
                ),
                .init(
                    id: 3,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(CGRect(x: 30, y: 100, width: 800, height: 400)),
                        AXName.isEditable: .boolean(true)
                    ],
                    settableAttributes: [AXName.value],
                    children: []
                ),
                .init(
                    id: 4,
                    attributes: [
                        AXName.role: .string(AXRole.staticText),
                        AXName.value: .string("20. August 2026 at 22:03"),
                        AXName.frame: .rect(CGRect(x: 30, y: 505, width: 300, height: 18))
                    ],
                    children: []
                ),
                .init(
                    id: 5,
                    attributes: [
                        AXName.role: .string(AXRole.staticText),
                        AXName.value: .string(
                            "Shopping list for the weekend, and what we still owe Priya."
                        ),
                        AXName.frame: .rect(CGRect(x: 30, y: 535, width: 600, height: 20))
                    ],
                    children: []
                )
            ]
        )
    }

    private func assemble(
        _ fixture: AXFixture,
        targetKind: TextEditTargetKind = .sentence,
        capturedText: String = "",
        roundTrips: Int = 400
    ) -> (assembly: ContextAssembly, reader: FixtureAccessibilityReader) {
        let reader = FixtureAccessibilityReader(fixture: fixture)
        let workspace = ContextWorkspace(
            reader: reader,
            budget: ContextBudget(maximumRoundTrips: roundTrips),
            target: reader.target(targetKind: targetKind, capturedText: capturedText),
            profile: .profile(forBundleIdentifier: fixture.bundleIdentifier)
        )
        return (ContextPipeline().assemble(workspace), reader)
    }

    // MARK: - Text markers

    func testMarkerPassageReadsTheConversationAboveAnElectronComposer() {
        let (assembly, _) = assemble(
            electronChatFixture(),
            capturedText: "I can write that up"
        )

        let prose = assembly.fragments
            .filter { $0.kind == .relatedPrecedingContent }
            .map(\.text)
            .joined(separator: " ")
        XCTAssertTrue(prose.contains("The staging deploy went out at four"))
        XCTAssertTrue(prose.contains("I have not written the summary yet"))
        XCTAssertTrue(assembly.telemetry.contributingSources.contains(MarkerPassageSource.sourceName))
    }

    /// The privacy boundary. Text inside the field travels with every request; text read
    /// from the interface is the author's to switch off per application. One marker read
    /// spans both, so the split has to happen before anything downstream sees it.
    func testMarkerPassageStopsAtTheEditableBoundary() {
        let (assembly, _) = assemble(
            electronChatFixture(),
            capturedText: "I can write that up"
        )

        for fragment in assembly.fragments {
            XCTAssertFalse(
                fragment.text.contains("I can write that up"),
                "the field's own text escaped into a harvested fragment"
            )
        }
    }

    /// Where the engine will not say where the field starts, the captured text is cut
    /// off the end instead — less exact, but it errs towards sending less.
    func testMarkerPassageFallsBackToTrimmingTheFieldText() {
        let (assembly, _) = assemble(
            electronChatFixture(supportsFieldBoundary: false),
            capturedText: "I can write that up"
        )

        let prose = assembly.fragments
            .filter { $0.kind == .relatedPrecedingContent }
            .map(\.text)
            .joined(separator: " ")
        XCTAssertTrue(prose.contains("I have not written the summary yet"))
        XCTAssertFalse(prose.contains("I can write that up"))
    }

    func testAnsweredNeedSkipsTheStructureAndProximitySources() {
        let (assembly, _) = assemble(
            electronChatFixture(),
            capturedText: "I can write that up"
        )

        XCTAssertEqual(assembly.telemetry.satisfiedAfterTier, .passage)
        XCTAssertTrue(assembly.telemetry.skippedSources.contains(ProximityCrawlSource.sourceName))
        XCTAssertTrue(assembly.telemetry.skippedSources.contains(TranscriptSource.sourceName))
    }

    func testTheWholeElectronReadCostsFarLessThanATraversal() {
        let (assembly, _) = assemble(
            electronChatFixture(),
            capturedText: "I can write that up"
        )

        // The traversal this replaces was allowed 240 nodes, each costing at least one
        // round trip before anything was known about it.
        XCTAssertLessThan(assembly.telemetry.roundTrips, 40)
    }

    // MARK: - Identity

    func testPageAddressTravelsWithoutItsQueryString() {
        let (assembly, _) = assemble(electronChatFixture())
        let titles = assembly.fragments.filter { $0.kind == .documentTitle }.map(\.text)

        XCTAssertTrue(titles.contains { $0.contains("app.slack.com/client/T01/C02") })
        XCTAssertFalse(titles.contains { $0.contains("thread=17") })
    }

    func testReadableAddressKeepsWhereAndDropsHow() {
        XCTAssertEqual(
            DocumentIdentitySource.readableAddress("https://github.com/a/b/pull/3?tab=files#r1"),
            "github.com/a/b/pull/3"
        )
        XCTAssertEqual(
            DocumentIdentitySource.readableAddress("https://example.com/"),
            "example.com"
        )
        // Nothing else is an address a person would recognise.
        XCTAssertNil(DocumentIdentitySource.readableAddress("file:///Users/someone/secret.txt"))
        XCTAssertNil(DocumentIdentitySource.readableAddress("not a url"))
    }

    func testEveryHarvestedFragmentSaysWhereItCameFrom() {
        let (assembly, _) = assemble(
            electronChatFixture(),
            capturedText: "I can write that up"
        )

        XCTAssertFalse(assembly.fragments.isEmpty)
        for fragment in assembly.fragments {
            XCTAssertNotNil(fragment.provenance, "\(fragment.kind) arrived without provenance")
        }
        let passage = assembly.fragments.first { $0.kind == .relatedPrecedingContent }
        XCTAssertEqual(passage?.provenance?.tier, .passage)
        XCTAssertEqual(passage?.provenance?.confidence, .stated)
    }

    // MARK: - Native

    func testANativeFieldWithoutMarkersFallsThroughToProximity() {
        // A bundle identifier with no profile of its own, so the generic path runs.
        let (assembly, _) = assemble(nativeNoteFixture(bundleIdentifier: "com.example.Jotter"))

        XCTAssertFalse(assembly.telemetry.contributingSources.contains(MarkerPassageSource.sourceName))
        XCTAssertTrue(assembly.telemetry.contributingSources.contains(ProximityCrawlSource.sourceName))
        XCTAssertTrue(assembly.fragments.contains { $0.text.contains("what we still owe Priya") })
    }

    /// The header from the screenshot. A standalone date is never what helps write a
    /// sentence, however close to the caret it happens to sit.
    func testABareTimestampNextToTheFieldIsNotContext() {
        let (assembly, _) = assemble(nativeNoteFixture(bundleIdentifier: "com.example.Jotter"))

        XCTAssertFalse(assembly.fragments.contains { $0.text.contains("22:03") })
    }

    /// The date header in the screenshot. In Notes the whole note is inside the focused
    /// field, so there is nothing outside it worth traversing for — and the traversal's
    /// only find was the timestamp it mislabelled as a field hint.
    func testTheNotesProfileDeclinesToTraverseTheInterface() {
        let (assembly, _) = assemble(nativeNoteFixture(bundleIdentifier: "com.apple.Notes"))

        XCTAssertTrue(assembly.telemetry.skippedSources.contains(ProximityCrawlSource.sourceName))
        XCTAssertFalse(assembly.fragments.contains { $0.text.contains("what we still owe Priya") })
        // The window title is stated by the application and still travels.
        XCTAssertTrue(assembly.fragments.contains { $0.text.contains("Notes") })
    }

    // MARK: - Budget

    func testAnExhaustedBudgetDegradesRatherThanFailing() {
        let (assembly, _) = assemble(
            nativeNoteFixture(bundleIdentifier: "com.example.Jotter"),
            roundTrips: 3
        )

        XCTAssertTrue(assembly.telemetry.reachedRoundTripLimit)
        XCTAssertLessThanOrEqual(assembly.telemetry.roundTrips, 3)
        // Degraded, not broken: whatever the first reads found is still usable.
        XCTAssertNotNil(assembly.fragments)
    }

    func testSourcesShareOneAllowanceRatherThanEachHavingItsOwn() {
        let reader = FixtureAccessibilityReader(fixture: electronChatFixture())
        let budget = ContextBudget(maximumRoundTrips: 400)
        let workspace = ContextWorkspace(
            reader: reader,
            budget: budget,
            target: reader.target(capturedText: "I can write that up"),
            profile: .generic
        )
        _ = ContextPipeline().assemble(workspace)

        XCTAssertEqual(budget.spentRoundTrips, workspace.telemetry.roundTrips)
        XCTAssertGreaterThan(budget.remainingRoundTrips, 0)
    }

    // MARK: - Reuse

    /// One reading of the screen, narrowed twice.
    ///
    /// A harvest is kept for a few seconds, so the request that reuses it may arrive at a
    /// field that no longer holds what it held when the screen was read — the author
    /// typed, or a suggestion was applied over it. What travels has to be decided from
    /// the field as it is now, or writing that has already been replaced comes back
    /// attributed to the interface.
    func testAHarvestIsNarrowedAgainstTheFieldAsItIsNow() {
        let note = "Shopping list for the weekend, and what we still owe Priya."
        let fixture = nativeNoteFixture(bundleIdentifier: "com.example.Jotter")
        let reader = FixtureAccessibilityReader(fixture: fixture)
        let harvest = ContextPipeline().harvest(
            ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 400),
                target: reader.target(capturedText: "Nothing to do with any of this"),
                profile: .profile(forBundleIdentifier: fixture.bundleIdentifier)
            )
        )

        let whenFirstRead = harvest.assembly(
            for: reader.target(capturedText: "Nothing to do with any of this")
        )
        XCTAssertTrue(
            whenFirstRead.fragments.contains { $0.text.contains("what we still owe Priya") }
        )

        let onceTheFieldHoldsIt = harvest.assembly(for: reader.target(capturedText: note))
        XCTAssertFalse(
            onceTheFieldHoldsIt.fragments.contains { $0.text.contains("what we still owe Priya") },
            "a reused harvest handed back writing the field itself now carries"
        )
    }

    /// Reusing a harvest costs no further reads, which is the whole point of keeping one.
    func testNarrowingAHarvestAgainSpendsNothing() {
        let fixture = nativeNoteFixture(bundleIdentifier: "com.example.Jotter")
        let reader = FixtureAccessibilityReader(fixture: fixture)
        let budget = ContextBudget(maximumRoundTrips: 400)
        let harvest = ContextPipeline().harvest(
            ContextWorkspace(
                reader: reader,
                budget: budget,
                target: reader.target(),
                profile: .profile(forBundleIdentifier: fixture.bundleIdentifier)
            )
        )
        let spentByTheHarvest = budget.spentRoundTrips

        _ = harvest.assembly(for: reader.target(capturedText: "Something else entirely"))

        XCTAssertEqual(budget.spentRoundTrips, spentByTheHarvest)
    }
}

/// Judgements about what a piece of text is, as distinct from where it sits.
final class ContextRelevanceTests: XCTestCase {
    func testRecognisesTextThatIsOnlyADateOrTime() {
        XCTAssertTrue(ContextRelevance.isBareTimestamp("20. August 2026 at 22:03"))
        XCTAssertTrue(ContextRelevance.isBareTimestamp("Yesterday 9:41"))
        XCTAssertTrue(ContextRelevance.isBareTimestamp("March 3, 2025"))
    }

    func testLeavesWritingThatMerelyMentionsADate() {
        XCTAssertFalse(
            ContextRelevance.isBareTimestamp(
                "Let us move the review to 3 March so Priya can join it."
            )
        )
        XCTAssertFalse(ContextRelevance.isBareTimestamp("The deploy went out and held."))
    }

    func testRecognisesTextWithNoWordsInIt() {
        XCTAssertTrue(ContextRelevance.isWordless("—— 42 ——"))
        XCTAssertTrue(ContextRelevance.isWordless("(3)"))
        XCTAssertFalse(ContextRelevance.isWordless("3 replies"))
    }

    func testSharedWordsEarnASmallBoostAndNothingElseEarnsAny() {
        let related = ContextRelevance.lexicalBoost(
            for: "The migration finished before the cutover window closed.",
            relatedTo: "I still need to write the migration summary."
        )
        let unrelated = ContextRelevance.lexicalBoost(
            for: "Sourdough needs a wetter starter than you think.",
            relatedTo: "I still need to write the migration summary."
        )

        XCTAssertGreaterThan(related, 0)
        XCTAssertEqual(unrelated, 0)
        // A nudge, not a ranking of its own: it must not overturn the tiers.
        XCTAssertLessThanOrEqual(related, 120)
    }

    func testShortGrammarWordsDoNotCountAsAgreement() {
        XCTAssertEqual(
            ContextRelevance.lexicalBoost(
                for: "It is on the way to be with them.",
                relatedTo: "That was the one for you and me."
            ),
            0
        )
    }
}

/// The recording loop the corpus depends on: capture, write, read back, replay.
final class AXFixtureRoundTripTests: XCTestCase {
    private func fixture() -> AXFixture {
        AXFixture(
            application: "Mail",
            bundleIdentifier: "com.apple.mail",
            scenario: "reply-with-quote",
            focusedNode: 2,
            nodes: [
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.title: .string("Re: Friday"),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 800, height: 600))
                    ],
                    children: [2, 3]
                ),
                .init(
                    id: 2,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(CGRect(x: 20, y: 40, width: 700, height: 200)),
                        AXName.isEditable: .boolean(true),
                        AXName.selectedTextMarkerRange: .marker("sel")
                    ],
                    parameterized: [
                        AXName.stringForTextMarkerRange: ["marker:r": .string("quoted thread")]
                    ],
                    parameterizedNames: [AXName.stringForTextMarkerRange],
                    settableAttributes: [AXName.value],
                    children: []
                ),
                .init(
                    id: 3,
                    attributes: [
                        AXName.role: .string(AXRole.staticText),
                        AXName.value: .string("Are you free on Friday afternoon at all?"),
                        AXName.frame: .rect(CGRect(x: 20, y: 260, width: 700, height: 20))
                    ],
                    children: []
                )
            ]
        )
    }

    private func assemble(_ fixture: AXFixture) -> ContextAssembly {
        let reader = FixtureAccessibilityReader(fixture: fixture)
        return ContextPipeline().assemble(
            ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 400),
                target: reader.target(),
                profile: .profile(forBundleIdentifier: fixture.bundleIdentifier)
            )
        )
    }

    func testAFixtureSurvivesJSONUnchanged() throws {
        let original = fixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoded = try JSONDecoder().decode(
            AXFixture.self,
            from: try encoder.encode(original)
        )

        XCTAssertEqual(decoded, original)
    }

    /// The property that makes a corpus worth keeping: a recording written to disk and
    /// read back produces the same result as the tree it was taken from.
    func testReplayingAFixtureFromDiskGivesTheSameAssembly() throws {
        let original = fixture()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(AXFixture.self, from: data)

        let before = assemble(original)
        let after = assemble(restored)

        XCTAssertEqual(before.fragments, after.fragments)
        XCTAssertEqual(before.telemetry.roundTrips, after.telemetry.roundTrips)
        XCTAssertEqual(
            before.telemetry.contributingSources,
            after.telemetry.contributingSources
        )
        XCTAssertFalse(before.fragments.isEmpty)
    }

    func testMarkerIdentitySurvivesTheRoundTrip() {
        let reader = FixtureAccessibilityReader(fixture: fixture())
        let field = reader.focusedElement

        // Two reads of the same recorded marker must answer with the same handle, or a
        // backwards walk through a document could never detect that it had stopped.
        let first = reader.attribute(AXName.selectedTextMarkerRange, of: field)?.opaqueValue
        let second = reader.attribute(AXName.selectedTextMarkerRange, of: field)?.opaqueValue

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }
}

/// Regression tests for what recorded trees turned out to look like.
final class RealWorldShapeTests: XCTestCase {
    /// A page whose composer sits deep inside nested markup, as a recording of a GitHub
    /// pull request showed it does: fifteen levels of `AXGroup` reach only the page's
    /// main landmark, with the web area and the window above that again.
    private func deeplyNestedWebFixture(depth: Int) -> AXFixture {
        var nodes: [AXFixture.Node] = []
        let markerNames = [
            AXName.stringForTextMarkerRange,
            AXName.textMarkerRangeForUIElement
        ]

        // 0 window, 1 web area, then `depth` groups, then the field.
        nodes.append(
            .init(
                id: 0,
                attributes: [
                    AXName.role: .string(AXRole.window),
                    AXName.title: .string("Pull request · owner/repo"),
                    AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_400, height: 900))
                ],
                children: [1]
            )
        )
        nodes.append(
            .init(
                id: 1,
                attributes: [
                    AXName.role: .string(AXRole.webArea),
                    AXName.url: .string("https://github.com/owner/repo/pull/13938"),
                    AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_400, height: 860))
                ],
                parameterized: [
                    AXName.textMarkerRangeForUIElement: [
                        "element:1": .marker("area-range")
                    ],
                    AXName.stringForTextMarkerRange: [
                        "marker:area-range": .string(
                            "fix up recent Valgrind errors — #13938. mitchellh commented "
                                + "24 minutes ago: the nightly job has been flagging the "
                                + "parser for a week, and every report traces back to the "
                                + "same uninitialised buffer in the token reader. This "
                                + "zeroes it at allocation and adds a suppression file "
                                + "for the two remaining false positives in libc. "
                                + "Pull request successfully merged and closed."
                        )
                    ]
                ],
                parameterizedNames: markerNames,
                children: [2]
            )
        )
        for level in 0..<depth {
            nodes.append(
                .init(
                    id: 2 + level,
                    attributes: [
                        AXName.role: .string("AXGroup"),
                        AXName.frame: .rect(CGRect(x: 10, y: 10, width: 1_000, height: 700))
                    ],
                    children: [3 + level]
                )
            )
        }
        nodes.append(
            .init(
                id: 2 + depth,
                attributes: [
                    AXName.role: .string(AXRole.textArea),
                    AXName.title: .string("Comment"),
                    AXName.frame: .rect(CGRect(x: 40, y: 40, width: 800, height: 120)),
                    AXName.isEditable: .boolean(true)
                ],
                parameterizedNames: markerNames,
                settableAttributes: [AXName.value],
                children: []
            )
        )
        return AXFixture(
            application: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            scenario: "pull-request-comment",
            focusedNode: 2 + depth,
            nodes: nodes
        )
    }

    private func assemble(_ fixture: AXFixture) -> ContextAssembly {
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

    /// The defect a real recording exposed: a ceiling of fourteen ancestors never
    /// reached the web area, so the marker path silently did nothing and the traversal
    /// was left to find the page on its own.
    func testTheWebAreaIsStillReachedThroughDeeplyNestedMarkup() {
        let assembly = assemble(deeplyNestedWebFixture(depth: 22))

        XCTAssertTrue(
            assembly.telemetry.contributingSources.contains(MarkerPassageSource.sourceName),
            "the marker path did not reach the web area through 22 levels of nesting"
        )
        XCTAssertTrue(
            assembly.fragments.contains { $0.text.contains("Valgrind") },
            "the page text above the composer never arrived"
        )
    }

    func testThePageTitleAndAddressSurviveTheSameNesting() {
        let assembly = assemble(deeplyNestedWebFixture(depth: 22))
        let titles = assembly.fragments.filter { $0.kind == .documentTitle }.map(\.text)

        XCTAssertTrue(titles.contains { $0.contains("github.com/owner/repo/pull/13938") })
        XCTAssertTrue(titles.contains { $0.contains("Pull request") })
    }

    /// Depth costs one read per level and nothing else, so reaching the page is still
    /// far cheaper than letting the traversal look for it.
    func testReachingThePageStaysCheap() {
        let assembly = assemble(deeplyNestedWebFixture(depth: 22))

        // Twenty-four levels of ancestry, the identity reads, and the marker exchange.
        XCTAssertLessThan(assembly.telemetry.roundTrips, 50)
        XCTAssertTrue(
            assembly.telemetry.skippedSources.contains(ProximityCrawlSource.sourceName)
        )
    }
}

/// Guards on the marker vocabulary, written from a recording of Chrome rather than from
/// what the engines are documented to share.
final class MarkerVocabularyTests: XCTestCase {
    /// The exact set a real Chrome web area answers, as recorded. Chromium implements
    /// the marker API broadly but not identically to WebKit, and the source may only
    /// require what is in here.
    private let chromiumVocabulary: Set<String> = [
        "AXAttributedStringForTextMarkerRange", "AXBoundsForTextMarkerRange",
        "AXEndTextMarkerForBounds", "AXIndexForTextMarker", "AXLengthForTextMarkerRange",
        "AXLineForTextMarker", "AXNextParagraphEndTextMarkerForTextMarker",
        "AXNextTextMarkerForTextMarker", "AXParagraphTextMarkerRangeForTextMarker",
        "AXPreviousParagraphStartTextMarkerForTextMarker",
        "AXPreviousTextMarkerForTextMarker", "AXStartTextMarkerForBounds",
        "AXStringForRange", "AXStringForTextMarkerRange", "AXTextMarkerForIndex",
        "AXTextMarkerForPosition", "AXTextMarkerRangeForUIElement",
        "AXTextMarkerRangeForUnorderedTextMarkers", "AXUIElementForTextMarker"
    ]

    /// The regression that cost a whole round of testing: requiring an attribute WebKit
    /// publishes and Chromium does not meant the source declined to ask Chrome anything
    /// at all, silently, on every page.
    func testChromiumDoesNotAnswerTheEndpointAccessors() {
        XCTAssertFalse(chromiumVocabulary.contains(AXName.startTextMarkerForTextMarkerRange))
        XCTAssertFalse(chromiumVocabulary.contains(AXName.endTextMarkerForTextMarkerRange))
        XCTAssertFalse(chromiumVocabulary.contains(AXName.startTextMarker))
    }

    func testWhatTheSourceRequiresIsPresentInChromium() {
        XCTAssertTrue(chromiumVocabulary.contains(AXName.stringForTextMarkerRange))
        XCTAssertTrue(chromiumVocabulary.contains(AXName.textMarkerRangeForUIElement))
        XCTAssertTrue(chromiumVocabulary.contains(AXName.lengthForTextMarkerRange))
    }

    /// A reference page can run to hundreds of thousands of characters. None of it past
    /// the first few thousand survives ranking, and reading it is paid for inside the
    /// author's own pause.
    func testAnOversizedDocumentIsDeclinedBeforeItIsRead() {
        let fixture = AXFixture(
            application: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            scenario: "very-long-article",
            focusedNode: 2,
            nodes: [
                .init(
                    id: 0,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.title: .string("A very long article"),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 800))
                    ],
                    children: [1]
                ),
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.webArea),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 760))
                    ],
                    parameterized: [
                        AXName.textMarkerRangeForUIElement: ["element:1": .marker("all")],
                        AXName.lengthForTextMarkerRange: ["marker:all": .number(900_000)],
                        AXName.stringForTextMarkerRange: [
                            "marker:all": .string(String(repeating: "x", count: 100))
                        ]
                    ],
                    parameterizedNames: [
                        AXName.textMarkerRangeForUIElement,
                        AXName.stringForTextMarkerRange,
                        AXName.lengthForTextMarkerRange
                    ],
                    children: [2]
                ),
                .init(
                    id: 2,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(CGRect(x: 40, y: 20, width: 900, height: 60)),
                        AXName.isEditable: .boolean(true)
                    ],
                    settableAttributes: [AXName.value],
                    children: []
                )
            ]
        )
        let reader = FixtureAccessibilityReader(fixture: fixture)
        let assembly = ContextPipeline().assemble(
            ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 400),
                target: reader.target(),
                profile: .generic
            )
        )

        XCTAssertFalse(
            assembly.telemetry.contributingSources.contains(MarkerPassageSource.sourceName)
        )
        // Declining is not failing: the other sources still answer.
        XCTAssertTrue(assembly.fragments.contains { $0.text.contains("A very long article") })
    }
}

final class ContextTextHygieneTests: XCTestCase {
    /// A live recording caught an application answering with its own name wrapped in
    /// control characters. Invisible in a log, invisible in the popover, and still there
    /// inside the prompt tag.
    func testControlCharactersNeverReachAFragment() {
        let fragments = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .relatedPrecedingContent,
                    text: "\u{0e} What we agreed \u{07}yesterday\u{00}",
                    relevance: 900,
                    readingOrder: 0
                )
            ],
            maximumUTF16Length: 500
        )

        XCTAssertEqual(fragments.first?.text, "What we agreed yesterday")
        for fragment in fragments {
            XCTAssertFalse(
                fragment.text.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0)
                }
            )
        }
    }
}

/// A marker read returns every word laid out in the document — the article and the
/// advertising beside it alike. Nothing about the text separates them, so the separation
/// has to come from what the page itself declares.
final class ContentBoundaryTests: XCTestCase {
    /// A page with a banner ad and a video player above the article, and a comment box
    /// inside it. The shape a real recording of an ad-supported page turned out to have.
    private func pageWithAdvertising(declaresLandmarks: Bool) -> AXFixture {
        let advertising = "0 seconds of 15 seconds Volume 0% LEARN MORE "
            + "Life in Motion HOTELS ENTDECKEN RADURLAUB IN DEN SCHÖNSTEN DESTINATIONEN"
        let article = "The council voted on Tuesday to keep the ferry running through "
            + "the winter, after two years of reduced sailings. Residents had argued the "
            + "reduced timetable cut the island off for most of the working week."

        let vocabulary = [
            AXName.textMarkerRangeForUIElement,
            AXName.stringForTextMarkerRange,
            AXName.lengthForTextMarkerRange
        ]
        return AXFixture(
            application: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            scenario: "comment-under-article",
            focusedNode: 3,
            nodes: [
                .init(
                    id: 0,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.title: .string("Island news"),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 900))
                    ],
                    children: [1]
                ),
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.webArea),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 860))
                    ],
                    parameterized: [
                        // The document holds the advertising as well as the article.
                        AXName.textMarkerRangeForUIElement: [
                            "element:1": .marker("whole-page"),
                            "element:2": .marker("article-only"),
                            "element:3": .marker("field")
                        ],
                        AXName.stringForTextMarkerRange: [
                            "marker:whole-page": .string(advertising + " " + article),
                            "marker:article-only": .string(article),
                            "marker:field": .string("")
                        ],
                        AXName.lengthForTextMarkerRange: [
                            "marker:whole-page": .number(400),
                            "marker:article-only": .number(200),
                            "marker:field": .number(0)
                        ]
                    ],
                    parameterizedNames: vocabulary,
                    children: [2]
                ),
                .init(
                    id: 2,
                    attributes: [
                        AXName.role: .string("AXGroup"),
                        AXName.subrole: .string(
                            declaresLandmarks ? "AXLandmarkMain" : "AXGroupUnspecified"
                        ),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 900, height: 700))
                    ],
                    children: [3]
                ),
                .init(
                    id: 3,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(CGRect(x: 40, y: 20, width: 800, height: 60)),
                        AXName.isEditable: .boolean(true)
                    ],
                    settableAttributes: [AXName.value],
                    children: []
                )
            ]
        )
    }

    private func prose(of fixture: AXFixture) -> String {
        let reader = FixtureAccessibilityReader(fixture: fixture)
        let assembly = ContextPipeline().assemble(
            ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 400),
                target: reader.target(),
                profile: .generic
            )
        )
        return assembly.fragments
            .filter { $0.kind == .relatedPrecedingContent }
            .map(\.text)
            .joined(separator: " ")
    }

    func testAPageThatDeclaresItsContentGetsReadWithinIt() {
        let text = prose(of: pageWithAdvertising(declaresLandmarks: true))

        XCTAssertTrue(text.contains("council voted on Tuesday"))
        XCTAssertFalse(
            text.contains("HOTELS ENTDECKEN"),
            "advertising outside the content landmark was still read"
        )
        XCTAssertFalse(text.contains("Volume 0%"))
    }

    /// A page declaring no structure gets the document, because there is nothing
    /// narrower to honour. Reading too much beats reading nothing.
    func testAPageWithNoStructureStillGetsRead() {
        let text = prose(of: pageWithAdvertising(declaresLandmarks: false))

        XCTAssertTrue(text.contains("council voted on Tuesday"))
    }

    /// The placeholders an embedded object leaves behind are not words in any language,
    /// so they are dropped wherever they come from.
    func testEmbeddedObjectPlaceholdersAreNotContext() {
        let fragments = ReadOnlyContextRanker.select(
            from: [
                .init(
                    kind: .relatedPrecedingContent,
                    text: "\u{fffc}\u{fffc}The ferry runs\u{fffc} through winter\u{fffd}",
                    relevance: 900,
                    readingOrder: 0
                )
            ],
            maximumUTF16Length: 500
        )

        XCTAssertEqual(fragments.first?.text, "The ferry runs through winter")
    }
}
