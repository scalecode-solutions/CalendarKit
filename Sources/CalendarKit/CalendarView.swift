import SwiftUI

/// The calendar: a month grid with each day's events as colored title chips and
/// the selected day's events below, or an agenda of everything coming up.
/// Above both, a chip per person whose calendar you see, to show or hide it. The kit
/// owns its content (the Month/Agenda switch and "+" sit in it); the HOST owns
/// the navigation bar (title, back, its own buttons) and pushes
/// `CalendarSettingsView` from wherever it likes (e.g. a trailing gear).
/// The host starts and stops the engine.
public struct CalendarView: View {
    @Bindable var engine: CalendarEngine
    let appearance: CalendarAppearance

    @State private var selected: CalDate
    @State private var month: (year: Int, month: Int)
    @State private var editor: EditorRequest?
    @State private var detail: CalOccurrence?
    @AppStorage("CalendarKit.mode") private var mode: CalendarMode = .month

    private let zone = TimeZone.current
    private let firstWeekday = Calendar.current.firstWeekday

    public init(engine: CalendarEngine, appearance: CalendarAppearance = .standard) {
        self.engine = engine
        self.appearance = appearance
        let today = CalDate(Date(), in: .current)
        _selected = State(initialValue: today)
        _month = State(initialValue: (today.year, today.month))
    }


    private var layout: MonthLayout { MonthLayout(year: month.year, month: month.month, firstWeekday: firstWeekday) }
    private var today: CalDate { CalDate(Date(), in: zone) }

    /// Every occurrence in the visible grid, by day. Recomputed when the engine's
    /// data changes (`revision`) or the month does.
    private var byDay: [CalDate: [CalOccurrence]] {
        _ = engine.revision
        let days = layout.weeks.flatMap { $0 }
        return DayIndex.group(engine.occurrences(from: days.first!, through: days.last!, zone: zone),
                              from: days.first!, through: days.last!, zone: zone)
    }

