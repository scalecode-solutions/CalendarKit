import Foundation
import Testing
@testable import CalendarKit

/// A pair nobody chose a color for gets one of its own, apart from the
/// person's own and the other pairs'.
@Suite("Automatic calendar colors")
struct AutoColorTests {
    /// A pair with someone; `pref` is the person's own choice for it.
    private func cal(other: UUID = UUID(), pref: CalColor = .none) -> CalCalendar {
        CalCalendar(id: UUID(), otherID: other, prefColor: pref)
    }

    /// Nobody chose a color: the pair gets one, never the default accent.
    @Test func anUncoloredPairIsNotTheDefault() {
        let out = CalCalendar.assignAutoColors([cal()])
        #expect(out[0].autoColor != nil)
        #expect(out[0].displayColor != .none && out[0].displayColor != .indigo)
    }

    /// The same person gets the same color on every launch, whatever the order.
    @Test func theSamePersonGetsTheSameColor() {
        let other = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!
        let a = CalCalendar.assignAutoColors([cal(other: other)])[0].displayColor
        for _ in 0..<20 {
            let pairs = (0..<3).map { _ in cal() } + [cal(other: other)]
            let out = CalCalendar.assignAutoColors(pairs.shuffled())
            let mine = out.first { $0.otherID == other }!.displayColor
            let again = CalCalendar.assignAutoColors(out.shuffled()).first { $0.otherID == other }!.displayColor
            #expect(mine == again)
        }
        // Alone, it gets its own slot, walking on past indigo (the default
        // accent) and blue and purple (beside it).
        let start = CalCalendar.stableIndex(other, 12)
        let expected = (0..<12).map { CalCalendar.autoPalette[(start + $0) % 12] }.first { ![.indigo, .blue, .purple].contains($0) }
        #expect(a == expected)
        // FNV-1a over the bytes is fixed: pin this id's slot, so a change of
        // hash (which would recolor everyone's friends) shows up here.
        #expect(start == 6)
    }

    /// Not the colors beside one's own while others are free.
    @Test func notBesideTheOwnColorWhileOthersAreFree() {
        for own in CalColor.allCases {
            let mine = own == .none ? CalColor.indigo : own
            let near = CalCalendar.neighbours(of: mine)
            for _ in 0..<20 {
                let out = CalCalendar.assignAutoColors((0..<3).map { _ in cal() }, own: own)
                #expect(!out.contains { near.contains($0.displayColor) }, "own \(own)")
            }
        }
        #expect(CalCalendar.neighbours(of: .indigo) == [.blue, .purple])
        #expect(CalCalendar.neighbours(of: .red) == [.pink, .orange])
        #expect(CalCalendar.neighbours(of: .gray).isEmpty)
    }

    /// Never the person's own color, whichever they picked (or the default).
    @Test func neverTheOwnColor() {
        for own in CalColor.allCases {
            let out = CalCalendar.assignAutoColors((0..<11).map { _ in cal() }, own: own)
            let mine = own == .none ? CalColor.indigo : own
            #expect(!out.contains { $0.displayColor == mine }, "own \(own)")
        }
    }

    /// Pairs never share a color while there are colors left (11 beside one's own).
    @Test func pairsAreAllDifferent() {
        for _ in 0..<50 {
            let colors = CalCalendar.assignAutoColors((0..<11).map { _ in cal() }).map(\.displayColor)
            #expect(Set(colors).count == 11)
            #expect(!colors.contains(.gray) && !colors.contains(.brown) && !colors.contains(.none))
        }
        // Past that they repeat rather than go blank.
        let many = CalCalendar.assignAutoColors((0..<15).map { _ in cal() })
        #expect(!many.contains { $0.displayColor == .none })
    }

    /// A chosen color wins, and is taken from the automatic ones.
    @Test func chosenColorsWinAndAreAvoided() {
        let out = CalCalendar.assignAutoColors([cal(pref: .teal), cal()])
        #expect(out[0].autoColor == nil && out[0].displayColor == .teal)
        #expect(![CalColor.teal, .indigo].contains(out[1].displayColor))
    }

