import CoreGraphics
import Foundation

/// An opaque handle to an element in whatever tree a reader is serving — a live
/// Accessibility element or a node in a captured fixture.
///
/// Handles rather than the Accessibility type itself, for two reasons. `AXUIElement` is
/// a CoreFoundation type with no `Sendable` conformance, so passing it through this
/// layer would mean `@unchecked` at every boundary; and a handle is something a
/// recorded fixture can vend just as easily as a running application, which is what
/// lets the whole pipeline be exercised without one.
public struct ElementRef: Hashable, Sendable {
    public let raw: Int

    public init(raw: Int) {
        self.raw = raw
    }
}

/// A handle to a value only the reader that produced it can interpret.
///
/// Text markers are documented as opaque and application-specific: they have no meaning
/// outside the application that made them, and no mapping to any ordinary type. They
/// exist to be handed straight back to another parameterized read, which is exactly what
/// this allows — and it means no part of the policy layer has to touch CoreFoundation.
///
/// A reader must vend equal handles for values the application considers equal. Walking
/// backwards through a document stops when a step returns the marker it started from,
/// and that check is only meaningful if identity survives the round trip.
public struct OpaqueRef: Hashable, Sendable {
    public let raw: Int

    public init(raw: Int) {
        self.raw = raw
    }
}

