import SwiftUI

/// Create or edit an event, one occurrence, or this-and-following.
struct EventEditorView: View {
    @Environment(\.calendarHostPeople) private var host
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
        case .new(let day, let pair):
            _draft = State(initialValue: CalEventDraft.new(on: day, calendarID: Self.defaultCalendar(engine, focused: pair)?.id))
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
            var d = CalEventDraft(series?.fields ?? o.event.fields, calendarID: o.event.calendarID, occurrence: o.when)
            // A counted series: the rest has what's left, not the whole count
            // again (R3); the form shows what will be saved.
            if let series, let left = Self.remaining(of: series, from: o) { d.ending = .after(left) }
            _draft = State(initialValue: d)
            isNew = false
        }
    }

    /// How many occurrences of a counted series fall on or after `o`'s day.
    static func remaining(of series: CalEvent, from o: CalOccurrence) -> Int? {
        guard let rule = series.fields.recurrence, let total = rule.count, let original = o.originalStart else { return nil }
        let first = series.fields.when.firstDay
        let day: CalDate
        switch original {
        case .date(let d): day = d
        case .instant(let t):
            guard case .timed(_, _, let tz) = series.fields.when else { return nil }
            day = CalDate(t, in: TimeZone(identifier: tz) ?? .gmt)
        }
        guard day > first else { return nil }
        let before = CalRecurrenceExpander.dates(rule, first: first, through: day.adding(days: -1)).count
        return max(1, total - before)
    }

    private var isOccurrence: Bool { if case .occurrence = request { return true }; return false }
    /// Where a new event goes: the pair in focus, else the first shown pair
    /// that can take it, else any that can.
    static func defaultCalendar(_ engine: CalendarEngine, focused: UUID?) -> CalCalendar? {
        let w = engine.writableCalendars
        return w.first { $0.id == focused } ?? w.first(where: \.visible) ?? w.first
    }

    private var calendar: CalCalendar? { draft.calendarID.flatMap { engine.calendar($0) } }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $draft.title)
                TextField("Location", text: $draft.location)
            }
            Section {
                Toggle("All-day", isOn: Binding(get: { draft.allDay }, set: { draft.setAllDay($0) }))
                // Moving the start keeps the length (only when the person moves it).
                DatePicker("Starts", selection: Binding(get: { draft.start }, set: { draft.moveStart(to: $0) }),
                           displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
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
                            Text(engine.displayName(c, host: host)).tag(Optional(c.id))
                        }
                    }
                    .onChange(of: draft.calendarID) { draft.labelID = nil }
                } else if let calendar {
                    LabeledContent("Calendar", value: engine.displayName(calendar, host: host))
                }
                if let cal = draft.calendarID, !engine.labels(of: cal).isEmpty {
                    Picker("Label", selection: $draft.labelID) {
                        Text("None").tag(UUID?.none)
                        ForEach(engine.labels(of: cal)) { l in Text(l.name).tag(Optional(l.id)) }
                    }
                }
                ColorRow(selection: $draft.color)
            } footer: {
                // Who will see it matters when choosing where it goes; once
                // it's there, saying so on every edit is noise (Frond's audit).
                if isNew, let calendar {
                    Text("You and \(engine.personName(calendar.otherID, in: calendar, host: host)) both see and can change it.")
                }
            }
            Section("Notes") {
                TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...10)
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        // Show times in the event's own zone, the zone the label names and
        // the one all-day days are derived in (R35). New events use the
        // device's zone, so nothing changes for them.
        .environment(\.timeZone, draft.timeZone)
        .scrollDismissesKeyboard(.interactively)
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
            // The phone is locked and the store can't open: a write now would
            // go nowhere. Keep the editor open and say why (MVCALE-39).
            guard engine.canSave() else { problem = "Unlock your phone to save this."; return }
            switch request {
            case .new:
                guard let cal = draft.calendarID else { problem = "Choose a calendar"; return }
                engine.addEvent(to: cal, fields)
            case .event(let e): engine.updateEvent(e, fields)
            case .occurrence(let o): engine.updateOccurrence(o, fields)
            case .following(let o): engine.updateFollowing(o, fields)
            }
            dismiss()
        }
    }
}

extension View {
    /// A segmented picker, or a menu when `menu` (large text sizes).
    @ViewBuilder func segmentedUnless(_ menu: Bool) -> some View {
        if menu { pickerStyle(.menu) } else { pickerStyle(.segmented) }
    }
}

struct RepeatSection: View {
    @Binding var draft: CalEventDraft
    @Environment(\.calendarAccent) private var accent
    @ScaledMetric(relativeTo: .footnote) private var chip: CGFloat = 32
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Segmented controls cut their labels ("Wee…") from extra-extra-large
    /// text: from there the same choices are a menu, still one tap to open.
    private var asMenu: Bool { typeSize >= .xxLarge }

