import CoreGraphics
import Foundation
import XCTest
@testable import PlainwordCore

/// The properties that make a harvest predictable rather than merely usually adequate:
/// which engine was recognised, how many messages a passage cost, and whether the run
/// ended with what the request needed.
final class ContextDeterminismTests: XCTestCase {
    private let conversation = """
    Priya: The staging deploy went out at four and the error rate is flat. \
    Marcus: Nice. Did the migration finish before the cutover? \
    Priya: It did, about twenty minutes early.
    """

    // MARK: - Engine

    func testAnEngineThatTakesRangesApartIsWebKit() {
        XCTAssertEqual(
            HostEngine.classify(
                markerVocabulary: [
                    AXName.stringForTextMarkerRange,
                    AXName.startTextMarkerForTextMarkerRange
                ],
                hasDocumentElement: true
            ),
            .webKit
        )
    }

    func testAnEngineThatWillNotIsChromium() {
        XCTAssertEqual(
            HostEngine.classify(
                markerVocabulary: [AXName.stringForTextMarkerRange],
                hasDocumentElement: true
            ),
            .chromium
        )
    }

    func testAFieldWithNoDocumentAroundItIsNative() {
        XCTAssertEqual(
            HostEngine.classify(
                markerVocabulary: [AXName.stringForTextMarkerRange],
                hasDocumentElement: false
            ),
            .native
        )
        XCTAssertEqual(
            HostEngine.classify(markerVocabulary: [], hasDocumentElement: true),
            .native
        )
    }

    // MARK: - Index arithmetic

    func testChromiumIsAnchoredThroughTheFieldsRectangle() {
        let reader = FixtureAccessibilityReader(fixture: indexedFixture(engine: .chromium))
        let assembly = assemble(reader)

        XCTAssertEqual(assembly.telemetry.engine, .chromium)
        XCTAssertEqual(
            assembly.fragments.first { $0.kind == .relatedPrecedingContent }?.text,
            conversation
        )
    }

    func testWebKitIsAnchoredThroughTheCaret() {
        // The WebKit recording states no answer for `AXStartTextMarkerForBounds` at all,
        // so a passage can only appear here if the selection was what anchored it.
        let reader = FixtureAccessibilityReader(fixture: indexedFixture(engine: .webKit))
        let assembly = assemble(reader)

        XCTAssertEqual(assembly.telemetry.engine, .webKit)
        XCTAssertEqual(
            assembly.fragments.first { $0.kind == .relatedPrecedingContent }?.text,
            conversation
        )
    }

    /// The point of the whole change: a passage of a stated length, in a number of
    /// messages that does not depend on how long the document is.
    func testAPassageCostsFiveMessagesWhateverThePageHolds() {
        let reader = FixtureAccessibilityReader(fixture: indexedFixture(engine: .chromium))
        _ = assemble(reader)

        let markerReads = reader.readLog.filter { $0.hasPrefix("parameterized(AX") }
        XCTAssertEqual(markerReads.count, 5, "\(markerReads)")
        XCTAssertFalse(
            reader.readLog.contains {
                $0.contains(AXName.previousParagraphStartTextMarkerForTextMarker)
            },
            "the paragraph walk should not run when the document is addressable"
        )
    }

    func testAFieldAtTheTopOfADocumentReadsNothingAboveIt() {
        var fixture = indexedFixture(engine: .chromium)
        // Index zero: the field begins where the document does.
        fixture.nodes[1].parameterized[AXName.indexForTextMarker] = [
            "marker:field-start": .number(0)
        ]
        let assembly = assemble(FixtureAccessibilityReader(fixture: fixture))

        XCTAssertNil(assembly.fragments.first { $0.kind == .relatedPrecedingContent })
    }

    // MARK: - Choosing what to read within

    /// The rule is size, not name: outward from the field, stop at the first container
    /// holding meaningfully more writing than the field itself.
    func testTheSmallestContainerHoldingRealWritingIsRead() {
        let assembly = assemble(FixtureAccessibilityReader(fixture: nestedContainersFixture()))

        let passage = assembly.fragments
            .first { $0.kind == .relatedPrecedingContent }?.text ?? ""
        XCTAssertTrue(passage.contains("the thread being replied to"), passage)
        XCTAssertFalse(passage.contains("somebody else's mail"), "read the whole mailbox")
        XCTAssertFalse(passage.contains("Send Discard"), "read only the composer's wrapper")
    }

