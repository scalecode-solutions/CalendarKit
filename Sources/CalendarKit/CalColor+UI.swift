import SwiftUI

public extension CalColor {
    /// The color for this scheme: a little deeper in light (contrast on white),
    /// a little brighter in dark. `.none` draws as the kit's default, indigo,
    /// everywhere (events, dots, the backdrop, the accent).
    func color(dark: Bool) -> Color {
        let (l, d) = rgb
        let c = dark ? d : l
        return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
    }

    /// Black or white, whichever reads better on this color in this scheme
    /// (WCAG contrast). Use it for any text or glyph drawn on a palette color:
    /// white on the bright dark-mode colors (yellow, mint, cyan, sky) is ~1.5:1.
    func onColor(dark: Bool) -> Color { textIsBlack(dark: dark) ? .black : .white }

    /// Whether black text beats white on this color.
    func textIsBlack(dark: Bool) -> Bool {
        let l = luminance(dark: dark)
        return (l + 0.05) / 0.05 > 1.05 / (l + 0.05)
    }

    /// The contrast ratio of `onColor` on this color. Never below ~4.58:1, since
    /// one of black and white always clears that on any color.
    func textContrast(dark: Bool) -> Double {
        let l = luminance(dark: dark)
        return max((l + 0.05) / 0.05, 1.05 / (l + 0.05))
    }

    /// WCAG 2 relative luminance of this scheme's color.
    func luminance(dark: Bool) -> Double {
        let (l, d) = rgb
        let c = dark ? d : l
        func lin(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    /// Display name for pickers.
    var title: String { self == .none ? "Default" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    private var rgb: (light: (Int, Int, Int), dark: (Int, Int, Int)) {
        switch self {
        case .red:    ((215, 50, 50), (255, 105, 100))
        case .orange: ((225, 110, 0), (255, 160, 70))
        case .yellow: ((195, 150, 0), (250, 210, 60))
        case .green:  ((40, 150, 60), (95, 210, 110))
        case .mint:   ((0, 160, 120), (90, 220, 180))
        case .teal:   ((0, 140, 140), (50, 200, 190))
        case .cyan:   ((0, 160, 200), (60, 210, 245))
        case .sky:    ((40, 140, 230), (100, 190, 255))
        case .blue: ((30, 90, 220), (90, 140, 255))
        case .none, .indigo: ((80, 70, 200), (130, 120, 255))
        case .purple: ((140, 60, 200), (190, 120, 245))
        case .pink:   ((215, 60, 140), (255, 120, 185))
        case .brown:  ((140, 95, 60), (200, 150, 110))
        case .gray:   ((110, 115, 125), (165, 170, 180))
        }
    }
}

/// A palette color as a ShapeStyle that follows light/dark.
public struct CalTint: ShapeStyle {
    public let color: CalColor
    public init(_ color: CalColor) { self.color = color }
    public func resolve(in environment: EnvironmentValues) -> Color {
        color.color(dark: environment.colorScheme == .dark)
    }
}

/// Black or white for text drawn on a palette color, following light/dark.
public struct CalOnTint: ShapeStyle {
    public let color: CalColor
    public init(_ color: CalColor) { self.color = color }
    public func resolve(in environment: EnvironmentValues) -> Color {
        color.onColor(dark: environment.colorScheme == .dark)
    }
}

extension EnvironmentValues {
    /// The palette color behind `.tint`, so text drawn on the tint can pick
    /// black or white (`CalOnTint(accent)`).
    @Entry var calendarAccent: CalColor = .indigo
}

private struct CalendarAccent: ViewModifier {
    let color: CalColor
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .tint(color.color(dark: scheme == .dark))
            .environment(\.calendarAccent, color)
    }
}

extension View {
    /// Tints with a palette color and tells views below which one it is.
    func calendarAccent(_ color: CalColor) -> some View { modifier(CalendarAccent(color: color)) }
}

/// The kit's wording, chosen by the host. Neutral defaults (CalendarLab); a
/// host passes its own.
public struct CalendarAppearance: Sendable {
    public var emptyDay: String
    public var emptyAgenda: String
    public var newEvent: String

    public init(emptyDay: String = "Nothing planned", emptyAgenda: String = "Nothing coming up",
                newEvent: String = "New Event") {
        self.emptyDay = emptyDay
        self.emptyAgenda = emptyAgenda
        self.newEvent = newEvent
    }

    public static let standard = CalendarAppearance()
}

/// A person's round avatar: their thumbnail, else initials on their color.
struct CalAvatar: View {
    let contact: CalContact?
    let fallbackName: String
    let tint: CalColor
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let data = contact?.avatar, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(CalOnTint(tint))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CalTint(tint))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        if contact == nil && fallbackName == "My calendar" { return "Me" }
        let words = (contact?.name ?? fallbackName).split(separator: " ")
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}
