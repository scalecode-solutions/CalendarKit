import SwiftUI

/// CalendarKit's look: "Together". The family's living mesh backdrop (as
/// GarageKit's and LushKit's: neutral edges that follow the host's color scheme,
/// near-black in dark and near-white in light, an opaque base, 12 fps, static
/// under Reduce Motion), tinted by the calendars on screen: each one's color
/// glows from its own side and they meet in the middle. Calmer than the others:
/// it drifts slowly.
public struct CalendarBackdrop: View {
    /// The visible calendars' colors, own first. Empty = a quiet neutral.
    var colors: [CalColor]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(colors: [CalColor]) { self.colors = colors }

    private var dark: Bool { colorScheme == .dark }
    private var edge: Color { dark ? .black : Color(white: 0.97) }
    private var rim: Color { dark ? Color(white: 0.06) : Color(white: 0.93) }
    private var base: Color { dark ? .black : .white }

    public var body: some View {
        let tints = colors.isEmpty ? [CalColor.none] : colors
        let a = tints[0].color(dark: dark)
        let b = tints[min(1, tints.count - 1)].color(dark: dark)
        let c = tints.count > 2 ? tints[2].color(dark: dark) : a.mix(with: b, by: 0.5)
        let strong = dark ? 0.34 : 0.24
        let soft = dark ? 0.18 : 0.12
        TimelineView(.animation(minimumInterval: 1 / 12, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : Float(ctx.date.timeIntervalSinceReferenceDate) * 0.6
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + 0.10 * sin(t * 0.21), 0], [1, 0],
                    [0, 0.42 + 0.10 * sin(t * 0.33)],
                    [0.5 + 0.16 * sin(t * 0.19), 0.5 + 0.12 * cos(t * 0.27)],
                    [1, 0.58 + 0.10 * cos(t * 0.29)],
                    [0, 1], [0.5 + 0.10 * cos(t * 0.23), 1], [1, 1],
                ],
                colors: [
                    edge, rim.mix(with: a, by: 0.15), edge,
                    a.opacity(strong), c.opacity(soft), b.opacity(strong),
                    edge, rim.mix(with: b, by: 0.12), edge,
                ]
            )
        }
        // The tinted stops are translucent: an opaque base keeps the host from
        // bleeding through.
        .background(base)
        .animation(.smooth(duration: 0.8), value: colors)
        .ignoresSafeArea()
    }
}

extension View {
    /// The kit's backdrop behind a list or form (its own background hidden).
    func calendarBackdrop(_ engine: CalendarEngine) -> some View {
        scrollContentBackground(.hidden)
            .background { CalendarBackdrop(colors: engine.backdropColors) }
    }

    /// A glass card, the kit's surface for content over the backdrop.
    func calendarCard(cornerRadius: CGFloat = 24, tint: Color? = nil) -> some View {
        glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
    }
}

extension CalendarEngine {
    /// The colors the backdrop glows with: the shown calendars', own first.
    public var backdropColors: [CalColor] {
        var out: [CalColor] = []
        for c in calendars where c.visible {
            let col = c.displayColor == .none ? CalColor.indigo : c.displayColor
            if !out.contains(col) { out.append(col) }
        }
        return Array(out.prefix(3))
    }

    /// The kit's accent: the person's own calendar color.
    public var accentColor: CalColor {
        guard let own = ownCalendar else { return .indigo }
        return own.displayColor == .none ? .indigo : own.displayColor
    }
}
