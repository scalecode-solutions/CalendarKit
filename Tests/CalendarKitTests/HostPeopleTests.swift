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
}
