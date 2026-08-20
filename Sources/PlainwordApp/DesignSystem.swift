import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    @MainActor
    func apply() {
        guard let application = NSApp else { return }
        switch self {
        case .automatic:
            application.appearance = nil
        case .light:
            application.appearance = NSAppearance(named: .aqua)
        case .dark:
            application.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Plainword Ink: paper in the light, lamplight in the dark.
///
/// The palette is warm rather than neutral because everything the app shows is
/// writing, and it borrows an editor's vocabulary for the parts that matter: red
/// pencil for what goes, green ink for what arrives.
enum PlainwordTheme {
    static let contentWidth: CGFloat = 620

    /// One radius per kind of thing, so a control never has to guess.
    static let panelCornerRadius: CGFloat = 13
    static let cardCornerRadius: CGFloat = 11
    static let cornerRadius: CGFloat = 11
    static let controlCornerRadius: CGFloat = 8
    static let pillCornerRadius: CGFloat = 7
    static let fieldCornerRadius: CGFloat = 7
    static let smallCornerRadius: CGFloat = 6
    static let settingsRowVerticalPadding: CGFloat = 7

    static let canvas = adaptive(light: 0xEFE9DD, dark: 0x191612)
    static let surface = adaptive(light: 0xFBF8F1, dark: 0x242019)
    static let raisedSurface = adaptive(light: 0xF4EFE4, dark: 0x2B261E)
    static let fieldSurface = adaptive(light: 0xF1EBDE, dark: 0x1E1A14)
    /// The sidebar is the same raised paper as any other lifted surface.
    static let sidebar = raisedSurface
    static let hoverSurface = raisedSurface
    static let disabledSurface = fieldSurface
    static let selectionWash = adaptive(light: 0xE8E2D2, dark: 0x332D23)
    static let selectedSurface = selectionWash

    static let separator = adaptive(light: 0xE3DCCB, dark: 0x383227)
    static let strongSeparator = adaptive(light: 0xD2C9B4, dark: 0x463E30)

    static let textPrimary = adaptive(light: 0x26211A, dark: 0xEFE8DA)
    static let textSecondary = adaptive(light: 0x6F6759, dark: 0xA79D8A)
    static let textTertiary = adaptive(light: 0x9C937F, dark: 0x7E7562)

    static let accent = adaptive(light: 0x33684C, dark: 0x8CBD9B)
    static let accentStrong = adaptive(light: 0x27543D, dark: 0xA5CFB2)
    static let accentMuted = adaptive(light: 0xE3EBE0, dark: 0x2C3A2F)
    static let accentText = adaptive(light: 0xF7F4EA, dark: 0x161B15)
    static let primaryButton = accent
    static let primaryButtonText = accentText

    /// Nothing in this system is "success green" separately from the accent: a
    /// verified connection and an applied edit are the same green ink.
    static let success = accent
    static let warning = adaptive(light: 0x96690F, dark: 0xD9A84E)
    static let danger = adaptive(light: 0xA6453E, dark: 0xD08B80)
    static let dangerMuted = adaptive(light: 0xF5E3DE, dark: 0x3C2823)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }

    static func adaptiveNSColor(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(
                isDark ? dark : light,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        }
    }

    private static func nsColor(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Three voices, and every piece of text belongs to exactly one of them.
///
/// Serif is anything that is writing — titles, suggestions, prose. Sans is the
/// interface talking about itself. Mono is machinery: shortcuts, receipts, labels
/// that name a thing rather than say something.
enum PlainwordFont {
    /// The writing voice.
    static func serif(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        italic: Bool = false
    ) -> Font {
        let font = Font.system(size: size, weight: weight, design: .serif)
        return italic ? font.italic() : font
    }

    /// The interface voice.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// The machinery voice.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func serifNSFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return font
    }
}

/// One duration for everything the reader watches, so nothing in the app moves at
/// a pace of its own.
enum PlainwordMotion {
    static let duration: Double = 0.18
    static let content: Animation = .easeOut(duration: duration)
    static let appear: Animation = .easeOut(duration: 0.16)

    /// The transition every content swap uses: rise four points and fade.
    static var rise: AnyTransition { .opacity.combined(with: .offset(y: 4)) }

    @MainActor
    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

private struct PlainwordShadowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: shadowColor(opacity: 0.16, darkOpacity: 0.5), radius: 22, x: 0, y: 18)
            .shadow(color: shadowColor(opacity: 0.08, darkOpacity: 0.3), radius: 4, x: 0, y: 3)
    }

    private func shadowColor(opacity: Double, darkOpacity: Double) -> Color {
        Color(
            nsColor: PlainwordTheme.adaptiveNSColor(
                light: 0x48381C,
                dark: 0x000000,
                lightAlpha: opacity,
                darkAlpha: darkOpacity
            )
        )
    }
}

/// A sheet of paper: an opaque surface, a hairline edge, and nothing translucent.
private struct PlainwordCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color
    let border: Color
    let shadow: Bool

    func body(content: Content) -> some View {
        content
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
            .modifier(ConditionalShadow(isVisible: shadow))
    }
}