/// Any value the Accessibility API can answer with, in a form the policy layer can hold.
public enum ContextValue: Equatable, Sendable {
    case string(String)
    case strings([String])
    case number(Int)
    case boolean(Bool)
    case element(ElementRef)
    case elements([ElementRef])
    /// Always AppKit screen coordinates. The reader performs the flip, so nothing above
    /// it has to know which way the y axis runs.
    case rect(CGRect)
    case textRange(location: Int, length: Int)
    case opaque(OpaqueRef)
    /// Two markers handed back together, which is how a marker range is asked for.
    case opaques([OpaqueRef])

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var stringsValue: [String]? {
        if case let .strings(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var boolValue: Bool {
        if case let .boolean(value) = self { return value }
        return false
    }

    public var elementValue: ElementRef? {
        if case let .element(value) = self { return value }
        return nil
    }

    public var elementsValue: [ElementRef] {
        if case let .elements(value) = self { return value }
        return []
    }

    public var rectValue: CGRect? {
        if case let .rect(value) = self { return value }
        return nil
    }

    public var rangeValue: NSRange? {
        if case let .textRange(location, length) = self {
            return NSRange(location: location, length: length)
        }
        return nil
    }

    public var opaqueValue: OpaqueRef? {
        if case let .opaque(value) = self { return value }
        return nil
    }

    public var opaquesValue: [OpaqueRef] {
        if case let .opaques(value) = self { return value }
        return []
    }
}

/// Everything the context pipeline is allowed to ask of the outside world.
///
/// One protocol, deliberately narrow. A live reader answers from running applications; a
/// fixture reader answers from a recorded tree. Because the sources above cannot tell
/// the difference, a test can drive the real ranking and the real traversal against a
/// real application's tree without that application — or the Accessibility permission
/// needed to talk to it — being present.
///
/// Implementations are reference types holding a handle table, used from within a single
/// actor. They are not `Sendable` and are not meant to be shared.
public protocol AccessibilityReading: AnyObject {
    /// Reads several attributes at once. Batching matters: each call is a synchronous
    /// message to another process, and the count of those is what the budget bounds.
    func attributes(_ names: [String], of element: ElementRef) -> [String: ContextValue]

    func attribute(_ name: String, of element: ElementRef) -> ContextValue?

    func parameterized(
        _ name: String,
        of element: ElementRef,
        parameter: ContextValue
    ) -> ContextValue?

    /// Whether an attribute can be written. The only thing this decides here is
    /// whether a text element is somewhere the author writes — and so not context — or
    /// a read-only field showing a value, which is.
    func isSettable(_ name: String, of element: ElementRef) -> Bool

    /// Which parameterized attributes this element answers. Engines disagree — WebKit
    /// and Chromium expose different marker vocabularies — and asking for one that is
    /// absent costs a full messaging timeout, so callers probe once and remember.
    func parameterizedAttributeNames(of element: ElementRef) -> Set<String>
}

public extension AccessibilityReading {
    func string(_ name: String, of element: ElementRef) -> String? {
        attribute(name, of: element)?.stringValue
    }

    func element(_ name: String, of element: ElementRef) -> ElementRef? {
        attribute(name, of: element)?.elementValue
    }

    func elements(_ name: String, of element: ElementRef) -> [ElementRef] {
        attribute(name, of: element)?.elementsValue ?? []
    }

    func rect(_ name: String, of element: ElementRef) -> CGRect? {
        attribute(name, of: element)?.rectValue
    }
}

/// The Accessibility attribute names this pipeline uses, spelled once.
///
/// Many are not in the SDK's constants at all — the marker vocabulary is published only
/// by the browser engines that implement it — so they would otherwise be string literals
/// scattered through the sources, and a typo in one would look exactly like an
/// application that does not support the attribute.
public enum AXName {
    // Identity and structure.
    public static let role = "AXRole"
    public static let subrole = "AXSubrole"
    public static let title = "AXTitle"
    public static let description = "AXDescription"
    public static let help = "AXHelp"
    public static let value = "AXValue"
    public static let placeholder = "AXPlaceholderValue"
    public static let titleUIElement = "AXTitleUIElement"
    public static let linkedUIElements = "AXLinkedUIElements"
    public static let parent = "AXParent"
    public static let children = "AXChildren"
    public static let visibleChildren = "AXVisibleChildren"
    public static let childrenInNavigationOrder = "AXChildrenInNavigationOrder"
    public static let contents = "AXContents"
    public static let window = "AXWindow"
    public static let url = "AXURL"
    public static let document = "AXDocument"

    // Geometry and state.
    public static let position = "AXPosition"
    public static let size = "AXSize"
    /// Synthetic. Position and size are always wanted together and always wanted in
    /// AppKit coordinates, so the reader answers both as one already-flipped rectangle
    /// and the policy layer never learns which way the y axis runs.
    public static let frame = "AXFrame"
    public static let hidden = "AXHidden"
    public static let isEditable = "AXIsEditable"
    public static let containsProtectedContent = "AXContainsProtectedContent"
    public static let numberOfCharacters = "AXNumberOfCharacters"
    public static let visibleCharacterRange = "AXVisibleCharacterRange"

    // Web and Electron.
    public static let domClassList = "AXDOMClassList"
    public static let ariaLive = "AXARIALive"
    public static let editableAncestor = "AXEditableAncestor"
    public static let highestEditableAncestor = "AXHighestEditableAncestor"

    // Tables, outlines, and lists.
    public static let rows = "AXRows"
    public static let visibleRows = "AXVisibleRows"

    // Text markers. Parameterized unless noted.
    /// Plain attributes on a web area.
    public static let startTextMarker = "AXStartTextMarker"
    public static let endTextMarker = "AXEndTextMarker"
    public static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"

    public static let stringForTextMarkerRange = "AXStringForTextMarkerRange"
    public static let lengthForTextMarkerRange = "AXLengthForTextMarkerRange"
    public static let startTextMarkerForBounds = "AXStartTextMarkerForBounds"
    public static let textMarkerRangeForUIElement = "AXTextMarkerRangeForUIElement"
    public static let textMarkerRangeForUnorderedTextMarkers =
        "AXTextMarkerRangeForUnorderedTextMarkers"
    public static let startTextMarkerForTextMarkerRange = "AXStartTextMarkerForTextMarkerRange"
    public static let endTextMarkerForTextMarkerRange = "AXEndTextMarkerForTextMarkerRange"
    public static let previousParagraphStartTextMarkerForTextMarker =
        "AXPreviousParagraphStartTextMarkerForTextMarker"
    public static let nextParagraphEndTextMarkerForTextMarker =
        "AXNextParagraphEndTextMarkerForTextMarker"
}

/// Accessibility roles the pipeline reasons about.
public enum AXRole {
    public static let window = "AXWindow"
    public static let webArea = "AXWebArea"
    public static let document = "AXDocument"
    public static let scrollArea = "AXScrollArea"
    public static let staticText = "AXStaticText"
    public static let textField = "AXTextField"
    public static let textArea = "AXTextArea"
    public static let comboBox = "AXComboBox"
    public static let heading = "AXHeading"
    public static let table = "AXTable"
    public static let outline = "AXOutline"
    public static let list = "AXList"
    public static let row = "AXRow"

    public static let readableContext: Set<String> = [
        staticText, textField, textArea, heading
    ]
    public static let viewport: Set<String> = [scrollArea, webArea, document]
    public static let transcriptContainer: Set<String> = [table, outline, list]

    /// Landmark subroles a page uses to say "this part is the content".
    ///
    /// Reading the text of the nearest one of these, rather than of the whole document,
    /// is what keeps advertising, video players, cookie banners and navigation out of a
    /// marker read — by the page's own structure rather than by recognising any of them.
    /// Every one of those is real text laid out in the document, so no amount of looking
    /// at the words would separate them from the article they surround.
    public static let contentLandmarks: Set<String> = [
        "AXLandmarkMain",
        "AXDocumentArticle",
        "AXLandmarkRegion",
        "AXLandmarkForm"
    ]

    /// Landmark subroles whose content is interface chrome rather than the document.
    /// Filtering by what the page declares beats inferring it from screen position.
    public static let chromeLandmarks: Set<String> = [
        "AXLandmarkNavigation",
        "AXLandmarkBanner",
        "AXLandmarkContentInfo",
        "AXLandmarkSearch",
        "AXLandmarkComplementary"
    ]
}
