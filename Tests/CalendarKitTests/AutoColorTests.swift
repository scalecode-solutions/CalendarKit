import Foundation
import Testing
@testable import CalendarKit

/// A friend's calendar with no color from anyone gets one of its own, apart
/// from the person's (two uncolored calendars both drew as indigo).
@Suite("Automatic calendar colors")
struct AutoColorTests {
    private func cal(_ role: CalRole, owner: UUID = UUID(), color: CalColor = .none, pref: CalColor = .none) -> CalCalendar {
        CalCalendar(id: UUID(), ownerID: owner, name: "", color: color, role: role, rev: 0,
                    grantExpiresAt: nil, visible: true, prefColor: pref)
    }

    /// Two people, neither chose a color: own stays the default, the friend's differs.
    @Test func aFriendsUncoloredCalendarIsNotTheDefault() {
        let out = CalCalendar.assignAutoColors([cal(.owner), cal(.view)])
        #expect(out[0].autoColor == nil && out[0].displayColor == .none)
        #expect(out[1].autoColor != nil)
        #expect(out[1].displayColor != .none && out[1].displayColor != .indigo)
    }

    /// The same owner gets the same color on every launch, whatever the order.
    @Test func theSamePersonGetsTheSameColor() {
        let owner = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!
        let a = CalCalendar.assignAutoColors([cal(.owner), cal(.view, owner: owner)])[1].displayColor
        for _ in 0..<20 {
            let friends = (0..<3).map { _ in cal(.view) } + [cal(.view, owner: owner)]
            let out = CalCalendar.assignAutoColors(([cal(.owner)] + friends).shuffled())
            let mine = out.first { $0.ownerID == owner }!.displayColor
            // Alone it gets its first choice; with others it may walk on, but
            // the result is the same however they arrive.
            let again = CalCalendar.assignAutoColors(out.shuffled()).first { $0.ownerID == owner }!.displayColor
            #expect(mine == again)
        }
        // Alone beside the person, it gets its own slot, walking on past
        // indigo (theirs) and blue and purple (beside it).
        let start = CalCalendar.stableIndex(owner, 12)
        let expected = (0..<12).map { CalCalendar.autoPalette[(start + $0) % 12] }.first { ![.indigo, .blue, .purple].contains($0) }
        #expect(a == expected)
        // FNV-1a over the bytes is fixed: pin this id's slot, so a change of
        // hash (which would recolor everyone's friends) shows up here.
        #expect(start == 6)
    }

    /// Not the colors beside one's own while others are free: blue next to
    /// the default indigo was the first pick for a real account id.
    @Test func notBesideTheOwnColorWhileOthersAreFree() {
        for own in CalColor.allCases {
            let mine = own == .none ? CalColor.indigo : own
            let near = CalCalendar.neighbours(of: mine)
            for _ in 0..<20 {
                let out = CalCalendar.assignAutoColors([cal(.owner, color: own)] + (0..<3).map { _ in cal(.view) })
                #expect(!out.dropFirst().contains { near.contains($0.displayColor) }, "own \(own)")
            }
        }
        #expect(CalCalendar.neighbours(of: .indigo) == [.blue, .purple])
        #expect(CalCalendar.neighbours(of: .red) == [.pink, .orange])
        #expect(CalCalendar.neighbours(of: .gray).isEmpty)
    }

    /// Never the person's own color, whichever they picked (or the default).
    @Test func neverTheOwnColor() {
        for own in CalColor.allCases {
            let friends = (0..<11).map { _ in cal(.view) }
            let out = CalCalendar.assignAutoColors([cal(.owner, color: own)] + friends)
            let mine = own == .none ? CalColor.indigo : own
            #expect(!out.dropFirst().contains { $0.displayColor == mine }, "own \(own)")
        }
        // Their own override of their own calendar counts too.
        let out = CalCalendar.assignAutoColors([cal(.owner, color: .blue, pref: .orange)] + (0..<11).map { _ in cal(.view) })
        #expect(!out.dropFirst().contains { $0.displayColor == .orange })
    }

    /// Friends never share a color while there are colors left (11 beside one's own).
    @Test func friendsAreAllDifferent() {
        for _ in 0..<50 {
            let out = CalCalendar.assignAutoColors([cal(.owner)] + (0..<11).map { _ in cal(.view) })
            let colors = out.dropFirst().map(\.displayColor)
            #expect(Set(colors).count == 11)
            #expect(!colors.contains(.gray) && !colors.contains(.brown) && !colors.contains(.none))
        }
        // Past that they repeat rather than go blank.
        let many = CalCalendar.assignAutoColors([cal(.owner)] + (0..<15).map { _ in cal(.view) })
        #expect(!many.contains { !$0.isOwn && $0.displayColor == .none })
    }

