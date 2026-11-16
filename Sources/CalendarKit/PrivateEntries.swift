import Foundation

// Intimate entries (0.8.0 design sprint, MVCALE-25; it stays in the kit,
// as decided in MVCALE-23). Neutral names: a "private entry"
// in the types, "Intimate" only as the word a person sees.

/// What one private entry records. The server seals all of it.
public struct CalPrivateContent: Equatable, Sendable, Codable {
    public var at: Date
    public var timeZone: String
    public var durationMinutes: Int = 0
    public var foreplayMinutes: Int = 0
    /// Names from the pair's partner list. Empty and not solo: who isn't set yet.
    public var partnerIDs: [UUID] = []
    public var solo = false
    public var types: [String] = []
    public var protection: [String] = []
    /// Per partner: "yes" | "no" | "unsure".
    public var finishedInside: [UUID: String] = [:]
    public var orgasmsMe = 0
    public var orgasmsPartner = 0
    /// "me" | "partner" | "mutual" | "".
    public var initiatedBy = ""
    public var location = ""
    public var locationNote = ""
    /// 0 = not rated, 1...5.
    public var satisfaction = 0
    public var notes = ""
    /// Logged in one tap; the details come later.
    public var quickLog = false
    public var positions: [String] = []

    public init(at: Date, timeZone: String = TimeZone.current.identifier) {
        self.at = at
        self.timeZone = timeZone
    }

    /// Nobody chosen yet (a quick log), shown as a hollow heart until filled in.
    public var needsWho: Bool { partnerIDs.isEmpty && !solo }
}

/// One private entry on a pair calendar.
public struct CalPrivateEntry: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let calendarID: UUID
    public var content: CalPrivateContent
    public var createdBy: UUID
    public var updatedBy: UUID
    public var rev: Int64
    public var deleted: Bool

    public init(id: UUID = UUID(), calendarID: UUID, content: CalPrivateContent, createdBy: UUID,
                updatedBy: UUID? = nil, rev: Int64 = 0, deleted: Bool = false) {
        self.id = id
        self.calendarID = calendarID
        self.content = content
        self.createdBy = createdBy
        self.updatedBy = updatedBy ?? createdBy
        self.rev = rev
        self.deleted = deleted
    }

    /// The day it falls on, in a zone.
    public func day(in zone: TimeZone) -> CalDate { CalDate(content.at, in: zone) }
}

/// A name on a pair's partner list (both members share it).
public struct CalPartner: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let calendarID: UUID
    public var name: String
    /// .none: the heart falls back to whoever logged the entry.
    public var color: CalColor
    public var archived: Bool
    public var rev: Int64
    public var deleted: Bool

    public init(id: UUID = UUID(), calendarID: UUID, name: String, color: CalColor = .none,
                archived: Bool = false, rev: Int64 = 0, deleted: Bool = false) {
        self.id = id
        self.calendarID = calendarID
        self.name = name
        self.color = color
        self.archived = archived
        self.rev = rev
        self.deleted = deleted
    }
}

/// What a pair's consent covers.
public enum CalConsentKind: String, Sendable, Codable {
    case intimate, cycle
}

/// One calendar's private changes since its cursor.
public struct CalPrivateDelta: Equatable, Sendable {
    public let entries: [CalPrivateEntry]
    public let partners: [CalPartner]
    public let rev: Int64
    public let hasMore: Bool
    /// Consent is off: drop every private row held for this calendar.
    public let reset: Bool

    public static let none = CalPrivateDelta(entries: [], partners: [], rev: 0, hasMore: false, reset: false)
}

/// A day's hearts on the grid: one per author, colored by the partner when
/// every entry names one partner color, else by whoever logged them (plan
/// decision 9).
public struct CalHeart: Equatable, Sendable, Identifiable {
    public let author: UUID
    public let color: CalColor
    public let count: Int
    /// Every entry of it still needs who: drawn hollow.
    public let hollow: Bool
    public var id: UUID { author }

    /// The hearts for one day's entries. `authorColor` is the fallback per
    /// author (the person's own accent for theirs, the pair's color for the
    /// other member's).
    static func hearts(_ entries: [CalPrivateEntry], partners: [UUID: CalPartner],
                       authorColor: (CalPrivateEntry) -> CalColor) -> [CalHeart] {
        let byAuthor = Dictionary(grouping: entries, by: \.createdBy)
        return byAuthor.keys.sorted { $0.uuidString < $1.uuidString }.map { author in
            let mine = byAuthor[author]!
            let colors = Set(mine.map { e -> CalColor in
                // Every partner of the entry has the same color: that one; else the author's.
                let cs = e.content.partnerIDs.map { partners[$0]?.color ?? CalColor.none }
                if let c = cs.first, c != .none, cs.allSatisfy({ $0 == c }) { return c }
                return authorColor(e)
            })
            let color = colors.count == 1 ? colors.first! : authorColor(mine[0])
            return CalHeart(author: author, color: color, count: mine.count, hollow: mine.allSatisfy(\.content.needsWho))
        }
    }
}
