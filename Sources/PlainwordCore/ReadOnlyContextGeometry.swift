import CoreGraphics
import Foundation

/// Geometry-driven relevance model for read-only context harvested from the interface
/// surrounding an editable field.
///
/// All frames are AppKit screen coordinates: the origin sits at the bottom-left of the
/// primary display and `y` grows upward. Content *above* the focused field therefore has
/// a `minY` greater than the field's `maxY`, and content *below* it has a `maxY` less
/// than the field's `minY`.
///
/// This model is deliberately free of any Accessibility API type so that the thresholds
/// and scores below can be exercised directly.
public enum ReadOnlyContextGeometry {
    /// Content directly below a field is normally a caption, hint, or validation
    /// message, so only a narrow band is worth reading.
    public static let maximumBelowGap: CGFloat = 72

    /// Content above a field can be a whole conversation transcript or document body,
    /// which is the single most valuable source of context this model has.
    public static let maximumAboveGap: CGFloat = 900

    /// A label sitting to the side of a field is close by definition; anything further
    /// away horizontally belongs to a different column of the layout.
    public static let maximumSideLabelGap: CGFloat = 120

    public static let maximumBudgetUTF16Length = 2_500

    // MARK: - Search bounds

    /// Lateral tolerance for content considered part of the focused field's column.
    public static func horizontalMargin(around focusedFrame: CGRect) -> CGFloat {
        min(180, max(96, focusedFrame.width * 0.2))
    }

    /// The screen region worth traversing, clipped to the enclosing scroll area or
    /// window when one is known.
    public static func searchBounds(
        around focusedFrame: CGRect,
        clippedTo viewportFrame: CGRect?
    ) -> CGRect {
        let margin = horizontalMargin(around: focusedFrame)
        // A small slack below the caption band keeps elements whose reported frame is a
        // pixel or two off from being pruned before they can be scored.
        let belowExtent = maximumBelowGap + 8
        var bounds = CGRect(
            x: focusedFrame.minX - margin,
            y: focusedFrame.minY - belowExtent,
            width: focusedFrame.width + margin * 2,
            height: focusedFrame.height + belowExtent + maximumAboveGap
        )
        if let viewportFrame, viewportFrame != .zero {
            bounds = bounds.intersection(viewportFrame)
        }
        return bounds
    }

    public static func isRelevant(_ frame: CGRect, to focusedFrame: CGRect) -> Bool {
        guard frame != .zero, frame.width > 0, frame.height > 0 else { return false }
        guard horizontalGap(between: frame, and: focusedFrame)
                <= horizontalMargin(around: focusedFrame) else {
            return false
        }
        if frame.maxY <= focusedFrame.minY {
            return focusedFrame.minY - frame.maxY <= maximumBelowGap
        }
        if frame.minY >= focusedFrame.maxY {
            return frame.minY - focusedFrame.maxY <= maximumAboveGap
        }
        return true
    }

    // MARK: - Traversal priority

    /// Distance used to visit the nearest candidates first. Lower is nearer.
    ///
    /// Lateral distance counts double: text beside a field usually belongs to an
    /// adjacent control, while text directly above or below it usually belongs to the
    /// same conversation, form row, or document.
    public static func proximity(of frame: CGRect, to focusedFrame: CGRect) -> Double {
        let horizontal = Double(horizontalGap(between: frame, and: focusedFrame))
        let vertical = Double(verticalGap(between: frame, and: focusedFrame))
        return vertical + horizontal * 2
    }

    // MARK: - Reading order

    /// Reading-order values are packed as `row * columnResolution + column`, where a row
    /// is a quantized screen line. Because they are derived from position rather than
    /// from traversal order, fragments always present in the order a person reads them,
    /// no matter which part of the element tree produced them.
    private static let columnResolution = 4_096
    private static let rowHeight: CGFloat = 8
    private static let maximumRow = 65_536

    /// Ordering band for context that comes from an explicit accessibility relationship
    /// rather than from screen position. It sits below every geometric value so that a
    /// declared label always presents ahead of one inferred from layout.
    public static let metadataReadingOrder = -(maximumRow * columnResolution) - columnResolution

