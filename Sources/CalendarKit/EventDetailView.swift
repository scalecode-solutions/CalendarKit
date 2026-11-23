import SwiftUI

/// One event (or occurrence): when, repeats, whose, label, where, notes;
/// edit and delete for people who may write.
struct EventDetailView: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let occurrence: CalOccurrence
    let edit: (EditorRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var askEdit = false
    @State private var askDelete = false

    private var event: CalEvent { occurrence.event }
    private var series: CalEvent? { occurrence.seriesID.flatMap { engine.event($0) } }
    /// Frozen pairs (no longer friends) are read-only.
    private var canWrite: Bool { !occurrence.calendar.frozen }

    private var me: UUID { engine.config.currentUserID }
    /// Who put it there, when that isn't the person reading: the other one in
    /// the pair ("Someone" once they're not a friend). Exactly when a row
    /// shows the author's avatar. For an occurrence it's the series' maker.
    private var addedBy: (name: String, contact: CalContact?, id: UUID)? {
        let a = occurrence.author
        if a == me { return nil }
        let p = engine.people[a]
        return (engine.personName(a, host: host) ?? "Someone", p, a)
    }
    /// Who changed it last, when that's the other person and they didn't add it.
    private var changedBy: CalContact? {
        let u = event.updatedBy
        return u == me || u == occurrence.author ? nil : engine.people[u]
    }

    var body: some View {
        List {
            Section {
                EventHero(occurrence: occurrence, repeatText: series.flatMap { s in
                    s.fields.recurrence.map { CalRepeatSummary.text($0, first: s.fields.when.firstDay) }
                })
            }
            Section {
                DetailRow(icon: "calendar") {
                    HStack(spacing: 8) {
                        CalAvatar(contact: engine.person(of: occurrence.calendar), fallbackName: engine.displayName(occurrence.calendar, host: host),
                                  tint: occurrence.calendar.displayColor, size: 22, personID: occurrence.calendar.otherID)
                        Text(engine.displayName(occurrence.calendar, host: host))
                    }
                }
                if let label = occurrence.label {
                    DetailRow(icon: "tag") {
                        HStack(spacing: 6) {
                            Circle().fill(CalTint(label.color == .none ? occurrence.color : label.color)).frame(width: 10, height: 10)
                            Text(label.name)
                        }
                    }
                }
                if !event.fields.location.isEmpty {
                    DetailRow(icon: "mappin.and.ellipse") { Text(event.fields.location) }
                }
                if let who = addedBy {
                    DetailRow(icon: "person") {
                        HStack(spacing: 8) {
                            CalAvatar(contact: who.contact, fallbackName: who.name,
                                      tint: occurrence.calendar.displayColor, size: 22, personID: who.id)
                            Text("Added by \(who.name)")
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let who = changedBy {
                    DetailRow(icon: "pencil") { Text("Last changed by \(who.name)") }
                }
            }
            if !event.fields.notes.isEmpty {
                Section {
                    DetailRow(icon: "text.alignleft") { Text(event.fields.notes) }
                }
            }
            if canWrite {
                Section {
                    Button("Delete Event", role: .destructive) {
                        if occurrence.seriesID == nil { engine.deleteEvent(event); dismiss() } else { askDelete = true }
                    }
                }
            }
        }
        .calendarBackdrop(engine)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            if canWrite {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { occurrence.seriesID == nil ? edit(.event(event)) : (askEdit = true) }
                }
            }
        }
        .confirmationDialog("This is a repeating event.", isPresented: $askEdit, titleVisibility: .hidden) {
            Button("This Event Only") { edit(.occurrence(occurrence)) }
            Button("All Future Events") { edit(.following(occurrence)) }
        }
        .confirmationDialog("This is a repeating event.", isPresented: $askDelete, titleVisibility: .hidden) {
            Button("Delete This Event Only", role: .destructive) { engine.deleteOccurrence(occurrence); dismiss() }
            Button("Delete All Future Events", role: .destructive) { engine.deleteFollowing(occurrence); dismiss() }
        }
    }
}

/// The top of the detail: the title on the calendar's color, then the time
/// big enough to read at a glance (TimeTree's start → end), the day under it,
/// and how it repeats.
struct EventHero: View {
    let occurrence: CalOccurrence
    let repeatText: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(CalTint(occurrence.color))
                .frame(width: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(occurrence.event.fields.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                times
                if let repeatText {
                    Label(repeatText, systemImage: "repeat")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let zone = EventText.otherZone(occurrence.when) {
                    Label(zone, systemImage: "globe")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var times: some View {
        let p = EventText.hero(occurrence.when)
        if let end = p.end {
            ViewThatFits(in: .horizontal) {
                // The arrow sits between the times, not the small day lines.
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    stamp(p.start)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    stamp(end)
                }
                VStack(alignment: .leading, spacing: 6) { stamp(p.start); stamp(end) }
            }
            .accessibilityElement(children: .combine)
        } else {
            stamp(p.start)
        }
    }

    private func stamp(_ s: EventText.Stamp) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.day).font(.subheadline).foregroundStyle(.secondary)
            Text(s.big).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

/// A detail row: an icon in a fixed column, then its content (Google's).
struct DetailRow<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: column)
                .accessibilityHidden(true)
            content
        }
    }
}