    /// A navigation region can hold far more text than the field — all of it link
    /// labels — and still not be somewhere to read context from.
    func testAChromeContainerIsNotReadWithin() {
        var fixture = nestedContainersFixture()
        let thread = fixture.nodes.firstIndex { $0.id == 6 }!
        fixture.nodes[thread].attributes[AXName.subrole] = .string("AXLandmarkNavigation")
        let assembly = assemble(FixtureAccessibilityReader(fixture: fixture))

        // Passed over, so the walk continued outward and read the mailbox instead.
        let passage = assembly.fragments
            .first { $0.kind == .relatedPrecedingContent }?.text ?? ""
        XCTAssertTrue(passage.contains("somebody else's mail"), passage)
    }

    /// Writing a post over a feed is not writing about the feed.
    func testADialogIsWhereTheWalkStops() {
        var fixture = nestedContainersFixture()
        // The composer's wrapper becomes a modal: a new-post dialog opened over a page.
        let composer = fixture.nodes.firstIndex { $0.id == 7 }!
        fixture.nodes[composer].attributes[AXName.subrole] = .string("AXApplicationDialog")
        let assembly = assemble(FixtureAccessibilityReader(fixture: fixture))

        let passage = assembly.fragments
            .first { $0.kind == .relatedPrecedingContent }?.text ?? ""
        XCTAssertFalse(passage.contains("thread being replied to"), passage)
        XCTAssertFalse(passage.contains("somebody else's mail"), passage)
    }

    // MARK: - The screen ladder

    func testTheLadderReadsWhatWasDrawnAboveTheCaret() {
        let assembly = assemble(FixtureAccessibilityReader(fixture: ladderFixture()))

        XCTAssertTrue(assembly.telemetry.contributingSources.contains(
            ScreenLadderSource.sourceName
        ))
        let texts = assembly.fragments.map(\.text)
        XCTAssertTrue(texts.contains { $0.hasPrefix("The migration ran ahead") })
        XCTAssertTrue(texts.contains { $0.contains("Yesterday") })
    }

    func testTheLadderDoesNotHandBackTheFieldTheAuthorIsWritingIn() {
        let assembly = assemble(FixtureAccessibilityReader(fixture: ladderFixture()))

        XCTAssertFalse(assembly.fragments.contains { $0.text.contains("half-written") })
    }

    func testAnAnsweredLadderLeavesTheTraversalUnrun() {
        let assembly = assemble(FixtureAccessibilityReader(fixture: ladderFixture()))

        XCTAssertEqual(assembly.telemetry.satisfiedAfterTier, .screen)
        XCTAssertTrue(
            assembly.telemetry.skippedSources.contains(ProximityCrawlSource.sourceName)
        )
    }

    /// Chromium answers a hit test with the group that draws the line, never with the
    /// text inside it. A ladder that only read text elements climbed a whole Gmail
    /// thread and came back with nothing.
    func testAProbeThatLandsOnAContainerStillReadsIt() {
        var fixture = ladderFixture()
        // The rung that used to find a static text now finds the row wrapping it.
        fixture.nodes.append(
            .init(
                id: 6,
                attributes: [
                    AXName.role: .string(AXRole.row),
                    AXName.frame: .rect(CGRect(x: 40, y: 88, width: 800, height: 40))
                ],
                children: [4]
            )
        )
        fixture.hitTests?["490:91"] = 6

        let assembly = assemble(FixtureAccessibilityReader(fixture: fixture))

        XCTAssertTrue(
            assembly.fragments.contains { $0.text.hasPrefix("The migration ran ahead") }
        )
    }

    /// A paragraph eight lines tall should be recognised once, not once per rung.
    func testATallParagraphIsProbedOnce() {
        let reader = FixtureAccessibilityReader(fixture: ladderFixture())
        _ = assemble(reader)

        XCTAssertLessThanOrEqual(
            reader.readLog.filter { $0 == "elementAtPosition" }.count,
            6
        )
    }

    // MARK: - Yield

    func testAHarvestRecordsWhatItNeededAndWhatItFound() {
        let telemetry = assemble(
            FixtureAccessibilityReader(fixture: ladderFixture())
        ).telemetry

        XCTAssertEqual(telemetry.requiredProseLength, 200)
        XCTAssertGreaterThanOrEqual(telemetry.harvestedProseLength, 200)
        XCTAssertFalse(telemetry.isUnderfed)
    }

    func testARunThatFoundNoProseSaysSo() {
        var fixture = ladderFixture()
        fixture.hitTests = nil
        let telemetry = assemble(FixtureAccessibilityReader(fixture: fixture)).telemetry

        XCTAssertEqual(telemetry.harvestedProseLength, 0)
        XCTAssertTrue(telemetry.isUnderfed)
    }

    // MARK: - Ordering