    public static func readingOrder(for frame: CGRect) -> Int {
        // A larger maxY is higher on screen and therefore earlier in reading order.
        let unclampedRow = Int((-frame.maxY / rowHeight).rounded(.down))
        let row = min(max(unclampedRow, -maximumRow), maximumRow)
        let unclampedColumn = Int((frame.minX / rowHeight).rounded(.down))
        let column = min(max(unclampedColumn, 0), columnResolution - 1)
        return row * columnResolution + column
    }

    // MARK: - Budget

    /// Read-only context is worth more to a short target than to a long one: a two-word
    /// fragment is meaningless without its surroundings, while a full paragraph mostly
    /// explains itself.
    public static func budgetUTF16Length(targetUTF16Length: Int) -> Int {
        let budget: Int
        switch targetUTF16Length {
        case ...120:
            budget = 2_000
        case ...400:
            budget = 1_500
        default:
            budget = 900
        }
        return min(maximumBudgetUTF16Length, budget)
    }

    // MARK: - Scoring

    /// Classifies and scores a piece of nearby text by where it sits relative to the
    /// focused field. Returns `nil` when the text is too far away, too short, or too
    /// long to be plausible context for its position.
    public static func candidate(
        text: String,
        isHeading: Bool,
        frame: CGRect,
        focusedFrame: CGRect,
        ancestorDistance: Int
    ) -> ReadOnlyContextCandidate? {
        guard isRelevant(frame, to: focusedFrame) else { return nil }

        let textLength = (text as NSString).length
        guard textLength >= 3 else { return nil }

        let horizontalOverlap = max(
            0,
            min(frame.maxX, focusedFrame.maxX) - max(frame.minX, focusedFrame.minX)
        )
        let overlapRatio = horizontalOverlap / max(1, min(frame.width, focusedFrame.width))
        let ancestorPenalty = min(160, ancestorDistance * 18)
        let order = readingOrder(for: frame)
        let verticallyAligned = frame.maxY > focusedFrame.minY
            && frame.minY < focusedFrame.maxY

        if verticallyAligned,
           frame.maxX <= focusedFrame.minX,
           focusedFrame.minX - frame.maxX <= maximumSideLabelGap,
           textLength <= 120 {
            return .init(
                kind: .fieldLabel,
                text: text,
                relevance: 820 - ancestorPenalty,
                readingOrder: order
            )
        }

        if frame.maxY <= focusedFrame.minY {
            let gap = focusedFrame.minY - frame.maxY
            guard gap <= maximumBelowGap, textLength <= 320 else { return nil }
            return .init(
                kind: .fieldDescription,
                text: text,
                relevance: 720 - ancestorPenalty - Int(gap),
                readingOrder: order
            )
        }

        if frame.minY >= focusedFrame.maxY - 4 {
            let gap = max(0, frame.minY - focusedFrame.maxY)
            var relevance = 690 - ancestorPenalty - Int(gap / 3)
            if overlapRatio >= 0.5 { relevance += 70 }
            if textLength >= 40 { relevance += 35 }
            if isHeading { relevance += 80 }
            return .init(
                kind: isHeading ? .documentTitle : .relatedPrecedingContent,
                text: text,
                relevance: relevance,
                readingOrder: order
            )
        }

        guard verticallyAligned, textLength <= 240 else { return nil }
        return .init(
            kind: textLength <= 120 ? .fieldDescription : .relatedContent,
            text: text,
            relevance: 560 - ancestorPenalty + (overlapRatio >= 0.5 ? 40 : 0),
            readingOrder: order
        )
    }

    // MARK: - Helpers

    private static func horizontalGap(between frame: CGRect, and other: CGRect) -> CGFloat {
        if frame.maxX < other.minX { return other.minX - frame.maxX }
        if frame.minX > other.maxX { return frame.minX - other.maxX }
        return 0
    }

    private static func verticalGap(between frame: CGRect, and other: CGRect) -> CGFloat {
        if frame.maxY < other.minY { return other.minY - frame.maxY }
        if frame.minY > other.maxY { return frame.minY - other.maxY }
        return 0
    }
}
