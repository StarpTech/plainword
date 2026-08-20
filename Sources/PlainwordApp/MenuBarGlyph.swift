import AppKit

/// The status bar rendition of the Plainword mark: a lowercase serif "p" with the
/// green ink full stop.
///
/// The full colour app icon collapses into a smudge at status item size and reads as
/// a sticker next to the glyphs macOS renders beside it, so the status item draws the
/// wordmark instead. The letter takes the menu bar's own label colour so it sits with
/// its neighbours; only the full stop carries colour, because only the full stop
/// carries state.
enum PlainwordMenuBarGlyph {
    enum Activity: Equatable {
        /// Ready, and nothing in flight.
        case idle
        /// A request is with the provider.
        case working
        /// Suggestions are switched off, or ignored in the active application.
        case paused
    }

    /// Share of the status item height the wordmark's point size occupies.
    private static let fillRatio: CGFloat = 0.83

    static func image(
        size: CGFloat = 18,
        activity: Activity = .idle,
        stopOpacity: CGFloat = 1
    ) -> NSImage {
        let pointSize = size * fillRatio
        let measured = measure(pointSize: pointSize, includesStop: activity != .paused)
        let imageSize = NSSize(width: ceil(measured.width) + 2, height: size)

        let image = NSImage(size: imageSize, flipped: false) { rect in
            // Built here rather than captured, so the dynamic colours below resolve
            // against the menu bar's appearance every time the glyph is drawn.
            let string = attributedGlyph(
                pointSize: pointSize,
                activity: activity,
                stopOpacity: stopOpacity
            )
            string.draw(
                at: NSPoint(x: 1, y: (rect.height - measured.height) / 2 + measured.descender)
            )
            return true
        }
        // The full stop is the state, and a template image would throw its colour
        // away along with the distinction it carries.
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription(for: activity)
        return image
    }

    /// The same wordmark for a menu item, where it always reads as the app rather
    /// than as a state.
    static func menuItemImage(size: CGFloat = 16) -> NSImage {
        image(size: size, activity: .idle)
    }

    private static func attributedGlyph(
        pointSize: CGFloat,
        activity: Activity,
        stopOpacity: CGFloat
    ) -> NSAttributedString {
        let font = PlainwordFont.serifNSFont(pointSize, weight: .medium)
        let letterColor: NSColor = activity == .paused
            ? .tertiaryLabelColor
            : .labelColor
        let glyph = NSMutableAttributedString(
            string: "p",
            attributes: [.font: font, .foregroundColor: letterColor]
        )

        // Paused removes the stop entirely: the sentence is not finished because
        // nothing is being written.
        guard activity != .paused else { return glyph }

        let stopColor = activity == .working
            ? PlainwordTheme.adaptiveNSColor(light: 0x96690F, dark: 0xD9A84E)
            : PlainwordTheme.adaptiveNSColor(light: 0x33684C, dark: 0x8CBD9B)
        glyph.append(
            NSAttributedString(
                string: ".",
                attributes: [
                    .font: font,
                    .foregroundColor: stopColor.withAlphaComponent(stopOpacity)
                ]
            )
        )
        return glyph
    }

    private struct GlyphMetrics {
        let width: CGFloat
        let height: CGFloat
        let descender: CGFloat
    }

    private static func measure(pointSize: CGFloat, includesStop: Bool) -> GlyphMetrics {
        let font = PlainwordFont.serifNSFont(pointSize, weight: .medium)
        let text = includesStop ? "p." : "p"
        let size = NSString(string: text).size(withAttributes: [.font: font])
        return GlyphMetrics(
            width: size.width,
            height: size.height,
            // The descender of the "p" would otherwise pull the whole wordmark low
            // against the menu bar's other glyphs.
            descender: -font.descender / 2
        )
    }

    private static func accessibilityDescription(for activity: Activity) -> String {
        switch activity {
        case .idle: "Plainword"
        case .working: "Plainword, working"
        case .paused: "Plainword, suggestions paused"
        }
    }
}
