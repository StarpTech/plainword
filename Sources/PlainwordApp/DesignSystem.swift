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

enum PlainwordTheme {
    static let contentWidth: CGFloat = 620
    static let cornerRadius: CGFloat = 12
    static let cardCornerRadius: CGFloat = 16
    static let settingsRowVerticalPadding: CGFloat = 7

    static let canvas = adaptive(light: 0xF7F7F8, dark: 0x1C1C1E)
    static let sidebar = adaptive(light: 0xF0F0F2, dark: 0x212124)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x252528)
    static let raisedSurface = adaptive(light: 0xFAFAFB, dark: 0x29292D)
    static let fieldSurface = adaptive(light: 0xF3F3F5, dark: 0x202023)
    static let hoverSurface = adaptive(light: 0xEAEAED, dark: 0x303035)
    static let disabledSurface = adaptive(light: 0xE8E8EB, dark: 0x35353A)
    static let selectedSurface = adaptive(light: 0xEAE8F5, dark: 0x302D40)
    static let separator = adaptive(light: 0xE2E2E5, dark: 0x323237)
    static let strongSeparator = adaptive(light: 0xD3D3D7, dark: 0x3B3B42)

    static let textPrimary = adaptive(light: 0x242428, dark: 0xF1F1F3)
    static let textSecondary = adaptive(light: 0x6F6F76, dark: 0xA7A7AF)
    static let textTertiary = adaptive(light: 0x929299, dark: 0x7F7F87)

    static let accent = adaptive(light: 0x6256C4, dark: 0x9587F2)
    static let accentStrong = adaptive(light: 0x5045A8, dark: 0x7D70D8)
    static let accentMuted = adaptive(light: 0xECEAF8, dark: 0x312E43)
    static let ambientBlue = adaptive(light: 0x7DC8FF, dark: 0x3B72B8)
    static let ambientLavender = adaptive(light: 0xC6AEFF, dark: 0x7257C6)
    static let primaryButton = adaptive(light: 0x6256C4, dark: 0x897CF0)
    static let primaryButtonText = adaptive(light: 0xFFFFFF, dark: 0x18171E)

    static let success = adaptive(light: 0x3F7F5C, dark: 0x79B18E)
    static let warning = adaptive(light: 0xA96B0C, dark: 0xF1B252)
    static let danger = adaptive(light: 0xA64F55, dark: 0xCF777C)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
                return nsColor(value)
            }
        )
    }

    private static func nsColor(_ value: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A quiet color field gives translucent surfaces something to refract while
/// keeping content contrast predictable. It is decorative and ignores input.
struct PlainwordBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PlainwordTheme.canvas

                if !reduceTransparency {
                    Ellipse()
                        .fill(PlainwordTheme.ambientLavender.opacity(0.22))
                        .frame(width: proxy.size.width * 0.72, height: proxy.size.height * 0.62)
                        .blur(radius: 82)
                        .offset(x: proxy.size.width * 0.32, y: -proxy.size.height * 0.34)

                    Ellipse()
                        .fill(PlainwordTheme.ambientBlue.opacity(0.14))
                        .frame(width: proxy.size.width * 0.62, height: proxy.size.height * 0.54)
                        .blur(radius: 92)
                        .offset(x: -proxy.size.width * 0.35, y: proxy.size.height * 0.34)

                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.clear,
                            PlainwordTheme.accent.opacity(0.035)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PlainwordGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let shadow: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    PlainwordTheme.surface,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassOutline(cornerRadius: cornerRadius)
        } else if #available(macOS 26.0, *) {
            if interactive {
                content
                    .glassEffect(
                        .regular.tint(tint).interactive(),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .glassOutline(cornerRadius: cornerRadius)
                    .glassShadow(isVisible: shadow)
            } else {
                content
                    .glassEffect(
                        .regular.tint(tint),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
                    .glassOutline(cornerRadius: cornerRadius)
                    .glassShadow(isVisible: shadow)
            }
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .background(
                    tint?.opacity(0.16) ?? .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassOutline(cornerRadius: cornerRadius)
                .glassShadow(isVisible: shadow)
        }
    }
}

private struct PlainwordGlassOutlineModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark

        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    PlainwordTheme.separator.opacity(isDark ? 0.38 : 0.62),
                    lineWidth: 1
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.12 : 0.48),
                            .clear,
                            Color.white.opacity(isDark ? 0.03 : 0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isDark ? 0.5 : 0.7
                )
                .padding(0.5)
        }
    }
}

