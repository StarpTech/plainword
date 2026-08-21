import Foundation

/// Which kind of text host the focused field belongs to.
///
/// The pipeline used to run every source against every application and find out what
/// worked by watching which of them came back with something. That is the wrong shape
/// for a budget: a source that cannot possibly answer here still charges for finding
/// that out, and the one that could is left with less.
///
/// Naming the engine first makes the path a decision instead of a search. It is settled
/// from what the application answers rather than from a table of bundle identifiers,
/// because the marker vocabulary is the engine's own statement about itself and cannot
/// go stale the way a list of applications does.
public enum HostEngine: String, Equatable, Sendable {
    /// AppKit, SwiftUI, or anything else whose field carries its own text.
    case native
    /// WebKit content: Safari, and every application drawing its editor in a `WKWebView`
    /// — which includes some that look entirely native, Mail's composer among them.
    case webKit
    /// Chromium content: the Chrome-family browsers and every Electron application.
    case chromium

    /// Which engine published the document the focused field sits in.
    ///
    /// The two web engines are told apart by endpoint extraction. WebKit will take a
    /// range apart and hand back the markers at its ends; Chromium publishes no such
    /// accessor, and a strategy that assumes one silently reads nothing there. That
    /// single difference decides how a passage has to be anchored, so it is the thing
    /// worth branching on.
    public static func classify(
        markerVocabulary: Set<String>,
        hasDocumentElement: Bool
    ) -> HostEngine {
        guard hasDocumentElement,
              markerVocabulary.contains(AXName.stringForTextMarkerRange) else {
            return .native
        }
        if markerVocabulary.contains(AXName.startTextMarkerForTextMarkerRange) {
            return .webKit
        }
        return .chromium
    }

    /// Whether index arithmetic is available, which is what allows a passage of a stated
    /// length to be taken in a fixed number of reads.
    public static func supportsIndexArithmetic(_ markerVocabulary: Set<String>) -> Bool {
        markerVocabulary.contains(AXName.indexForTextMarker)
            && markerVocabulary.contains(AXName.textMarkerForIndex)
            && markerVocabulary.contains(AXName.textMarkerRangeForUnorderedTextMarkers)
    }
}
