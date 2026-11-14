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
        #expect(CalColor.yellow.textIsBlack(dark: false))
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
