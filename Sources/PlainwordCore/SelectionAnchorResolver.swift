import Foundation
import CoreGraphics

public enum SelectionAnchorResolver {
    public static func preferred(
        start: CGRect?,
        end: CGRect?,
        pointer: CGPoint,
        maximumPointerDistance: CGFloat = 96
    ) -> CGRect? {
        guard let start else { return end }
        guard let end else { return start }

        let startDistance = hypot(pointer.x - start.midX, pointer.y - start.midY)
        let endDistance = hypot(pointer.x - end.midX, pointer.y - end.midY)
        let nearest = startDistance < endDistance ? start : end

        return min(startDistance, endDistance) <= maximumPointerDistance
            ? nearest
            : end
    }

    public static func pointerFallback(
        pointer: CGPoint,
        inside elementFrame: CGRect,
        tolerance: CGFloat = 8
    ) -> CGRect? {
        guard elementFrame.width > 0,
              elementFrame.height > 0,
              elementFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(pointer) else {
            return nil
        }
        return CGRect(x: pointer.x, y: pointer.y, width: 2, height: 18)
    }
}
