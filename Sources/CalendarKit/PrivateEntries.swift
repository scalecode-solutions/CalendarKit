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
    /// Whose encounter it is (MVCALE-51): either member may log one for the
    /// other (one member logging the other's encounter). nil: whoever logged it.
    public var subjectID: UUID?

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

    /// Whose encounter it is: its subject, else whoever logged it.
    public var subject: UUID { content.subjectID ?? createdBy }
}

/// A name on one person's partner list, on a pair (MVCALE-51): each member
/// keeps their own; both receive both lists, so the other's entries still
/// show who.
public struct CalPartner: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let calendarID: UUID
    /// Who added it (only they change it). nil: from before partners had an
    /// owner, offered to nobody, still naming old entries.
    public var ownerID: UUID?
    public var name: String
    /// .none: the heart falls back to whoever logged the entry.
    public var color: CalColor
    public var archived: Bool
    /// Its owner's default (MVCALE-51): their new entries and quick logs, and
    /// the other member's "Intimate for", start with it. One per owner per
    /// pair; the server clears the old one. Never an archived one.
    public var isDefault: Bool
    public var rev: Int64
    public var deleted: Bool

    public init(id: UUID = UUID(), calendarID: UUID, ownerID: UUID? = nil, name: String, color: CalColor = .none,
                archived: Bool = false, isDefault: Bool = false, rev: Int64 = 0, deleted: Bool = false) {
        self.id = id
        self.calendarID = calendarID
        self.ownerID = ownerID
        self.name = name
        self.color = color
        self.archived = archived
        self.isDefault = isDefault
        self.rev = rev
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case id, calendarID, ownerID, name, color, archived, isDefault, rev, deleted
    }

    /// Stored partners from before owners or defaults read as nobody's and
    /// not a default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        calendarID = try c.decode(UUID.self, forKey: .calendarID)
        ownerID = try c.decodeIfPresent(UUID.self, forKey: .ownerID)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(CalColor.self, forKey: .color)
        archived = try c.decode(Bool.self, forKey: .archived)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        rev = try c.decode(Int64.self, forKey: .rev)
        deleted = try c.decode(Bool.self, forKey: .deleted)
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

/// A day's hearts on the grid: one per person the entries are about (their
/// subject), colored by the partner when every entry names one partner color,
/// else by that person's color (plan
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
        // Per person the entries are about (their subject, MVCALE-51).
        let byAuthor = Dictionary(grouping: entries, by: \.subject)
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
