import SwiftUI

/// Create or edit an event, one occurrence, or this-and-following.
struct EventEditorView: View {
    let engine: CalendarEngine
    let request: EditorRequest

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CalEventDraft
    @State private var problem: String?
    private let isNew: Bool

    init(engine: CalendarEngine, request: EditorRequest) {
        self.engine = engine
        self.request = request
        switch request {
        case .new(let day):
            var d = CalEventDraft.new(on: day, calendarID: engine.ownCalendar?.id ?? engine.writableCalendars.first?.id)
            d.alerts = nil
            _draft = State(initialValue: d)
            isNew = true
        case .event(let e):
            _draft = State(initialValue: CalEventDraft(e.fields, calendarID: e.calendarID))
            isNew = false
        case .occurrence(let o):
            var d = CalEventDraft(o.event.fields, calendarID: o.event.calendarID, occurrence: o.when)
            d.repeatPreset = .never // one occurrence doesn't repeat
            _draft = State(initialValue: d)
            isNew = false
        case .following(let o):
            let series = engine.event(o.seriesID ?? o.event.id)
            _draft = State(initialValue: CalEventDraft(series?.fields ?? o.event.fields, calendarID: o.event.calendarID, occurrence: o.when))
            isNew = false
        }
    }

    private var isOccurrence: Bool { if case .occurrence = request { return true }; return false }
    private var calendar: CalCalendar? { draft.calendarID.flatMap { engine.calendar($0) } }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $draft.title)
                TextField("Location", text: $draft.location)
            }
            Section {
                Toggle("All-day", isOn: $draft.allDay)
                DatePicker("Starts", selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    .onChange(of: draft.start) { old, new in
                        // Keep the length when the start moves.
                        draft.end = max(new, draft.end.addingTimeInterval(new.timeIntervalSince(old)))
                    }
                DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                if !draft.allDay && draft.timeZone != .current {
                    LabeledContent("Time zone", value: draft.timeZone.localizedName(for: .generic, locale: .current) ?? draft.timeZone.identifier)
                }
            }
            if !isOccurrence {
                RepeatSection(draft: $draft)
            }
            Section {
                if isNew {
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(engine.writableCalendars) { c in
                            Text(engine.displayName(c)).tag(Optional(c.id))
                        }
                    }
                    .onChange(of: draft.calendarID) { draft.labelID = nil }
                } else if let calendar {
                    LabeledContent("Calendar", value: engine.displayName(calendar))
                }
                if let cal = draft.calendarID, !engine.labels(of: cal).isEmpty {
                    Picker("Label", selection: $draft.labelID) {
                        Text("None").tag(UUID?.none)
                        ForEach(engine.labels(of: cal)) { l in Text(l.name).tag(Optional(l.id)) }
                    }
                }
                ColorRow(selection: $draft.color)
            } footer: {
                if let calendar, !calendar.isOwn {
                    Text("Everyone who can see \(engine.displayName(calendar)) will see this event.")
                } else if let own = calendar, own.isOwn {
                    Text("Anyone you've shared your calendar with will see this event.")
                }
            }
            if isNew {
                Section("Your reminders") {
                    AlertsPicker(allDay: draft.allDay, selection: Binding(
                        get: { draft.alerts ?? (draft.allDay ? engine.alertDefaults.allDay : engine.alertDefaults.timed) },
                        set: { draft.alerts = $0 }))
                }
            }
            Section("Notes") {
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...10)
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .calendarBackdrop(engine)
        .navigationTitle(isNew ? "New Event" : "Edit Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button(isNew ? "Add" : "Save", action: save).bold() }
        }
    }

    private func save() {
        switch draft.fields() {
        case .failure(let p):
            problem = CalEventDraft.describe(p)
        case .success(let fields):
            switch request {
            case .new:
                guard let cal = draft.calendarID else { problem = "Choose a calendar"; return }
                engine.addEvent(to: cal, fields, alerts: draft.alerts)
            case .event(let e): engine.updateEvent(e, fields)
            case .occurrence(let o): engine.updateOccurrence(o, fields)
            case .following(let o): engine.updateFollowing(o, fields)
            }
            dismiss()
        }
    }
}

struct RepeatSection: View {
    @Binding var draft: CalEventDraft