    /// Adding friends one at a time never recolors one already there (the
    /// review measured 7% to 39% moving without memory, from 1 to 5 friends).
    @Test func addingAFriendNeverMovesAnother() {
        // Past 11 the palette is full and colors repeat; still nobody moves.
        for own in [CalColor.none, .orange, .gray] {
            for _ in 0..<300 {
                var cals: [CalCalendar] = []
                for k in 1...14 {
                    let before = Dictionary(uniqueKeysWithValues: cals.map { ($0.id, $0.displayColor) })
                    cals = CalCalendar.assignAutoColors((cals + [cal()]).shuffled(), own: own)
                    for c in cals where before[c.id] != nil { #expect(c.displayColor == before[c.id]) }
                    // Assigning again changes nothing (else every sync would write and rebuild).
                    #expect(Self.colors(CalCalendar.assignAutoColors(cals.shuffled(), own: own)) == Self.colors(cals))
                    if k == 11 && own != .gray { #expect(Set(cals.map(\.displayColor)).count == 11) }
                }
            }
        }
    }

    private static func colors(_ cals: [CalCalendar]) -> [UUID: CalColor] {
        Dictionary(uniqueKeysWithValues: cals.map { ($0.id, $0.displayColor) })
    }

    /// A remembered color gives way when it's chosen for something else, or
    /// when the person's own color moves next to it; otherwise it stays.
    @Test func aRememberedColorStaysUntilItIsTaken() {
        var a = cal(); a.autoColor = .green
        var out = CalCalendar.assignAutoColors([a])
        #expect(out[0].displayColor == .green)
        // The person picks green for another pair: the remembered one moves.
        out = CalCalendar.assignAutoColors([a, cal(pref: .green)])
        #expect(out[0].displayColor != .green)
        // The person makes their own color mint (green's neighbour): it moves too.
        out = CalCalendar.assignAutoColors([a], own: .mint)
        #expect(![.mint, .green, .teal].contains(out[0].displayColor))
        // A pair the person colors forgets the automatic one.
        var b = cal(pref: .red); b.autoColor = .orange
        #expect(CalCalendar.assignAutoColors([b])[0].autoColor == nil)
    }

    /// The person's own choice beats the automatic one.
    @Test func displayColorOrder() {
        var c = cal()
        c.autoColor = .green
        #expect(c.displayColor == .green)
        c.prefColor = .pink
        #expect(c.displayColor == .pink)
    }
}

@MainActor
@Suite("Automatic calendar colors, engine")
struct AutoColorEngineTests {
    /// The server's list (which has no automatic color) doesn't wipe the one
    /// this device remembers, and the rest of the pair still updates.
    @Test func theStoreKeepsItThroughTheServersList() throws {
        let store = try CalendarStore(userID: UUID(), appGroup: nil, inMemory: true)
        var c = CalCalendar(id: UUID(), otherID: UUID(), rev: 1)
        store.setCalendars([c])
        store.updateCalendar(c.id) { $0.autoColor = .green }
        c.name = "Renamed"
        c.rev = 2
        store.setCalendars([c])
        let back = store.calendars()[0].0
        #expect(back.autoColor == .green && back.name == "Renamed" && back.rev == 2)
    }

    /// What the views read: the engine's pairs carry the automatic color, it
    /// follows a change of one's own color, and an unchanged sync doesn't
    /// count as a change.
    @Test func theEngineColorsEachPair() async {
        let (engine, server, own) = makeEngine()
        let friend = server.addPair()
        await engine.refresh()
        let first = engine.calendar(own)!.displayColor, second = engine.calendar(friend)!.displayColor
        #expect(first != .none && second != .none && first != second && ![first, second].contains(.indigo))
        #expect(engine.backdropColors.count == 3) // the person's own, then the two pairs'

        let rev = engine.revision
        await engine.refresh()
        #expect(engine.revision == rev)

        // Newcomers don't take it, across refreshes.
        for _ in 0..<6 { server.addPair() }
        await engine.refresh()
        #expect(engine.calendar(friend)!.displayColor == second)
        let colors = engine.calendars.map(\.displayColor)
        #expect(Set(colors).count == colors.count)

        // The person takes that color as their own: the pair moves off it.
        engine.myColor = second
        defer { engine.myColor = .none }
        await engine.refresh()
        #expect(engine.accentColor == second)
        #expect(engine.calendar(friend)!.displayColor != second)
    }
}