private struct ConditionalShadow: ViewModifier {
    let isVisible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVisible {
            content.modifier(PlainwordShadowModifier())
        } else {
            content
        }
    }
}

/// The brand mark: a serif lowercase "p" with a green ink full stop, on paper.
struct PlainwordBrandMark: View {
    var size: CGFloat = 40

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [PlainwordTheme.raisedSurface, PlainwordTheme.canvas]
                            : [PlainwordTheme.surface, PlainwordTheme.fieldSurface],
                        startPoint: UnitPoint(x: 0.35, y: 0),
                        endPoint: UnitPoint(x: 0.65, y: 1)
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
                        .strokeBorder(PlainwordTheme.separator, lineWidth: max(1, size / 256))
                }

            wordmark
                .font(PlainwordFont.serif(size * 0.664, weight: .medium))
                .offset(y: -size * 0.137)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var wordmark: Text {
        Text(verbatim: "p").foregroundStyle(PlainwordTheme.textPrimary)
            + Text(verbatim: ".").foregroundStyle(PlainwordTheme.accent)
    }
}

struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: PlainwordTheme.contentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(PlainwordTheme.textPrimary)
        .background(.clear)
    }
}

/// A page title in the writing voice, with its one line of explanation beside it
/// rather than beneath it, over a hairline.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(PlainwordFont.serif(26, weight: .medium))
                Text(subtitle)
                    .font(PlainwordFont.ui(12))
                    .foregroundStyle(PlainwordTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)

            Rectangle()
                .fill(PlainwordTheme.separator)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .plainwordCard(cornerRadius: PlainwordTheme.cardCornerRadius)
    }
}

/// A labelled stack of one card, which is how every section of a settings page is
/// built.
struct SettingsSection<Content: View>: View {
    let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsSectionLabel(label)
            SettingsGroup {
                content
            }
        }
    }
}

struct SettingsDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(PlainwordTheme.separator)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

struct SettingsSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(PlainwordFont.mono(10))
            .tracking(1)
            .foregroundStyle(PlainwordTheme.textTertiary)
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let detail: String?
    private let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PlainwordFont.ui(13, weight: .bold))
                if let detail {
                    Text(detail)
                        .font(PlainwordFont.ui(11))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content
        }
        .frame(minHeight: 52)
        .padding(.vertical, PlainwordTheme.settingsRowVerticalPadding)
    }
}

/// A row whose control needs the full width, so it sits under the label rather
/// than being squeezed beside it.
struct SettingsStackedRow<Content: View>: View {
    let title: String
    let detail: String?
    private let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PlainwordFont.ui(13, weight: .bold))
                if let detail {
                    Text(detail)
                        .font(PlainwordFont.ui(11))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// A state, stated: a word, a colour, and a mark that does not depend on colour.
struct StatusPill: View {
    let title: String
    let color: Color
    var systemImage: String?
    var wash: Color = PlainwordTheme.fieldSurface

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(PlainwordFont.ui(9, weight: .bold))
            } else {
                StatusDot(color: color)
            }
            Text(title)
                .font(PlainwordFont.ui(11, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            wash,
            in: RoundedRectangle(cornerRadius: PlainwordTheme.pillCornerRadius, style: .continuous)
        )
    }
}

struct PlainwordSegment<Value: Hashable>: Identifiable {
    let value: Value
    let label: String

    var id: Value { value }

