import AppKit

/// Monochrome status bar rendition of the Plainword mark.
///
/// The full color app icon collapses into a smudge at status item size and reads as a
/// sticker next to the template icons macOS renders beside it, so the status item draws
/// this vector glyph instead and lets AppKit tint it for the current menu bar appearance.
/// Geometry is expressed in the coordinate space of the 1024pt brand artwork, whose y
/// axis points down.
enum PlainwordMenuBarGlyph {
    private static let pageLineWidth: CGFloat = 54
    private static let sparkleCenter = CGPoint(x: 668, y: 706)
    private static let sparkleRadius: CGFloat = 104
    /// Bounds of the stroked page plus the sparkle, in artwork units.
    private static let artworkBounds = CGRect(x: 297, y: 173, width: 475, height: 692)
    /// Share of the status item height the glyph occupies.
    private static let fillRatio: CGFloat = 0.93

    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            path(fitting: rect).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Plainword"
        return image
    }

    private static func path(fitting rect: NSRect) -> NSBezierPath {
        let glyph = NSBezierPath()
        glyph.append(strokedPage())
        glyph.append(sparkle())
        glyph.windingRule = .nonZero

        let height = rect.height * fillRatio
        let scale = height / artworkBounds.height
        let transform = NSAffineTransform()
        transform.translateX(
            by: rect.midX - artworkBounds.width * scale / 2,
            yBy: rect.midY - height / 2
        )
        transform.scaleX(by: scale, yBy: -scale)
        transform.translateX(by: -artworkBounds.minX, yBy: -artworkBounds.maxY)
        glyph.transform(using: transform as AffineTransform)
        return glyph
    }

    /// The folded page of the brand mark, drawn as an even stroke so the glyph keeps the
    /// airy weight of the system icons around it instead of turning into a solid block.
    private static func strokedPage() -> NSBezierPath {
        let page = NSBezierPath()
        page.move(to: CGPoint(x: 324, y: 275))
        page.curve(
            to: CGPoint(x: 394, y: 200),
            controlPoint1: CGPoint(x: 324, y: 234),
            controlPoint2: CGPoint(x: 353, y: 200)
        )
        page.line(to: CGPoint(x: 641, y: 200))
        page.curve(
            to: CGPoint(x: 655, y: 214),
            controlPoint1: CGPoint(x: 649, y: 200),
            controlPoint2: CGPoint(x: 655, y: 206)
        )
        page.line(to: CGPoint(x: 655, y: 372))
        page.curve(
            to: CGPoint(x: 547, y: 478),
            controlPoint1: CGPoint(x: 655, y: 440),
            controlPoint2: CGPoint(x: 610, y: 470)
        )
        page.line(to: CGPoint(x: 547, y: 565))
        page.curve(
            to: CGPoint(x: 325, y: 838),
            controlPoint1: CGPoint(x: 505, y: 610),
            controlPoint2: CGPoint(x: 345, y: 780)
        )
        page.close()

        let outline = page.cgPath.copy(
            strokingWithWidth: pageLineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return NSBezierPath(cgPath: outline)
    }

    private static func sparkle() -> NSBezierPath {
        let center = sparkleCenter
        let radius = sparkleRadius
        let waist = radius * 0.30
        let star = NSBezierPath()
        star.move(to: CGPoint(x: center.x, y: center.y - radius))
        star.curve(
            to: CGPoint(x: center.x + radius, y: center.y),
            controlPoint1: CGPoint(x: center.x + waist, y: center.y - waist),
            controlPoint2: CGPoint(x: center.x + waist, y: center.y - waist)
        )
        star.curve(
            to: CGPoint(x: center.x, y: center.y + radius),
            controlPoint1: CGPoint(x: center.x + waist, y: center.y + waist),
            controlPoint2: CGPoint(x: center.x + waist, y: center.y + waist)
        )
        star.curve(
            to: CGPoint(x: center.x - radius, y: center.y),
            controlPoint1: CGPoint(x: center.x - waist, y: center.y + waist),
            controlPoint2: CGPoint(x: center.x - waist, y: center.y + waist)
        )
        star.curve(
            to: CGPoint(x: center.x, y: center.y - radius),
            controlPoint1: CGPoint(x: center.x - waist, y: center.y - waist),
            controlPoint2: CGPoint(x: center.x - waist, y: center.y - waist)
        )
        star.close()
        return star
    }
}
