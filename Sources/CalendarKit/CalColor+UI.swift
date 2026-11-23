import SwiftUI

public extension CalColor {
    /// The color for this scheme. Each variant reads as text on its scheme's
    /// card (at least 4.5:1) and stays apart from every other color (CIE76
    /// distance at least 22), picked in CIELCh by hue; see AccentTextTests. `.none` draws as the kit's default, indigo,
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

    /// The contrast ratio of the text `onColor` actually picks on this color.
    /// The better of black and white always clears ~4.58:1 on any color.
    func textContrast(dark: Bool) -> Double {
        let l = luminance(dark: dark)
        return textIsBlack(dark: dark) ? (l + 0.05) / 0.05 : 1.05 / (l + 0.05)
    }

    /// The sRGB components for this scheme, 0...255.
    func components(dark: Bool) -> (Int, Int, Int) { dark ? rgb.dark : rgb.light }

    /// WCAG 2 relative luminance of this scheme's color.
    func luminance(dark: Bool) -> Double {
        let c = components(dark: dark)
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
        case .red:    ((226, 2, 46), (255, 146, 137))
        case .orange: ((188, 80, 0), (255, 167, 109))
        case .yellow: ((145, 106, 2), (255, 213, 102))
        case .green:  ((62, 128, 1), (130, 220, 73))
        case .mint:   ((0, 130, 70), (8, 232, 158))
        case .teal:   ((4, 126, 110), (4, 198, 178))
        case .cyan:   ((5, 124, 146), (13, 224, 248))
        case .sky:    ((2, 99, 153), (25, 196, 254))
        case .blue:   ((3, 85, 174), (158, 194, 254))
        case .none, .indigo: ((1, 45, 204), (175, 166, 255))
        case .purple: ((164, 2, 209), (224, 146, 255))
        case .pink:   ((217, 1, 133), (255, 140, 186))
        case .brown:  ((119, 77, 56), (215, 170, 138))
        case .gray:   ((115, 112, 108), (185, 182, 175))
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

/// A person's round avatar: the host's photo when it draws one, else their
/// thumbnail from the directory, else initials on their color.
struct CalAvatar: View {
    let contact: CalContact?
    let fallbackName: String
    let tint: CalColor
    var size: CGFloat = 22
    /// Who it is, when `contact` is nil (someone the directory doesn't know):
    /// the host may still know them.
    var personID: UUID? = nil
    @Environment(\.calendarHostPeople) private var host

    private var id: UUID? { personID ?? contact?.id }

    var body: some View {
        Group {
            if let id, let hosted = host.avatar(id, size) {
                hosted.scaledToFill()
            } else if let data = contact?.avatar, let img = UIImage(data: data) {
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
        let words = (id.flatMap { host.hostName($0) } ?? contact?.name ?? fallbackName).split(separator: " ")
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}