    public var body: some View {
        ZStack {
            CalendarBackdrop(colors: engine.backdropColors)
            VStack(spacing: 12) {
                if let n = engine.notices.last {
                    NoticeBanner(notice: n) { engine.dismissNotice(n) }
                }
                controls
                if engine.calendars.count > 1 { PeopleBar(engine: engine) }
                switch mode {
                case .month: monthContent
                case .agenda:
                    AgendaList(engine: engine, appearance: appearance, zone: zone,
                               showOwners: engine.calendars.filter(\.visible).count > 1) { detail = $0 }
                }
            }
            .padding(.top, 4)
        }
        .calendarAccent(engine.accentColor)
        .sheet(item: $editor) { req in
            NavigationStack { EventEditorView(engine: engine, request: req) }
                .calendarAccent(engine.accentColor)
        }
        .sheet(item: $detail) { o in
            NavigationStack {
                EventDetailView(engine: engine, occurrence: o) { editRequest in
                    detail = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        editor = editRequest
                    }
                }
            }
            .calendarAccent(engine.accentColor)
            .presentationDetents([.medium, .large])
        }
    }

    /// The kit's own control row: Month / Agenda, and "+".
    private var controls: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $mode.animation(.snappy)) {
                Text("Month").tag(CalendarMode.month)
                Text("Agenda").tag(CalendarMode.agenda)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            Spacer()
            Button { editor = .new(mode == .month ? selected : today) } label: {
                Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 22, height: 22)
                    .foregroundStyle(CalOnTint(engine.accentColor))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(appearance.newEvent)
            .disabled(engine.writableCalendars.isEmpty)
            // A fixed-size control: past this, VoiceOver's large content
            // viewer shows it instead of the glyph outgrowing its circle.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer()
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var monthContent: some View {
        let index = byDay
        VStack(spacing: 0) {
            monthHeader
            weekdayHeader
            grid(index)
                .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                    if v.translation.width < -60 { step(1) } else if v.translation.width > 60 { step(-1) }
                })
        }
        .padding(.bottom, 8)
        .calendarCard(cornerRadius: 28)
        .padding(.horizontal, 12)
        // The grid takes the height its chips need; the day's list gets the rest.
        .fixedSize(horizontal: false, vertical: true)
        DayList(day: selected, occurrences: index[selected] ?? [], engine: engine, appearance: appearance,
                showOwners: engine.calendars.filter(\.visible).count > 1) { detail = $0 }
    }

    // MARK: month

    private var monthHeader: some View {
        HStack {
            Text(monthTitle).font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if layout != MonthLayout(year: today.year, month: today.month, firstWeekday: firstWeekday) || selected != today {
                Button("Today") {
                    month = (today.year, today.month)
                    selected = today
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Previous month")
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Next month")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var monthTitle: String {
        CalFormat.template("MMMMyyyy").string(from: CalDate(month.year, month.month, 1).utcMidnight)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(MonthLayout.weekdaySymbols(firstWeekday: firstWeekday).enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func grid(_ index: [CalDate: [CalOccurrence]]) -> some View {
        VStack(spacing: 2) {
            ForEach(layout.weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        let occ = index[day] ?? []
                        DayCell(day: day, inMonth: layout.contains(day), isToday: day == today,
                                isSelected: day == selected, chips: DayChip.chips(occ), eventCount: occ.count)
                            .onTapGesture {
                                selected = day
                                if !layout.contains(day) { month = (day.year, day.month) }
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func step(_ n: Int) {
        let (y, m) = CalRecurrenceExpander.addMonths(month.year, month.month, n)
        withAnimation(.snappy) { month = (y, m) }
        selected = CalDate(y, m, 1) == CalDate(today.year, today.month, 1) ? today : CalDate(y, m, 1)
    }
}

/// The main screen's two views. Remembered on the device.
public enum CalendarMode: String, Sendable {
    case month, agenda
}

/// Everything coming up, from today, grouped by day (empty days skipped),
/// under a strip of the coming week's days. Day headers stay pinned while their
/// events scroll under them; each row leads with its time. Reaches further as
/// you scroll.
struct AgendaList: View {
    let engine: CalendarEngine
    let appearance: CalendarAppearance
    let zone: TimeZone
    let showOwners: Bool
    let open: (CalOccurrence) -> Void
    @State private var days = 60

    private var today: CalDate { CalDate(Date(), in: zone) }

    private var groups: [(CalDate, [CalOccurrence])] {
        _ = engine.revision
        let through = today.adding(days: days - 1)
        let index = DayIndex.group(engine.occurrences(from: today, through: through, zone: zone),
                                   from: today, through: through, zone: zone)
        return index.keys.sorted().map { ($0, index[$0]!) }
    }

    var body: some View {
        let g = groups
        ScrollViewReader { proxy in
            VStack(spacing: 8) {
                WeekStrip(today: today, marks: Dictionary(g.prefix(14).map { ($0.0, Array(Set($0.1.map(\.color))).prefix(3).map { $0 }) },
                                                          uniquingKeysWith: { a, _ in a })) { day in
                    // The first day with something on it, from the one tapped.
                    if let target = g.first(where: { $0.0 >= day })?.0 {
                        withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) }
                    }
                }
                .padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        if g.isEmpty {
                            Text(appearance.emptyAgenda)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .calendarCard(cornerRadius: 20)
                        }
                        ForEach(g, id: \.0) { day, occ in
                            Section {
                                // Keyed by day too: a multi-day event is one occurrence on
                                // several days, and one id twice in a lazy stack drew only
                                // the first (the second day showed a blank gap).
                                ForEach(occ.map { AgendaItem(day: day, occurrence: $0) }) { item in
                                    Button { open(item.occurrence) } label: {
                                        AgendaRow(occurrence: item.occurrence, day: day, engine: engine, showOwner: showOwners)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                AgendaHeader(day: day, today: today).id(day)
                            }
                        }
                        // Reaching the end loads further ahead (up to two years).
                        if days < 730 {
                            Color.clear.frame(height: 1).onAppear { days = min(730, days + 60) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .refreshable { await engine.refresh() }
            }
        }
    }
}

/// An occurrence on one of its days (the agenda's identity for a row).
struct AgendaItem: Identifiable {
    let day: CalDate
    let occurrence: CalOccurrence
    var id: String { "\(day)|\(occurrence.id)" }
}

/// A pinned day header: "Today", "Tomorrow", else the weekday and date, with
/// the date beside the first two so they still say which day.
struct AgendaHeader: View {
    let day: CalDate
    let today: CalDate

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(day == today ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            if let sub {
                Text(sub).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // Pinned over scrolling rows: mostly opaque, so their text doesn't
        // show through the label.
        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.75)))
        .glassEffect(.regular, in: Capsule())
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        switch today.days(to: day) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return CalFormat.template(day.year == today.year ? "EEEEMMMd" : "EEEEMMMdyyyy").string(from: day.utcMidnight)
        }
    }

    private var sub: String? {
        today.days(to: day) <= 1 ? CalFormat.template("EEEMMMd").string(from: day.utcMidnight) : nil
    }
}

/// The next seven days, a day per column: the weekday, the date (today in the accent),
/// and a dot per color with something that day. Tapping a day jumps the
/// agenda to it (or to the next day with something on).
struct WeekStrip: View {
    let today: CalDate
    let marks: [CalDate: [CalColor]]
    let jump: (CalDate) -> Void
    @Environment(\.calendarAccent) private var accent

    /// The coming week, today first: what's ahead is what the agenda is for.
    private var week: [CalDate] { (0..<7).map { today.adding(days: $0) } }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(week, id: \.self) { d in
                Button { jump(d) } label: {
                    VStack(spacing: 4) {
                        Text(WeekdayChips.letter(d.isoWeekday)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        Text("\(d.day)")
                            .font(.subheadline.weight(d == today ? .bold : .regular))
                            .foregroundStyle(d == today ? AnyShapeStyle(CalOnTint(accent)) : AnyShapeStyle(.primary))
                            .frame(width: 30, height: 30)
                            .background { if d == today { Circle().fill(.tint) } }
                        HStack(spacing: 2) {
                            ForEach(Array((marks[d] ?? []).enumerated()), id: \.offset) { _, c in
                                Circle().fill(CalTint(c)).frame(width: 4, height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(DayCell.spoken(d, isToday: d == today, events: marks[d] == nil ? 0 : 1))
            }
        }
        .padding(.vertical, 8)
        .calendarCard(cornerRadius: 22)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// An agenda row: the time first, then the event (Fantastical's reading order).
struct AgendaRow: View {
    let occurrence: CalOccurrence
    let day: CalDate
    let engine: CalendarEngine
    let showOwner: Bool
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 64

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(times.0).font(.subheadline.weight(.medium)).monospacedDigit()
                if let end = times.1 { Text(end).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: min(timeWidth, 96), alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(CalTint(occurrence.color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.title).font(.body.weight(.medium)).lineLimit(2)
                if !occurrence.event.fields.location.isEmpty {
                    Text(occurrence.event.fields.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if occurrence.seriesID != nil {
                Image(systemName: "repeat").font(.caption).foregroundStyle(.tertiary).accessibilityLabel("Repeats")
            }
            if showOwner, let who = AuthorBadge.author(of: occurrence, engine: engine) { who }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .calendarCard(cornerRadius: 20)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Start and end, or "All day" (and which day of several).
    private var times: (String, String?) {
        switch occurrence.when {
        case .allDay(let s, let e):
            let n = s.days(to: e)
            return ("All day", n > 1 ? "\(s.days(to: day) + 1) of \(n)" : nil)
        case .timed(let s, let e, _):
            let f = CalFormat.styles(date: .none, time: .short)
            return (f.string(from: s), s == e ? nil : f.string(from: e))
        }
    }
}

/// Which days each occurrence shows on (in the viewer's zone).
enum DayIndex {
    static func group(_ occ: [CalOccurrence], from: CalDate, through: CalDate, zone: TimeZone) -> [CalDate: [CalOccurrence]] {
        var out: [CalDate: [CalOccurrence]] = [:]
        for o in occ {
            var d: CalDate, last: CalDate
            switch o.when {
            case .allDay(let s, let e):
                d = s
                last = e.adding(days: -1)
            case .timed(let s, let e, _):
                d = CalDate(s, in: zone)
                // An event ending exactly at midnight doesn't spill into the next day.
                let endDay = CalDate(e, in: zone)
                last = e > s && OccurrenceBuilder.start(of: endDay, in: zone) == e ? endDay.adding(days: -1) : endDay
            }
            if d < from { d = from }
            while d <= last && d <= through {
                out[d, default: []].append(o)
                d = d.adding(days: 1)
            }
        }
        return out
    }
}

struct DayCell: View {
    let day: CalDate
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let chips: DayChip.Line
    var eventCount = 0
    @Environment(\.calendarAccent) private var accent
    /// The day's disc grows with Dynamic Type, up to what a seventh of a phone
    /// fits; past that the number shrinks to fit.
    @ScaledMetric(relativeTo: .callout) private var disc: CGFloat = 30
    @ScaledMetric(relativeTo: .caption2) private var chipHeight: CGFloat = 14

    /// Selected today: the accent with black or white on it. Selected another
    /// day: an inverted disc (dark on light, light on dark).
    private var numberStyle: AnyShapeStyle {
        switch (isSelected, isToday) {
        case (true, true): AnyShapeStyle(CalOnTint(accent))
        case (true, false): AnyShapeStyle(Color(uiColor: .systemBackground))
        case (false, true): AnyShapeStyle(.tint)
        case (false, false): inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            Text("\(day.day)")
                .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                .foregroundStyle(numberStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: min(disc, 44), height: min(disc, 44))
                .background {
                    if isSelected { Circle().fill(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(uiColor: .label))) }
                }
            // Two lines of chips, always reserved so every week row is the
            // same height: two titles, or one and "+N".
            VStack(spacing: 2) {
                ForEach(Array(chips.shown.enumerated()), id: \.offset) { _, c in
                    DayChip(chip: c, height: min(chipHeight, 18))
                }
                if chips.more > 0 {
                    Text("+\(chips.more)")
                        .font(.system(size: min(chipHeight, 18) * 0.7, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 3)
                        .frame(height: min(chipHeight, 18))
                }
            }
            .frame(height: min(chipHeight, 18) * 2 + 2, alignment: .top)
            .opacity(inMonth ? 1 : 0.45)
        }
        .padding(.horizontal, 1.5)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DayCell.spoken(day, isToday: isToday, events: eventCount))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension DayCell {
    private static var dayFormatter: DateFormatter { CalFormat.template("EEEEMMMMd") }

    /// What VoiceOver says for a day: "Today, Saturday, November 14, 2 events".
    static func spoken(_ day: CalDate, isToday: Bool, events: Int) -> String {
        var parts: [String] = []
        if isToday { parts.append(String(localized: "Today")) }
        parts.append(dayFormatter.string(from: day.utcMidnight))
        if events == 1 { parts.append(String(localized: "1 event")) }
        else if events > 1 { parts.append(String(localized: "\(events) events")) }
        return parts.joined(separator: ", ")
    }
}

/// An event's title in a month cell, in its color (event, else label, else
/// calendar): tinted capsule, colored text, one line.
struct DayChip: View {
    struct Item: Equatable {
        let title: String
        let color: CalColor
    }
    /// A cell's chips: at most two lines, the second given to "+N" when more.
    struct Line: Equatable {
        var shown: [Item] = []
        var more = 0
    }

    let chip: Item
    let height: CGFloat

    var body: some View {
        Text(chip.title)
            .font(.system(size: height * 0.7, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(CalTint(chip.color))
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: height)
            .background(CalTint(chip.color).opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Two titles, or one and "+N" (the day's occurrences come sorted: all-day
    /// first, then by time).
    static func chips(_ occ: [CalOccurrence]) -> Line {
        let items = occ.map { Item(title: $0.title, color: $0.color) }
        if items.count <= 2 { return Line(shown: items) }
        return Line(shown: [items[0]], more: items.count - 1)
    }
}

struct DayList: View {
    let day: CalDate
    let occurrences: [CalOccurrence]
    let engine: CalendarEngine
    let appearance: CalendarAppearance
    let showOwners: Bool
    let open: (CalOccurrence) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(dayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
                if occurrences.isEmpty {
                    Text(appearance.emptyDay)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .calendarCard(cornerRadius: 20)
                }
                ForEach(occurrences) { o in
                    Button { open(o) } label: {
                        OccurrenceRow(occurrence: o, day: day, engine: engine, showOwner: showOwners)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .calendarCard(cornerRadius: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await engine.refresh() }
    }

    private var dayTitle: String {
        CalFormat.template("EEEEMMMMd").string(from: day.utcMidnight)
    }
}

struct OccurrenceRow: View {
    let occurrence: CalOccurrence
    let day: CalDate
    let engine: CalendarEngine
    let showOwner: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(CalTint(occurrence.color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.title).font(.body.weight(.medium)).lineLimit(2)
                Text(timeText).font(.subheadline).foregroundStyle(.secondary)
                if !occurrence.event.fields.location.isEmpty {
                    Text(occurrence.event.fields.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if occurrence.seriesID != nil {
                Image(systemName: "repeat").font(.caption).foregroundStyle(.tertiary).accessibilityLabel("Repeats")
            }
            if showOwner, let who = AuthorBadge.author(of: occurrence, engine: engine) {
                who
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        switch occurrence.when {
        case .allDay(let s, let e):
            return s.days(to: e) > 1 ? "All day · day \(s.days(to: day) + 1) of \(s.days(to: e))" : "All day"
        case .timed(let s, let e, _):
            let f = CalFormat.styles(date: .none, time: .short)
            if s == e { return f.string(from: s) }
            return "\(f.string(from: s)) – \(f.string(from: e))"
        }
    }
}

/// Who put an event there: its author when that's someone other than the
/// calendar's owner (a partner adding to your calendar), else the owner. Shown
/// when more than one calendar is on screen, so a glance says whose it is;
/// the detail's "Added by" appears exactly when the author isn't the owner.
struct AuthorBadge: View {
    let contact: CalContact?
    let name: String
    let tint: CalColor
    let addedByOther: Bool
    var size: CGFloat = 22

    var body: some View {
        CalAvatar(contact: contact, fallbackName: name, tint: tint, size: size)
            .accessibilityHidden(false)
            .accessibilityLabel(addedByOther ? "Added by \(name)" : name)
    }

    @MainActor
    static func author(of o: CalOccurrence, engine: CalendarEngine, size: CGFloat = 22) -> AuthorBadge? {
        let owner = o.calendar.ownerID
        if o.author != owner {
            let person = engine.people[o.author]
            let theirs = engine.calendars.first { $0.ownerID == o.author }
            let me = o.author == engine.config.currentUserID
            return AuthorBadge(contact: person, name: me ? "My calendar" : (person?.name ?? theirs.map(engine.displayName) ?? "Someone"),
                               tint: theirs?.displayColor ?? .gray, addedByOther: true, size: size)
        }
        return AuthorBadge(contact: engine.owner(of: o.calendar), name: engine.displayName(o.calendar),
                           tint: o.calendar.displayColor, addedByOther: false, size: size)
    }
}

/// One chip per calendar you can see, yours first: tap to show or hide it.
/// The shared-calendar apps' signature: who's on screen, at a glance.
struct PeopleBar: View {
    let engine: CalendarEngine

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(engine.calendars) { c in
                    PersonChip(calendar: c, name: name(c), contact: engine.owner(of: c)) {
                        withAnimation(.snappy) { engine.setVisible(c, !c.visible) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func name(_ c: CalCalendar) -> String {
        if c.isOwn { return "Me" }
        let full = engine.owner(of: c)?.name ?? engine.displayName(c)
        return full.split(separator: " ").first.map(String.init) ?? full
    }
}

struct PersonChip: View {
    let calendar: CalCalendar
    let name: String
    let contact: CalContact?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                CalAvatar(contact: contact, fallbackName: calendar.isOwn ? "My calendar" : name,
                          tint: calendar.displayColor, size: 22)
                    .saturation(calendar.visible ? 1 : 0)
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(calendar.visible ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .strikethrough(!calendar.visible, color: .secondary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(calendar.visible ? AnyShapeStyle(CalTint(calendar.displayColor).opacity(0.18))
                                                : AnyShapeStyle(.quaternary))
            }
            .overlay {
                Capsule().strokeBorder(calendar.visible ? AnyShapeStyle(CalTint(calendar.displayColor).opacity(0.6))
                                                        : AnyShapeStyle(.clear), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendar.isOwn ? "My calendar" : "\(name)'s calendar")
        .accessibilityValue(calendar.visible ? "Shown" : "Hidden")
        .accessibilityHint("Shows or hides it")
        .accessibilityAddTraits(calendar.visible ? .isSelected : [])
    }
}

struct NoticeBanner: View {
    let notice: CalNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(notice.message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .calendarCard(cornerRadius: 18, tint: .orange)
        .padding(.horizontal, 12)
    }
}

/// What the editor sheet is for.
enum EditorRequest: Identifiable {
    case new(CalDate)
    case event(CalEvent)
    case occurrence(CalOccurrence)
    case following(CalOccurrence)

    var id: String {
        switch self {
        case .new(let d): "new-\(d)"
        case .event(let e): "event-\(e.id)"
        case .occurrence(let o): "occ-\(o.id)"
        case .following(let o): "fol-\(o.id)"
        }
    }
}
