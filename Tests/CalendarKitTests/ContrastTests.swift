import Foundation
import Testing
@testable import CalendarKit

@Suite("Contrast")
struct ContrastTests {
    /// Text on any palette color, either scheme, clears WCAG AA for normal text.
    @Test(arguments: CalColor.allCases, [false, true])
    func textOnEveryColorReads(color: CalColor, dark: Bool) {
        #expect(color.textContrast(dark: dark) >= 4.5, "\(color) dark=\(dark): \(color.textContrast(dark: dark))")
    }

    /// The bright dark-mode colors take black (white on them was ~1.5:1).
    @Test func brightColorsTakeBlack() {
        for c: CalColor in [.yellow, .mint, .cyan, .sky] {
            #expect(c.textIsBlack(dark: true), "\(c)")
        }
        #expect(!CalColor.yellow.textIsBlack(dark: false)) // the deep light amber takes white
    }

    /// Deep colors keep white.
    @Test func deepColorsKeepWhite() {
        for c: CalColor in [.blue, .indigo, .purple, .red] {
            #expect(!c.textIsBlack(dark: false), "\(c)")
        }
    }

    /// The luminance matches WCAG's reference points.
    @Test func luminanceEnds() {
        #expect(abs(CalColor.blue.luminance(dark: false) - 0.0957) < 0.001) // rgb(3, 85, 174), worked out separately
    }
}

@Suite("Accent as text")
struct AccentTextTests {
    /// The cards over a yellow backdrop, measured from Lab screenshots: the
    /// warmest light card pixel and a typical dark one (conservative cases).
    static let lightCard = (255, 248, 217)
    static let darkCard = (75, 67, 32)

    static func linear(_ v: Int) -> Double {
        let s = Double(v) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ c: (Int, Int, Int)) -> Double {
        0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }

    /// CIELAB (D65), for the distance between two palette colors.
    static func lab(_ c: (Int, Int, Int)) -> (Double, Double, Double) {
        let r = linear(c.0), g = linear(c.1), b = linear(c.2)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// Every accent as text ("Today", the chevrons, today's number) clears
    /// 4.5:1 on its scheme's card.
    @Test(arguments: CalColor.allCases, [false, true])
    func accentReadsAsText(color: CalColor, dark: Bool) {
        let card = Self.luminance(dark ? Self.darkCard : Self.lightCard)
        let c = color.luminance(dark: dark)
        let ratio = (max(card, c) + 0.05) / (min(card, c) + 0.05)
        #expect(ratio >= 4.5, "\(color) dark=\(dark): \(ratio)")
    }

    /// No two colors look alike: two people picking neighbouring colors can
    /// still tell their calendars apart (CIE76 distance at least 22).
    @Test(arguments: [false, true])
    func colorsStayApart(dark: Bool) {
        let colors = CalColor.allCases.filter { $0 != .none } // .none draws as indigo
        for (i, a) in colors.enumerated() {
            for b in colors[(i + 1)...] {
                let p = Self.lab(a.components(dark: dark)), q = Self.lab(b.components(dark: dark))
                let d = ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
                #expect(d >= 22, "\(a)–\(b) dark=\(dark): \(d)")
            }
        }
    }
}
