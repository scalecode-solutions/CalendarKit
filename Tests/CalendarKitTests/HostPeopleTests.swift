import Foundation
import SwiftUI
import Testing
@testable import CalendarKit

/// MVCALE-120: the host's names win in views, a pair's typed name beats them,
/// and the kit never splits a host name. (The engine never sees the host at
/// all, so its order, which assigns the saved auto colours, can't follow it.)
@MainActor
@Suite("Host people", .serialized)
struct HostPeopleTests {
    @Test func noHostByDefault() {
        let host = EnvironmentValues().calendarHostPeople
        let id = UUID()
        #expect(host.name(id) == nil && host.avatar(id, 22) == nil && host.presence(id) == nil)
    }

    @Test func theOrderIsTypedHostDirectorySomeone() async {
        let (engine, server, _) = makeEngine()
        let sam = server.addFriend(name: "Sam Reed")
        let typed = UUID()
        server.addPair(with: typed, name: "Date nights")
        await engine.refresh()
        let host = CalendarHostPeople(name: { $0 == sam || $0 == typed ? "Sunny Day" : nil })
        let samPair = engine.pair(with: sam)!
        #expect(engine.displayName(samPair, host: host) == "Sunny Day")
        #expect(engine.displayName(samPair, host: .none) == "Sam Reed")
        // A name someone typed for the calendar beats the host's for the person.
        #expect(engine.displayName(engine.pair(with: typed)!, host: host) == "Date nights")
        // An empty host answer counts as none; nobody knows them: "Someone".
        #expect(engine.displayName(samPair, host: CalendarHostPeople(name: { _ in "" })) == "Sam Reed")
        #expect(engine.personName(UUID(), host: host) == nil)
        #expect(engine.personName(sam, host: host) == "Sunny Day")
    }

    @Test func theDetailNamesWhoChangedItTheHostsWay() async {
        let (engine, server, _) = makeEngine()
        let sam = server.addFriend(name: "Sam Reed")
        await engine.refresh()
        let me = engine.config.currentUserID
        let host = CalendarHostPeople(name: { $0 == sam ? "Sunny Day" : nil })
        #expect(EventDetailView.changedBy(sam, author: me, me: me, engine: engine, host: host) == "Sunny Day")
        #expect(EventDetailView.changedBy(sam, author: me, me: me, engine: engine, host: .none) == "Sam Reed")
        // Not shown for me, for the author, or for someone nobody knows.
        #expect(EventDetailView.changedBy(me, author: sam, me: me, engine: engine, host: host) == nil)
        #expect(EventDetailView.changedBy(sam, author: sam, me: me, engine: engine, host: host) == nil)
        #expect(EventDetailView.changedBy(UUID(), author: me, me: me, engine: engine, host: host) == nil)
    }

    @Test func aHostNameIsNeverSplit() async {
        let (engine, server, _) = makeEngine()
        let sam = server.addFriend(name: "Sam Reed")
        await engine.refresh()
        let pair = engine.pair(with: sam)!
        // The directory's name gives its first word, as before.
        #expect(engine.shortName(pair, host: .none) == "Sam")
        // The host's name is used whole, or its own short form.
        #expect(engine.shortName(pair, host: CalendarHostPeople(name: { _ in "Sam R." })) == "Sam R.")
        #expect(engine.shortName(pair, host: CalendarHostPeople(name: { _ in "Sam R." }, shortName: { _ in "Sammy" })) == "Sammy")
    }

    /// MVCALE-125: a line about a person names the person, even inside a pair
    /// someone typed a name for ("Added by Sam", not "Added by Date nights").
    @Test func aPersonIsNamedAsThePersonInANamedPair() async {
        let (engine, server, _) = makeEngine()
        let sam = server.addFriend(name: "Sam Reed")
        let pairID = server.addPair(with: sam, name: "Date nights", friend: false)
        await engine.refresh()
        let pair = engine.calendar(pairID)!
        let me = engine.config.currentUserID
        let host = CalendarHostPeople(name: { $0 == sam ? "Sunny Day" : nil })
        // The pair keeps its typed name; the person is the host's, then the directory's.
        #expect(engine.displayName(pair, host: host) == "Date nights")
        #expect(engine.personName(sam, in: pair, host: host) == "Sunny Day")
        #expect(engine.personName(sam, in: pair, host: .none) == "Sam Reed")
        // Nobody knows them: the pair's label, never "Someone" over a name we have.
        #expect(engine.personName(UUID(), in: pair, host: host) == "Date nights")
        // Whose cycle a row is.
        #expect(CycleDaySection.name(sam, pair: pair, engine: engine, host: host) == "Sunny Day")
        #expect(CycleDaySection.name(me, pair: pair, engine: engine, host: host) == "You")
        // "Added by …" names whoever made the entry.
        let entry = CalPrivateEntry(calendarID: pairID, content: CalPrivateContent(at: Date()), createdBy: sam)
        #expect(PrivateEntryRow.addedBy(entry, engine: engine, host: host) == "Sunny Day")
        #expect(PrivateEntryRow.addedBy(entry, engine: engine, host: .none) == "Sam Reed")
    }

    /// 6878f24: inside one pair, the other person's items badge as the person,
    /// across pairs as the pair; mine say "you".
    @Test func theInPairBadgeNamesThePerson() async {
        let (engine, server, _) = makeEngine()
        let sam = server.addFriend(name: "Sam Reed")
        let pairID = server.addPair(with: sam, name: "Date nights", friend: false)
        let event = server.externalCreate(pairID, allDay("Dinner", 2026, 11, 10))
        await engine.refresh()
        let pair = engine.calendar(pairID)!
        let me = engine.config.currentUserID
        let host = CalendarHostPeople(name: { $0 == sam ? "Sunny Day" : nil })
        func occurrence(by author: UUID) -> CalOccurrence {
            CalOccurrence(id: event.id.uuidString, event: event, seriesID: nil, originalStart: nil, when: event.fields.when,
                          calendar: pair, label: nil, color: pair.displayColor, author: author)
        }
        #expect(AuthorBadge.author(of: occurrence(by: sam), engine: engine, host: host, inPair: true)?.name == "Sunny Day")
        #expect(AuthorBadge.author(of: occurrence(by: sam), engine: engine, host: .none, inPair: true)?.name == "Sam Reed")
        #expect(AuthorBadge.author(of: occurrence(by: me), engine: engine, host: host, inPair: true)?.name == "you")
        // Across every pair, the badge is the pair.
        #expect(AuthorBadge.author(of: occurrence(by: sam), engine: engine, host: host, inPair: false)?.name == "Date nights")
    }
}