enum EventText {
    /// One end of the hero: the day in small type, the time (or "All day") big.
    struct Stamp: Equatable { let day: String; let big: String }

    /// The hero's start and end. A one-day event has no separate end stamp
    /// for its day: "Sat, Nov 14 / 10:00 AM → 1:00 PM"; an all-day event is
    /// "All day", over its days.
    static func hero(_ w: CalWhen, zone: TimeZone = .current, now: Date = Date()) -> (start: Stamp, end: Stamp?) {
        // The year only when it isn't this one.
        let thisYear = CalDate(now, in: zone).year
        let lastYear: Int
        switch w {
        case .allDay(_, let e): lastYear = e.adding(days: -1).year
        case .timed(_, let e, _): lastYear = CalDate(e, in: zone).year
        }
        let dayTemplate = w.firstDay.year == thisYear && lastYear == thisYear ? "EEEMMMd" : "EEEMMMdy"
        switch w {
        case .allDay(let s, let e):
            let f = CalFormat.template(dayTemplate, zone: CalFormat.utc)
            let last = e.adding(days: -1)
            if last == s { return (Stamp(day: f.string(from: s.utcMidnight), big: "All day"), nil) }
            return (Stamp(day: "All day", big: f.string(from: s.utcMidnight)),
                    Stamp(day: "\u{00A0}", big: f.string(from: last.utcMidnight)))
        case .timed(let s, let e, _):
            let day = CalFormat.template(dayTemplate, zone: zone)
            let time = CalFormat.styles(date: .none, time: .short, zone: zone)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            if s == e { return (Stamp(day: day.string(from: s), big: time.string(from: s)), nil) }
            if cal.isDate(s, inSameDayAs: e) {
                return (Stamp(day: day.string(from: s), big: time.string(from: s)),
                        Stamp(day: "\u{00A0}", big: time.string(from: e)))
            }
            return (Stamp(day: day.string(from: s), big: time.string(from: s)),
                    Stamp(day: day.string(from: e), big: time.string(from: e)))
        }
    }

    /// "Central Time", when the event keeps a zone other than the device's.
    static func otherZone(_ w: CalWhen) -> String? {
        guard case .timed(_, _, let tz) = w, tz != TimeZone.current.identifier, let zone = TimeZone(identifier: tz) else { return nil }
        return zone.localizedName(for: .generic, locale: .current) ?? tz
    }

    static func when(_ w: CalWhen) -> String {
        switch w {
        case .allDay(let s, let e):
            let f = CalFormat.styles(date: .full, time: .none, zone: CalFormat.utc)
            let first = f.string(from: s.utcMidnight)
            if s.days(to: e) == 1 { return "\(first), all day" }
            return "\(first) – \(f.string(from: e.adding(days: -1).utcMidnight)), all day"
        case .timed(let s, let e, let tz):
            let f = CalFormat.styles(date: .full, time: .short)
            let t = CalFormat.styles(date: .none, time: .short)
            let sameDay = Calendar.current.isDate(s, inSameDayAs: e)
            var out = s == e ? f.string(from: s) : sameDay ? "\(f.string(from: s)) – \(t.string(from: e))" : "\(f.string(from: s)) – \(f.string(from: e))"
            if tz != TimeZone.current.identifier, let zone = TimeZone(identifier: tz) {
                out += " (\(zone.localizedName(for: .shortGeneric, locale: .current) ?? tz))"
            }
            return out
        }
    }
}