    var body: some View {
        Section {
            // One tap from "Never" to "Weekly" (Structured's picker): the
            // frequency is a segmented control, and only what it needs shows.
            Picker("Repeat", selection: $draft.frequency) {
                Text("Never").tag(CalFrequency?.none)
                Text("Daily").tag(Optional(CalFrequency.daily))
                Text("Weekly").tag(Optional(CalFrequency.weekly))
                Text("Monthly").tag(Optional(CalFrequency.monthly))
                Text("Yearly").tag(Optional(CalFrequency.yearly))
            }
            .segmentedUnless(asMenu)
            .accessibilityIdentifier("Repeat")
            if draft.frequency != nil {
                Stepper("Every \(draft.customRule.interval == 1 ? "" : "\(draft.customRule.interval) ")\(unit)",
                        value: $draft.customRule.interval, in: 1...99)
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
                Picker("Ends", selection: endingKind) {
                    Text("Never").tag(0)
                    Text("On a date").tag(1)
                    Text("After").tag(2)
                }
                .segmentedUnless(asMenu)
                switch draft.ending {
                case .on(let d):
                    DatePicker("End date", selection: Binding(
                        get: { CalRecurrenceExpander.wallClock(d, hour: 12, minute: 0, second: 0, in: draft.timeZone) },
                        set: { draft.ending = .on(CalDate($0, in: draft.timeZone)) }), in: draft.start..., displayedComponents: .date)
                case .after(let n):
                    Stepper(n == 1 ? "Once" : "\(n) times", value: Binding(get: { n }, set: { draft.ending = .after($0) }), in: 1...1000)
                case .never:
                    EmptyView()
                }
            }
        } header: {
            Text("Repeat")
        } footer: {
            if draft.frequency != nil, case .success(let f) = draft.fields(), let r = f.recurrence {
                Label(CalRepeatSummary.text(r, first: f.when.firstDay), systemImage: "repeat")
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

    /// The repeat days as chips, in the person's week order and language.
    private var weekdays: some View {
        HStack {
            ForEach(WeekdayChips.order(), id: \.self) { d in
                let on = draft.customRule.weekdays.contains(d) || d == draft.firstDay.isoWeekday
                Button {
                    guard d != draft.firstDay.isoWeekday else { return } // the start's day always repeats
                    if on { draft.customRule.weekdays.removeAll { $0 == d } } else { draft.customRule.weekdays.append(d) }
                } label: {
                    Text(WeekdayChips.letter(d))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: min(chip, 44), height: min(chip, 44))
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
                        .foregroundStyle(on ? AnyShapeStyle(CalOnTint(accent)) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(WeekdayChips.name(d))
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

/// The palette: a labelled grid of swatches, all in view (a scrolling row
/// cut a swatch in half at the edge and didn't read as a choice).
struct ColorRow: View {
    @Binding var selection: CalColor
    @ScaledMetric(relativeTo: .body) private var swatch: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Color", value: selection == .none ? "Calendar's" : selection.title)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 10) {
                ForEach(CalColor.allCases, id: \.self) { c in
                    Button { selection = c } label: {
                        Circle()
                            .fill(c == .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(CalTint(c)))
                            .frame(width: min(swatch, 40), height: min(swatch, 40))
                            .overlay { if selection == c { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(c == .none ? AnyShapeStyle(.primary) : AnyShapeStyle(CalOnTint(c))) } }
                            .overlay { if c == .none && selection != c { Image(systemName: "slash.circle").foregroundStyle(.secondary) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c == .none ? "Calendar's color" : c.title)
                    .accessibilityAddTraits(selection == c ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Weekday chips: ISO numbers (1 = Monday ... 7 = Sunday, what rules store),
/// shown in the locale's week order with its letters and names.
enum WeekdayChips {
    /// ISO weekdays starting at the calendar's first weekday (1 = Sunday).
    static func order(firstWeekday: Int = Calendar.current.firstWeekday) -> [Int] {
        (0..<7).map { iso(gregorian: (firstWeekday - 1 + $0) % 7 + 1) }
    }

    static func letter(_ iso: Int, calendar: Calendar = .current) -> String {
        calendar.veryShortStandaloneWeekdaySymbols[gregorian(iso: iso) - 1]
    }

    static func name(_ iso: Int, calendar: Calendar = .current) -> String {
        calendar.standaloneWeekdaySymbols[gregorian(iso: iso) - 1]
    }

    /// Foundation numbers Sunday 1 ... Saturday 7; ISO numbers Monday 1 ... Sunday 7.
    static func iso(gregorian g: Int) -> Int { g == 1 ? 7 : g - 1 }
    static func gregorian(iso i: Int) -> Int { i == 7 ? 1 : i + 1 }
}