private extension View {
    func glassOutline(cornerRadius: CGFloat) -> some View {
        modifier(PlainwordGlassOutlineModifier(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func glassShadow(isVisible: Bool) -> some View {
        if isVisible {
            shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 8)
        } else {
            self
        }
    }
}

struct PlainwordBrandMark: View {
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: PlainwordBrand.icon(size: size))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}

@MainActor
enum PlainwordBrand {
    static func icon(size: CGFloat) -> NSImage {
        let image = (NSImage(named: "BrandIcon")?.copy() as? NSImage)
            ?? NSImage(size: NSSize(width: size, height: size))
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        return image
    }
}

struct SettingsPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .frame(maxWidth: PlainwordTheme.contentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(PlainwordTheme.textPrimary)
        .background(.clear)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PlainwordTheme.accent)
                .frame(width: 38, height: 38)
                .plainwordGlass(
                    cornerRadius: 12,
                    tint: PlainwordTheme.accent.opacity(0.16),
                    shadow: true
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PlainwordTheme.textSecondary)
            }
        }
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
        .plainwordGlass(cornerRadius: PlainwordTheme.cardCornerRadius, shadow: true)
    }
}

struct SettingsDivider: View {
    var leadingInset: CGFloat = 42

    var body: some View {
        Rectangle()
            .fill(PlainwordTheme.separator.opacity(0.7))
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
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(PlainwordTheme.textSecondary)
            .padding(.leading, 2)
    }
}

struct SettingsRow<Content: View>: View {
    let icon: String?
    let title: String
    let detail: String?
    private let content: Content

    init(
        _ title: String,
        icon: String? = nil,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PlainwordTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        PlainwordTheme.accent.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(PlainwordTheme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: 48)
        .padding(.vertical, PlainwordTheme.settingsRowVerticalPadding)
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

struct StatusPill: View {
    let title: String
    let color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
            } else {
                StatusDot(color: color)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 25)
        .plainwordGlass(cornerRadius: 8, tint: color.opacity(0.13))
    }
}

struct PlainwordButtonStyle: ButtonStyle {
    enum Emphasis {
        case primary
        case secondary
        case quiet
        case danger
    }

    @Environment(\.isEnabled) private var isEnabled
    let emphasis: Emphasis
    let large: Bool

    init(_ emphasis: Emphasis = .secondary, large: Bool = false) {
        self.emphasis = emphasis
        self.large = large
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, emphasis == .quiet ? 8 : (large ? 14 : 11))
            .frame(height: large ? 32 : 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background(configuration: configuration))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private var foreground: Color {
        guard isEnabled else { return PlainwordTheme.textTertiary }

        switch emphasis {
        case .primary: return PlainwordTheme.primaryButtonText
        case .secondary: return PlainwordTheme.textPrimary
        case .quiet: return PlainwordTheme.textSecondary
        case .danger: return PlainwordTheme.danger
        }
    }

    private func background(configuration: Configuration) -> Color {
        if !isEnabled {
            switch emphasis {
            case .primary, .secondary: return PlainwordTheme.disabledSurface
            case .quiet, .danger: return .clear
            }
        }
        return enabledBackground(configuration: configuration)
    }

    private func enabledBackground(configuration: Configuration) -> Color {
        switch emphasis {
        case .primary:
            configuration.isPressed ? PlainwordTheme.accentStrong : PlainwordTheme.primaryButton
        case .secondary:
            configuration.isPressed ? PlainwordTheme.hoverSurface : PlainwordTheme.raisedSurface
        case .quiet:
            configuration.isPressed ? PlainwordTheme.hoverSurface : .clear
        case .danger:
            configuration.isPressed ? PlainwordTheme.danger.opacity(0.16) : .clear
        }
    }

    private var border: Color {
        if !isEnabled {
            switch emphasis {
            case .primary, .secondary: return PlainwordTheme.separator
            case .quiet, .danger: return .clear
            }
        }

        switch emphasis {
        case .primary, .quiet, .danger: return .clear
        case .secondary: return PlainwordTheme.strongSeparator
        }
    }
}

private struct PlainwordFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PlainwordTheme.separator, lineWidth: 1)
            }
    }
}

extension View {
    func plainwordGlass(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false,
        shadow: Bool = false
    ) -> some View {
        modifier(
            PlainwordGlassModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                shadow: shadow
            )
        )
    }

    func plainwordField() -> some View {
        modifier(PlainwordFieldModifier())
    }
}
