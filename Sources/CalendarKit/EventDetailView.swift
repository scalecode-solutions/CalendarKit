import SwiftUI

/// One event (or occurrence): when, repeats, whose, label, where, notes, my
/// reminders; edit and delete for people who may write.
struct EventDetailView: View {
    let engine: CalendarEngine
    let occurrence: CalOccurrence
    let edit: (EditorRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var askEdit = false
    @State private var askDelete = false

    private var event: CalEvent { occurrence.event }
    private var series: CalEvent? { occurrence.seriesID.flatMap { engine.event($0) } }
    private var canWrite: Bool { occurrence.calendar.role.canWrite }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.fields.title).font(.title2.weight(.semibold))
                    Text(EventText.when(occurrence.when)).foregroundStyle(.secondary)
                    if let s = series, let r = s.fields.recurrence {
                        Label(CalRepeatSummary.text(r, first: s.fields.when.firstDay), systemImage: "repeat")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Calendar") {
                    HStack(spacing: 6) {
                        CalAvatar(contact: engine.owner(of: occurrence.calendar), fallbackName: engine.displayName(occurrence.calendar),
                                  tint: occurrence.calendar.displayColor, size: 20)
                        Text(engine.displayName(occurrence.calendar))
                    }
                }
                if let label = occurrence.label {
                    LabeledContent("Label") {
                        HStack(spacing: 6) {
                            Circle().fill(CalTint(label.color == .none ? occurrence.color : label.color)).frame(width: 10, height: 10)
                            Text(label.name)
                        }
                    }
                }
                if !event.fields.location.isEmpty { LabeledContent("Location", value: event.fields.location) }
                if let who = engine.people[event.updatedBy], event.updatedBy != engine.config.currentUserID {
                    LabeledContent("Last changed by", value: who.name)
                }
            }
            if !event.fields.notes.isEmpty {
                Section("Notes") { Text(event.fields.notes) }
            }
            Section("Your reminders") {
                AlertsPicker(allDay: occurrence.isAllDay,
                             selection: Binding(get: { engine.effectiveAlerts(for: occurrence) },
                                                set: { engine.setAlerts(for: series ?? event, minutesBefore: $0) }))
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
        .confirmationDialog("This is a repeating event.", isPresented: $askEdit, titleVisibility: .visible) {
            Button("This Event Only") { edit(.occurrence(occurrence)) }
            Button("All Future Events") { edit(.following(occurrence)) }
        }
        .confirmationDialog("This is a repeating event.", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Delete This Event Only", role: .destructive) { engine.deleteOccurrence(occurrence); dismiss() }
            Button("Delete All Future Events", role: .destructive) { engine.deleteFollowing(occurrence); dismiss() }
        }
    }
}

enum EventText {
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

/// Reminder choices as toggles.
struct AlertsPicker: View {
    let allDay: Bool
    @Binding var selection: [Int]

    static let timedChoices: [(Int, String)] = [(0, "At time of event"), (5, "5 minutes before"), (15, "15 minutes before"),
                                                (30, "30 minutes before"), (60, "1 hour before"), (120, "2 hours before"),
                                                (1440, "1 day before"), (2880, "2 days before"), (10080, "1 week before")]
    static let allDayChoices: [(Int, String)] = [(-540, "On the day (9 AM)"), (900, "1 day before (9 AM)"),
                                                 (2340, "2 days before (9 AM)"), (9540, "1 week before (9 AM)")]

    var body: some View {
        ForEach(allDay ? Self.allDayChoices : Self.timedChoices, id: \.0) { m, title in
            Toggle(title, isOn: Binding(get: { selection.contains(m) }, set: { on in
                var s = selection.filter { $0 != m }
                if on && s.count < 5 { s.append(m) }
                selection = s.sorted()
            }))
            .disabled(!selection.contains(m) && selection.count >= 5)
        }
    }
}