    /// Anything chosen wins, and a chosen color is taken from the automatic ones.
    @Test func chosenColorsWinAndAreAvoided() {
        let out = CalCalendar.assignAutoColors([cal(.owner), cal(.view, color: .orange), cal(.view, pref: .teal),
                                                cal(.view)])
        #expect(out[1].autoColor == nil && out[1].displayColor == .orange)
        #expect(out[2].autoColor == nil && out[2].displayColor == .teal)
        #expect(![CalColor.orange, .teal, .indigo].contains(out[3].displayColor))
    }

    /// Adding friends one at a time never recolors one already there (the
    /// review measured 7% to 39% moving without memory, from 1 to 5 friends).
    @Test func addingAFriendNeverMovesAnother() {
        for _ in 0..<500 {
            var cals = [cal(.owner)]
            for _ in 0..<11 {
                let before = Dictionary(uniqueKeysWithValues: cals.map { ($0.id, $0.displayColor) })
                cals = CalCalendar.assignAutoColors((cals + [cal(.view)]).shuffled())
                for c in cals where before[c.id] != nil { #expect(c.displayColor == before[c.id]) }
            }
            #expect(Set(cals.filter { !$0.isOwn }.map(\.displayColor)).count == 11)
        }
    }

    /// A remembered color gives way when it's chosen for something else, or
    /// when the person's own color moves next to it; otherwise it stays, even
    /// where a newcomer's id would have landed on it.
    @Test func aRememberedColorStaysUntilItIsTaken() {
        var a = cal(.view); a.autoColor = .green
        var out = CalCalendar.assignAutoColors([cal(.owner), a])
        #expect(out[1].displayColor == .green)
        // Someone colors their calendar green: the remembered one moves.
        out = CalCalendar.assignAutoColors([cal(.owner), a, cal(.view, color: .green)])
        #expect(out[1].displayColor != .green)
        // The person makes their own mint (green's neighbour): it moves too.
        out = CalCalendar.assignAutoColors([cal(.owner, color: .mint), a])
        #expect(![.mint, .green, .teal].contains(out[1].displayColor))
        // A friend who colors their calendar forgets the automatic one.
        var b = cal(.view, color: .red); b.autoColor = .orange
        #expect(CalCalendar.assignAutoColors([cal(.owner), b])[1].autoColor == nil)
    }

    /// The person's own choice for a friend's calendar beats the automatic one.
    @Test func displayColorOrder() {
        var c = cal(.view)
        c.autoColor = .green
        #expect(c.displayColor == .green)
        c.color = .red
        #expect(c.displayColor == .red)
        c.prefColor = .pink
        #expect(c.displayColor == .pink)
    }
}

@MainActor
@Suite("Automatic calendar colors, engine")
struct AutoColorEngineTests {
    /// The server's list (which has no automatic color) doesn't wipe the one
    /// this device remembers, and the rest of the calendar still updates.
    @Test func theStoreKeepsItThroughTheServersList() throws {
        let store = try CalendarStore(userID: UUID(), appGroup: nil, inMemory: true)
        var c = CalCalendar(id: UUID(), ownerID: UUID(), name: "", color: .none, role: .view, rev: 1,
                            grantExpiresAt: nil, visible: true, prefColor: .none)
        store.setCalendars([c])
        store.updateCalendar(c.id) { $0.autoColor = .green }
        c.name = "Renamed"
        c.rev = 2
        store.setCalendars([c])
        let back = store.calendars()[0].0
        #expect(back.autoColor == .green && back.name == "Renamed" && back.rev == 2)
    }

    /// What the views read: the engine's calendars carry the automatic color,
    /// it follows a change of one's own color, and an unchanged sync doesn't
    /// count as a change.
    @Test func theEngineColorsAFriendsCalendar() async {
        let (engine, server, own) = makeEngine()
        let friend = server.addCalendar(owner: UUID(), role: .view)
        server.set { s in for i in s.calendars.indices { s.calendars[i].color = .none } }
        await engine.refresh()
        let shared = engine.calendar(friend)!
        #expect(engine.calendar(own)!.displayColor == .none)
        #expect(shared.displayColor != .none && shared.displayColor != .indigo)
        #expect(engine.backdropColors.count == 2)

        let rev = engine.revision
        await engine.refresh()
        #expect(engine.revision == rev)

        // Own takes the friend's color: the friend's moves off it.
        let taken = shared.displayColor
        // A newcomer doesn't take it, across refreshes.
        for _ in 0..<6 { _ = server.addCalendar(owner: UUID(), role: .view) }
        server.set { s in for i in s.calendars.indices { s.calendars[i].color = .none } }
        await engine.refresh()
        #expect(engine.calendar(friend)!.displayColor == taken)
        let friends = engine.calendars.filter { !$0.isOwn }.map(\.displayColor)
        #expect(Set(friends).count == friends.count)

        engine.renameOwnCalendar(nil, color: taken)
        await engine.refresh()
        #expect(engine.calendar(own)!.displayColor == taken)
        #expect(engine.calendar(friend)!.displayColor != taken)
    }
}