    var body: some View {
        Section {
            Picker("Repeat", selection: $draft.repeatPreset) {
                ForEach(CalRepeatPreset.allCases) { Text($0.title).tag($0) }
            }
            if draft.repeatPreset == .custom {
                Picker("Frequency", selection: $draft.customRule.frequency) {
                    Text("Daily").tag(CalFrequency.daily)
                    Text("Weekly").tag(CalFrequency.weekly)
                    Text("Monthly").tag(CalFrequency.monthly)
                    Text("Yearly").tag(CalFrequency.yearly)
                }
                Stepper("Every \(draft.customRule.interval) \(unit)", value: $draft.customRule.interval, in: 1...99)
                if draft.customRule.frequency == .weekly { weekdays }
                if draft.customRule.frequency == .monthly {
                    Picker("On", selection: $draft.customRule.monthly) {
                        Text("Day \(draft.firstDay.day)").tag(CalMonthlyMode.dayOfMonth)
                        Text("The \(ordinal) \(weekdayName)").tag(CalMonthlyMode.nthWeekday)
                        if draft.firstDay.adding(days: 7).month != draft.firstDay.month {
                            Text("The last \(weekdayName)").tag(CalMonthlyMode.lastWeekday)
                        }
                    }
                }
            }
            if draft.repeatPreset != .never {
                Picker("End Repeat", selection: endingKind) {
                    Text("Never").tag(0)
                    Text("On Date").tag(1)
                    Text("After").tag(2)
                }
                switch draft.ending {
                case .on(let d):
                    DatePicker("End Date", selection: Binding(
                        get: { CalRecurrenceExpander.wallClock(d, hour: 12, minute: 0, second: 0, in: draft.timeZone) },
                        set: { draft.ending = .on(CalDate($0, in: draft.timeZone)) }), in: draft.start..., displayedComponents: .date)
                case .after(let n):
                    Stepper("\(n) times", value: Binding(get: { n }, set: { draft.ending = .after($0) }), in: 1...1000)
                case .never:
                    EmptyView()
                }
            }
        } footer: {
            if draft.repeatPreset != .never, case .success(let f) = draft.fields(), let r = f.recurrence {
                Text(CalRepeatSummary.text(r, first: f.when.firstDay))
            }
        }
    }

    private var unit: String {
        let n = draft.customRule.interval
        switch draft.customRule.frequency {
        case .daily: return n == 1 ? "day" : "days"
        case .weekly: return n == 1 ? "week" : "weeks"
        case .monthly: return n == 1 ? "month" : "months"
        case .yearly: return n == 1 ? "year" : "years"
        }
    }

    private var weekdayName: String {
        ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][draft.firstDay.isoWeekday]
    }

    private var ordinal: String { ["first", "second", "third", "fourth", "fifth"][(draft.firstDay.day - 1) / 7] }

    private var weekdays: some View {
        HStack {
            ForEach(1...7, id: \.self) { d in
                let on = draft.customRule.weekdays.contains(d) || d == draft.firstDay.isoWeekday
                Button {
                    guard d != draft.firstDay.isoWeekday else { return } // the start's day always repeats
                    if on { draft.customRule.weekdays.removeAll { $0 == d } } else { draft.customRule.weekdays.append(d) }
                } label: {
                    Text(["M", "T", "W", "T", "F", "S", "S"][d - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][d])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var endingKind: Binding<Int> {
        Binding(get: {
            switch draft.ending { case .never: 0; case .on: 1; case .after: 2 }
        }, set: { k in
            switch k {
            case 1: draft.ending = .on(draft.firstDay.adding(days: 30))
            case 2: draft.ending = .after(10)
            default: draft.ending = .never
            }
        })
    }
}

/// The palette as a row of swatches.
struct ColorRow: View {
    @Binding var selection: CalColor

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(CalColor.allCases, id: \.self) { c in
                    Button { selection = c } label: {
                        Circle()
                            .fill(c == .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(CalTint(c)))
                            .frame(width: 26, height: 26)
                            .overlay { if selection == c { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                            .overlay { if c == .none { Image(systemName: "slash.circle").foregroundStyle(.secondary) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.title)
                    .accessibilityAddTraits(selection == c ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}
