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
        #expect(abs(CalColor.blue.luminance(dark: false) - 0.1275) < 0.002) // rgb(30, 90, 220), worked by hand
    }
}

@Suite("Accent as text")
struct AccentTextTests {
    /// The light card over a yellow backdrop, measured from a Lab screenshot:
    /// the warmest (darkest) card pixel, so the conservative case.
    static let warmCard = (255, 248, 217)

    static func luminance(_ c: (Int, Int, Int)) -> Double {
        func lin(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    /// Every accent as text in light mode ("Today", the chevrons, today's
    /// number) clears 4.5:1 on the card.
    @Test(arguments: CalColor.allCases)
    func lightAccentReadsAsText(color: CalColor) {
        let card = Self.luminance(Self.warmCard)
        let ratio = (card + 0.05) / (color.luminance(dark: false) + 0.05)
        #expect(ratio >= 4.5, "\(ratio)")
    }
}