    init(_ value: Value, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// Choices small enough in number to show all at once, so the current one is
/// legible without opening anything.
struct PlainwordSegmentedControl<Value: Hashable>: View {
    let segments: [PlainwordSegment<Value>]
    @Binding var selection: Value
    var accessibilityLabel: String = ""
    /// The popover has less room than a settings card, so the same control is
    /// available one size down rather than being reinvented there.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 0 : 2) {
            ForEach(segments) { segment in
                Button {
                    selection = segment.value
                } label: {
                    Text(segment.label)
                        .font(PlainwordFont.ui(compact ? 10 : 11, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(
                            selection == segment.value
                                ? PlainwordTheme.textPrimary
                                : PlainwordTheme.textTertiary
                        )
                        .padding(.horizontal, compact ? 8 : 11)
                        .frame(height: compact ? 16 : 21)
                        .background {
                            if selection == segment.value {
                                RoundedRectangle(
                                    cornerRadius: compact
                                        ? 4.5
                                        : PlainwordTheme.smallCornerRadius,
                                    style: .continuous
                                )
                                .fill(PlainwordTheme.surface)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == segment.value ? .isSelected : [])
            }
        }
        .padding(compact ? 1.5 : 2)
        .background(
            PlainwordTheme.fieldSurface,
            in: RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
                .strokeBorder(PlainwordTheme.separator, lineWidth: 1)
        }
        // A settings row's label claims `maxWidth: .infinity`, so an HStack splits the
        // width between the two and the segments come back ellipsized — "Keep m…" next
        // to "Professi…", which is the one thing a show-them-all control must not do.
        // Its width is not negotiable; the label wraps to a second line instead.
        .fixedSize(horizontal: true, vertical: false)
        .animation(PlainwordMotion.content, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var containerRadius: CGFloat {
        compact
            ? PlainwordTheme.smallCornerRadius
            : PlainwordTheme.controlCornerRadius
    }
}

/// A button label that carries its own keyboard shortcut, so a panel does not
/// need a separate hint line explaining which key triggers which button.
struct PlainwordShortcutLabel: View {
    let title: String
    let shortcut: String
    let shortcutOpacity: Double

    init(_ title: String, shortcut: String, shortcutOpacity: Double = 0.55) {
        self.title = title
        self.shortcut = shortcut
        self.shortcutOpacity = shortcutOpacity
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(shortcut)
                .font(PlainwordFont.mono(11))
                .opacity(shortcutOpacity)
                .accessibilityHidden(true)
        }
    }
}

struct PlainwordButtonStyle: ButtonStyle {
    enum Emphasis {
        case primary
        case secondary
        case quiet
        case danger
    }

    let emphasis: Emphasis
    let large: Bool

    init(_ emphasis: Emphasis = .secondary, large: Bool = false) {
        self.emphasis = emphasis
        self.large = large
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, emphasis: emphasis, large: large)
    }

    /// Hover is part of every emphasis here, and a `ButtonStyle` cannot hold state
    /// of its own, so the label is drawn by a view that can.
    private struct StyledLabel: View {
        let configuration: Configuration
        let emphasis: Emphasis
        let large: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(PlainwordFont.ui(large ? 12.5 : 12, weight: .bold))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(height: large ? 32 : 28)
                .background {
                    RoundedRectangle(
                        cornerRadius: PlainwordTheme.controlCornerRadius,
                        style: .continuous
                    )
                    .fill(background)
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PlainwordTheme.controlCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(border, lineWidth: 1)
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 && isEnabled }
                .animation(PlainwordMotion.content, value: isHovering)
                .opacity(isEnabled || emphasis != .primary ? 1 : 0.45)
        }

        private var horizontalPadding: CGFloat {
            switch emphasis {
            case .primary: large ? 14 : 12
            case .secondary: large ? 13 : 11
            case .quiet, .danger: 9
            }
        }

        private var isActive: Bool {
            isEnabled && (configuration.isPressed || isHovering)
        }

        private var foreground: Color {
            guard isEnabled else {
                return emphasis == .primary
                    ? PlainwordTheme.accentText
                    : PlainwordTheme.textTertiary
            }

            switch emphasis {
            case .primary: return PlainwordTheme.accentText
            case .secondary: return PlainwordTheme.textPrimary
            case .quiet: return isActive
                ? PlainwordTheme.textPrimary
                : PlainwordTheme.textSecondary
            case .danger: return PlainwordTheme.danger
            }
        }

        private var background: Color {
            guard isEnabled else {
                switch emphasis {
                case .primary: return PlainwordTheme.accent
                case .secondary: return PlainwordTheme.fieldSurface
                case .quiet, .danger: return .clear
                }
            }

            switch emphasis {
            case .primary:
                return isActive ? PlainwordTheme.accentStrong : PlainwordTheme.accent
            case .secondary, .quiet:
                return isActive ? PlainwordTheme.raisedSurface : .clear
            case .danger:
                return isActive ? PlainwordTheme.dangerMuted : .clear
            }
        }

        private var border: Color {
            switch emphasis {
            case .primary, .quiet, .danger:
                return .clear
            case .secondary:
                return isEnabled
                    ? PlainwordTheme.strongSeparator
                    : PlainwordTheme.separator
            }
        }
    }
}

private struct PlainwordFieldModifier: ViewModifier {
    let isFocused: Bool
    let usesMono: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(usesMono ? PlainwordFont.mono(11.5) : PlainwordFont.ui(12.5))
            .foregroundStyle(PlainwordTheme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                PlainwordTheme.fieldSurface,
                in: RoundedRectangle(
                    cornerRadius: PlainwordTheme.fieldCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PlainwordTheme.fieldCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    isFocused ? PlainwordTheme.accent : PlainwordTheme.strongSeparator,
                    lineWidth: 1
                )
            }
            .background {
                // The focus ring sits outside the field rather than inside it, so
                // nothing the author typed shifts when the field takes focus.
                if isFocused {
                    RoundedRectangle(
                        cornerRadius: PlainwordTheme.fieldCornerRadius + 3,
                        style: .continuous
                    )
                    .fill(PlainwordTheme.accentMuted)
                    .padding(-3)
                }
            }
            .animation(PlainwordMotion.content, value: isFocused)
    }
}

extension View {
    func plainwordCard(
        cornerRadius: CGFloat,
        fill: Color = PlainwordTheme.surface,
        border: Color = PlainwordTheme.separator,
        shadow: Bool = false
    ) -> some View {
        modifier(
            PlainwordCardModifier(
                cornerRadius: cornerRadius,
                fill: fill,
                border: border,
                shadow: shadow
            )
        )
    }

    func plainwordField(isFocused: Bool = false, usesMono: Bool = false) -> some View {
        modifier(PlainwordFieldModifier(isFocused: isFocused, usesMono: usesMono))
    }
}