    func testSourcesRunInTierOrderAndOtherwiseAsGiven() {
        let pipeline = ContextPipeline(sources: [
            ProximityCrawlSource(),
            ScreenLadderSource(),
            TranscriptSource(),
            DocumentIdentitySource(),
            FieldIdentitySource()
        ])

        XCTAssertEqual(
            pipeline.sources.map(\.name),
            [
                DocumentIdentitySource.sourceName,
                FieldIdentitySource.sourceName,
                TranscriptSource.sourceName,
                ScreenLadderSource.sourceName,
                ProximityCrawlSource.sourceName
            ]
        )
    }

    // MARK: - Helpers

    private func assemble(_ reader: FixtureAccessibilityReader) -> ContextAssembly {
        ContextPipeline().assemble(
            ContextWorkspace(
                reader: reader,
                budget: ContextBudget(maximumRoundTrips: 2_000),
                target: reader.target(targetKind: .sentence),
                profile: .profile(forBundleIdentifier: reader.fixture.bundleIdentifier)
            )
        )
    }

    /// A web composer whose document can be addressed by character offset.
    ///
    /// The two engines differ only in how the field's own position is found: WebKit
    /// hands back the ends of the selected range, Chromium answers for a rectangle.
    /// Everything after that anchor is arithmetic both of them can do.
    private func indexedFixture(engine: HostEngine) -> AXFixture {
        let fieldFrame = CGRect(x: 40, y: 20, width: 900, height: 60)
        var vocabulary = [
            AXName.textMarkerRangeForUIElement,
            AXName.stringForTextMarkerRange,
            AXName.indexForTextMarker,
            AXName.textMarkerForIndex,
            AXName.textMarkerRangeForUnorderedTextMarkers
        ]
        var areaAttributes: [String: FixtureValue] = [
            AXName.role: .string(AXRole.webArea),
            AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 760))
        ]
        var parameterized: [String: [String: FixtureValue]] = [
            AXName.indexForTextMarker: ["marker:field-start": .number(conversation.utf16.count)],
            AXName.textMarkerForIndex: ["number:0": .marker("document-start")],
            AXName.textMarkerRangeForUnorderedTextMarkers: [
                "markers:document-start|field-start": .marker("above-field")
            ],
            AXName.stringForTextMarkerRange: ["marker:above-field": .string(conversation)]
        ]

        switch engine {
        case .webKit:
            vocabulary.append(AXName.startTextMarkerForTextMarkerRange)
            areaAttributes[AXName.selectedTextMarkerRange] = .marker("selection")
            parameterized[AXName.startTextMarkerForTextMarkerRange] = [
                "marker:selection": .marker("field-start")
            ]
        case .chromium, .native:
            vocabulary.append(AXName.startTextMarkerForBounds)
            parameterized[AXName.startTextMarkerForBounds] = [
                AXFixture.parameterKey(
                    for: .rect(fieldFrame),
                    markerID: { _ in nil },
                    nodeID: { _ in nil }
                )!: .marker("field-start")
            ]
        }

        return AXFixture(
            application: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            scenario: "reply-in-thread",
            focusedNode: 3,
            nodes: [
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 800))
                    ],
                    children: [2]
                ),
                .init(
                    id: 2,
                    attributes: areaAttributes,
                    parameterized: parameterized,
                    parameterizedNames: vocabulary,
                    children: [3]
                ),
                .init(
                    id: 3,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(fieldFrame),
                        AXName.isEditable: .boolean(true)
                    ],
                    settableAttributes: [AXName.value],
                    children: []
                )
            ]
        )
    }

    /// Three nested containers around one field, as a web application publishes them:
    /// the composer's own wrapper, the thread, and the whole mailbox. Only the middle
    /// one is the writing this request is about, and nothing but their sizes says so.
    private func nestedContainersFixture() -> AXFixture {
        let composerWrapper = "Send Discard"
        let thread = String(repeating: "This is the thread being replied to. ", count: 12)
        let mailbox = String(repeating: "This is somebody else's mail. ", count: 90) + thread
        let field = "my half-written reply"

        func range(_ marker: String) -> [String: FixtureValue] { ["element:0": .marker(marker)] }

        return AXFixture(
            application: "Webmail",
            bundleIdentifier: "com.example.Webmail",
            scenario: "nested",
            focusedNode: 4,
            nodes: [
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 800))
                    ],
                    children: [2]
                ),
                .init(
                    id: 2,
                    attributes: [
                        AXName.role: .string(AXRole.webArea),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 760))
                    ],
                    parameterized: [
                        // Keyed by node id: 5 is the mailbox, 6 the thread, 7 the
                        // composer's wrapper, 4 the field, 2 the page itself.
                        AXName.textMarkerRangeForUIElement: [
                            "element:2": .marker("mailbox-range"),
                            "element:5": .marker("mailbox-range"),
                            "element:6": .marker("thread-range"),
                            "element:7": .marker("composer-range"),
                            "element:4": .marker("field-range")
                        ],
                        AXName.lengthForTextMarkerRange: [
                            "marker:mailbox-range": .number(mailbox.utf16.count),
                            "marker:thread-range": .number(thread.utf16.count),
                            "marker:composer-range": .number(composerWrapper.utf16.count),
                            "marker:field-range": .number(field.utf16.count)
                        ],
                        AXName.stringForTextMarkerRange: [
                            "marker:mailbox-range": .string(mailbox + " " + field),
                            "marker:thread-range": .string(thread + " " + field),
                            "marker:composer-range": .string(composerWrapper + " " + field),
                            "marker:field-range": .string(field)
                        ]
                    ],
                    parameterizedNames: [
                        AXName.textMarkerRangeForUIElement,
                        AXName.stringForTextMarkerRange,
                        AXName.lengthForTextMarkerRange
                    ],
                    children: [5]
                ),
                // The mailbox: a list, and far too much of it.
                .init(
                    id: 5,
                    attributes: [
                        AXName.role: .string(AXRole.list),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 700))
                    ],
                    children: [6]
                ),
                // The thread: a list too, and the right one.
                .init(
                    id: 6,
                    attributes: [
                        AXName.role: .string(AXRole.list),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 1_200, height: 400))
                    ],
                    children: [7]
                ),
                // The composer's own wrapper: a form holding the field and two buttons.
                .init(
                    id: 7,
                    attributes: [
                        AXName.role: .string(AXRole.list),
                        AXName.subrole: .string("AXLandmarkForm"),
                        AXName.frame: .rect(CGRect(x: 40, y: 20, width: 900, height: 90))
                    ],
                    children: [4]
                ),
                .init(
                    id: 4,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(CGRect(x: 40, y: 20, width: 900, height: 60)),
                        AXName.isEditable: .boolean(true),
                        AXName.value: .string(field)
                    ],
                    settableAttributes: [AXName.value]
                )
            ],
            capturedText: field,
            targetKind: TextEditTargetKind.sentence.rawValue
        )
    }

    /// An interface with no document and no usable hierarchy: the field's siblings are
    /// reachable only by asking what was drawn where.
    private func ladderFixture() -> AXFixture {
        let paragraph = """
        The migration ran ahead of schedule and the cutover window closed twenty minutes \
        early, so the release notes still describe a plan nobody followed. Someone should \
        rewrite the second half before Friday, including the rollback section.
        """
        let field = CGRect(x: 40, y: 20, width: 900, height: 60)

        return AXFixture(
            application: "Studio",
            bundleIdentifier: "com.example.Studio",
            scenario: "comment-on-a-canvas",
            focusedNode: 3,
            nodes: [
                .init(
                    id: 1,
                    attributes: [
                        AXName.role: .string(AXRole.window),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 900, height: 300))
                    ],
                    children: [2]
                ),
                .init(
                    id: 2,
                    attributes: [
                        AXName.role: .string(AXRole.scrollArea),
                        AXName.frame: .rect(CGRect(x: 0, y: 0, width: 900, height: 200))
                    ],
                    // The children the traversal would need are not published here. Only
                    // the field is, which is what makes this the shape that defeats a
                    // walk and not a hit test.
                    children: [3]
                ),
                .init(
                    id: 3,
                    attributes: [
                        AXName.role: .string(AXRole.textArea),
                        AXName.frame: .rect(field),
                        AXName.isEditable: .boolean(true),
                        AXName.value: .string("a half-written reply")
                    ],
                    settableAttributes: [AXName.value]
                ),
                .init(
                    id: 4,
                    attributes: [
                        AXName.role: .string(AXRole.staticText),
                        AXName.frame: .rect(CGRect(x: 40, y: 88, width: 800, height: 40)),
                        AXName.value: .string(paragraph)
                    ]
                ),
                .init(
                    id: 5,
                    attributes: [
                        AXName.role: .string(AXRole.staticText),
                        AXName.frame: .rect(CGRect(x: 40, y: 130, width: 800, height: 40)),
                        AXName.value: .string("Yesterday at 16:02, Priya wrote:")
                    ]
                )
            ],
            hitTests: [
                // The first rung lands in the tall paragraph; the next one clears it.
                "490:91": 4,
                "490:139": 5
            ]
        )
    }
}
