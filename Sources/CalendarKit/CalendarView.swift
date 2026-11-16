import SwiftUI

/// The calendar: a month grid with each day's events as colored title chips, or
/// an agenda of everything coming up. Tapping a day (or an agenda day header)
/// pushes that day's view. Above both, a chip per person whose calendar you
/// see, to show or hide it. The kit owns its content (the Month/Agenda switch
/// and "+" sit in it); the HOST owns the navigation bar (title, back, its own
/// buttons) and pushes `CalendarSettingsView` from wherever it likes (e.g. a
/// trailing gear). The host starts and stops the engine.
///
/// **It must sit inside a `NavigationStack`** (the day view is pushed onto it).
/// Without one, tapping a day does nothing. The Lab's UI tests check it.
public struct CalendarView: View {
    @Bindable var engine: CalendarEngine
    let appearance: CalendarAppearance

    @State private var month: (year: Int, month: Int)
    @State private var editor: EditorRequest?
    @State private var detail: CalOccurrence?
    @State private var openDay: CalDate?
    /// What's on screen this visit; where it starts comes from "Opens on".
    @State private var mode: CalendarMode
    /// The last view used, which "Opens on: Last used" reopens.
    @AppStorage(CalendarMode.storageKey) private var savedMode: CalendarMode = .month
    @AppStorage(CalendarOpensOn.storageKey) private var opensOn: CalendarOpensOn = .lastUsed
    /// The host's focus, when it owns it (the picker is hidden then).
    private let hostFocus: Binding<CalFocus>?
    /// The kit's own focus, when the host passes none: remembered per account.
    @State private var ownFocus: CalFocus

    private let zone = TimeZone.current
    private let firstWeekday = Calendar.current.firstWeekday

    /// `focus`: nil (the default) lets the kit own which pairs are on screen,
    /// with its own picker (Everyone, each person, the hidden ones), remembered
    /// per account. A binding hands it to the host and hides the picker: a
    /// conversation passes `.constant(.person(theirID))`.
    public init(engine: CalendarEngine, appearance: CalendarAppearance = .standard, focus: Binding<CalFocus>? = nil) {
        self.engine = engine
        self.appearance = appearance
        self.hostFocus = focus
        let today = CalDate(Date(), in: .current)
        _month = State(initialValue: (today.year, today.month))
        _mode = State(initialValue: CalendarOpensOn.startMode(.standard))
        _ownFocus = State(initialValue: CalFocus(stored: UserDefaults.standard.string(forKey: CalFocus.key(engine.config.currentUserID))))
    }

    private var focus: CalFocus {
        if let hostFocus { return hostFocus.wrappedValue }
        return ownFocus.resolved(in: engine.calendars)
    }

    private func choose(_ f: CalFocus) {
        withAnimation(.snappy) { ownFocus = f }
        UserDefaults.standard.set(f.stored, forKey: CalFocus.key(engine.config.currentUserID))
    }

    /// The pair in focus, if one is (shown even before the server has it).
    private var focusedPair: CalCalendar? {
        guard case .person(let id) = focus else { return nil }
        return engine.pair(with: id)
    }

    /// What the focus puts on screen: one pair (hidden or not) colored by who
    /// added what, or every pair that isn't hidden.
    private var scope: CalScope {
        guard case .person = focus else { return .everyone }
        return CalScope(only: Set(focusedPair.map { [$0.id] } ?? []), byAuthor: true)
    }


    private var layout: MonthLayout { MonthLayout(year: month.year, month: month.month, firstWeekday: firstWeekday) }
    private var today: CalDate { CalDate(Date(), in: zone) }

    /// Every occurrence in the visible grid, by day. Recomputed when the engine's
    /// data changes (`revision`) or the month does.
    private var byDay: [CalDate: [CalOccurrence]] {
        _ = engine.revision
        let days = layout.weeks.flatMap { $0 }
        let s = scope
        return DayIndex.group(engine.occurrences(from: days.first!, through: days.last!, zone: zone,
                                                 only: s.only, byAuthor: s.byAuthor),
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
                if hostFocus == nil && !engine.calendars.isEmpty {
                    PeopleBar(engine: engine, focus: focus, choose: choose)
                }
                if let p = focusedPair, p.frozen || !p.visible { PairStateBanner(engine: engine, pair: p) }
                switch mode {
                case .month: monthContent
                case .agenda:
                    AgendaList(engine: engine, appearance: appearance, zone: zone, scope: scope,
                               showOwners: showOwners, open: { detail = $0 }, openDay: { openDay = $0 })
                }
            }
            .padding(.top, 4)
        }
        .calendarAccent(engine.accentColor)
        .eventSheets(engine: engine, editor: $editor, detail: $detail)
        .navigationDestination(item: $openDay) { day in
            DayView(engine: engine, appearance: appearance, zone: zone, day: day,
                    showOwners: showOwners, inPair: focusedPair?.id, occurrences: dayOccurrences)
        }
        .onChange(of: mode) { _, m in
            // Only "Last used" remembers the switch; a fixed choice lasts for the visit.
            if opensOn == .lastUsed { savedMode = m }
        }
    }

    /// Rows show a badge when it tells something: whose pair (more than one
    /// on screen), or who added it (inside one pair).
    private var showOwners: Bool { scope.byAuthor || engine.calendars.filter(\.visible).count > 1 }

    /// One day's occurrences: the same set the grid draws, so the focus
    /// narrows the day view too, in one place.
    private func dayOccurrences(_ day: CalDate) -> [CalOccurrence] {
        DayIndex.occurrences(on: day, engine: engine, zone: zone, scope: scope)
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
            Button { editor = .new(today, in: focusedPair?.id) } label: {
                Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 22, height: 22)
                    .foregroundStyle(CalOnTint(engine.accentColor))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(appearance.newEvent)
            .disabled(engine.writableCalendars.isEmpty || focusedPair?.frozen == true)
            // A fixed-size control: past this, VoiceOver's large content
            // viewer shows it instead of the glyph outgrowing its circle.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityShowsLargeContentViewer()
        }
        .padding(.horizontal, 16)
    }

    /// The month in a scroll view: at large text sizes on a small phone the
    /// grid is taller than the screen, and pull to refresh lives here.
    private var monthContent: some View {
        let index = byDay
        return ScrollView {
            VStack(spacing: 0) {
                monthHeader
                weekdayHeader
                grid(index)
                    // Simultaneous, and only for a mostly sideways drag, so the
                    // scroll view still scrolls.
                    .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                        if v.translation.width < -60 { step(1) } else if v.translation.width > 60 { step(-1) }
                    })
            }
            .padding(.bottom, 8)
            .calendarCard(cornerRadius: 28)
            .padding(.horizontal, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await engine.refresh() }
    }

    // MARK: month

    private var monthHeader: some View {
        HStack {
            Text(monthTitle).font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if layout != MonthLayout(year: today.year, month: today.month, firstWeekday: firstWeekday) {
                Button("Today") { withAnimation(.snappy) { month = (today.year, today.month) } }
                    .cardButton()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                .cardButton(circle: true)
                .accessibilityLabel("Previous month")
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
                .cardButton(circle: true)
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
                // A faint rule above every week but the first: a day's chips
                // sit at the bottom of its cell, right over the next week's
                // numbers, and without it they read as the next week's.
                if week.first != layout.weeks.first?.first { WeekRule() }
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        let occ = index[day] ?? []
                        Button { openDay = day } label: {
                            DayCell(day: day, inMonth: layout.contains(day), isToday: day == today,
                                    chips: DayChip.chips(occ), eventCount: occ.count)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(DayCell.spoken(day, isToday: day == today, events: occ.count))
                        .accessibilityHint("Opens the day")
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func step(_ n: Int) {
        let (y, m) = CalRecurrenceExpander.addMonths(month.year, month.month, n)
        withAnimation(.snappy) { month = (y, m) }
    }
}

/// The main screen's two views. The last one used is remembered on the device.
public enum CalendarMode: String, Sendable {
    case month, agenda

    static let storageKey = "CalendarKit.mode"
}

/// Where the calendar opens: the view used last (the default), or always the
/// month or the agenda. Stored on the device.
enum CalendarOpensOn: String, CaseIterable, Sendable {
    case lastUsed, month, agenda

    static let storageKey = "CalendarKit.opensOn"

    var title: String {
        switch self {
        case .lastUsed: "Last used"
        case .month: "Month"
        case .agenda: "Agenda"
        }
    }

    /// The view a fresh calendar screen starts on.
    static func startMode(_ defaults: UserDefaults) -> CalendarMode {
        switch CalendarOpensOn(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .lastUsed {
        case .lastUsed: CalendarMode(rawValue: defaults.string(forKey: CalendarMode.storageKey) ?? "") ?? .month
        case .month: .month
        case .agenda: .agenda
        }
    }
}

/// Everything coming up, from today, grouped by day (empty days skipped),
/// under a strip of the coming week's days. Day headers stay pinned while their
/// events scroll under them; each row leads with its time. Reaches further as
/// you scroll.
struct AgendaList: View {
    let engine: CalendarEngine
    let appearance: CalendarAppearance
    let zone: TimeZone
    let scope: CalScope
    let showOwners: Bool
    let open: (CalOccurrence) -> Void
    /// A day header was tapped: open that day.
    let openDay: (CalDate) -> Void
    @State private var days = 60

    private var today: CalDate { CalDate(Date(), in: zone) }

    private var groups: [(CalDate, [CalOccurrence])] {
        _ = engine.revision
        let through = today.adding(days: days - 1)
        let index = DayIndex.group(engine.occurrences(from: today, through: through, zone: zone,
                                                      only: scope.only, byAuthor: scope.byAuthor),
                                   from: today, through: through, zone: zone)
        return index.keys.sorted().map { ($0, index[$0]!) }
    }

    var body: some View {
        let g = groups
        ScrollViewReader { proxy in
            VStack(spacing: 8) {
                WeekStrip(today: today, marks: Dictionary(g.prefix(14).map { ($0.0, WeekStrip.dots($0.1)) },
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
                                        AgendaRow(occurrence: item.occurrence, day: day, engine: engine, showOwner: showOwners,
                                                  inPair: scope.byAuthor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Button { openDay(day) } label: { AgendaHeader(day: day, today: today) }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityHint("Opens the day")
                                    .accessibilityIdentifier("agendaDayHeader")
                                    .id(day)
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
        .glassEffect(.regular, in: Capsule())
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Pinned over scrolling rows: a band across the whole column, solid
        // behind the label and fading out below it, so rows pass cleanly
        // under the header instead of showing beside a narrow capsule.
        .background {
            Rectangle().fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.75),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, -12)
                .padding(.bottom, -8)
        }
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

    /// A day's dots: its colors in the order its events come, each once, at
    /// most three (stable from one render to the next).
    static func dots(_ occ: [CalOccurrence]) -> [CalColor] {
        var out: [CalColor] = []
        for o in occ where !out.contains(o.color) {
            out.append(o.color)
            if out.count == 3 { break }
        }
        return out
    }

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
    var inPair = false
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
            if showOwner, let who = AuthorBadge.author(of: occurrence, engine: engine, inPair: inPair) { who }
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
    /// One day's occurrences, everything that touches it (a multi-day or
    /// all-day event shows on each of its days), in the order the grid uses.
    @MainActor
    static func occurrences(on day: CalDate, engine: CalendarEngine, zone: TimeZone, scope: CalScope = .everyone) -> [CalOccurrence] {
        _ = engine.revision
        return group(engine.occurrences(from: day, through: day, zone: zone, only: scope.only, byAuthor: scope.byAuthor),
                     from: day, through: day, zone: zone)[day] ?? []
    }

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

/// The hairline between two weeks of the month grid, in the system's
/// separator color (it adapts to light and dark), one pixel high.
struct WeekRule: View {
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / scale)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .accessibilityHidden(true)
    }
}

struct DayCell: View {
    let day: CalDate
    let inMonth: Bool
    let isToday: Bool
    let chips: DayChip.Line
    var eventCount = 0
    @Environment(\.calendarAccent) private var accent
    /// The day's disc grows with Dynamic Type, up to what a seventh of a phone
    /// fits; past that the number shrinks to fit.
    @ScaledMetric(relativeTo: .callout) private var disc: CGFloat = 30
    @ScaledMetric(relativeTo: .caption2) private var chipHeight: CGFloat = 14

    /// Today: the accent with black or white on it. Other days: plain,
    /// dimmed outside the month.
    private var numberStyle: AnyShapeStyle {
        if isToday { return AnyShapeStyle(CalOnTint(accent)) }
        return inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }

    var body: some View {
        VStack(spacing: 3) {
            Text("\(day.day)")
                .font(.callout.weight(isToday ? .semibold : .regular))
                .foregroundStyle(numberStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: min(disc, 44), height: min(disc, 44))
                .background {
                    if isToday { Circle().fill(.tint) }
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
        .accessibilityAddTraits(.isButton)
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

    /// Across every pair: whose pair it's on (the other person). Inside one
    /// pair: who added it (you, or them).
    @MainActor
    static func author(of o: CalOccurrence, engine: CalendarEngine, inPair: Bool = false, size: CGFloat = 22) -> AuthorBadge? {
        let me = engine.config.currentUserID
        guard inPair else {
            return AuthorBadge(contact: engine.person(of: o.calendar), name: engine.displayName(o.calendar),
                               tint: o.calendar.displayColor, addedByOther: false, size: size)
        }
        if o.author == me {
            return AuthorBadge(contact: engine.people[me], name: "you", tint: engine.accentColor, addedByOther: true, size: size)
        }
        return AuthorBadge(contact: engine.people[o.author], name: engine.displayName(o.calendar),
                           tint: o.calendar.displayColor, addedByOther: true, size: size)
    }
}

/// Which pairs are on screen: all of them, or one person's. Local to this
/// screen (and remembered on the device per account when the kit owns it);
/// it never changes the synced show/hide prefs.
public enum CalFocus: Hashable, Sendable {
    /// Every pair that isn't hidden.
    case everyone
    /// The pair with this person, hidden or not.
    case person(UUID)

    var stored: String {
        switch self {
        case .everyone: "everyone"
        case .person(let id): id.uuidString
        }
    }

    init(stored: String?) {
        self = stored.flatMap(UUID.init(uuidString:)).map(CalFocus.person) ?? .everyone
    }

    static func key(_ user: UUID) -> String { "CalendarKit.focus.\(user.uuidString)" }

    /// The kit's remembered focus, against the pairs there are now: a person
    /// with no pair any more (no longer a friend) is Everyone, rather than an
    /// empty calendar with nothing selected. Nothing loaded yet keeps it; so
    /// does the stored value, so it comes back if they do.
    func resolved(in calendars: [CalCalendar]) -> CalFocus {
        guard case .person(let id) = self, !calendars.isEmpty, !calendars.contains(where: { $0.otherID == id }) else { return self }
        return .everyone
    }
}

/// What a focus puts on screen.
struct CalScope: Equatable {
    /// nil: every pair that isn't hidden. Else these pairs, hidden or not.
    var only: Set<UUID>?
    /// Inside one pair: color and badge rows by who added them.
    var byAuthor: Bool

    static let everyone = CalScope(only: nil, byAuthor: false)
}

/// The focus picker the kit shows when it owns the focus: Everyone, then a
/// chip per shown pair, then the hidden ones in a menu.
struct PeopleBar: View {
    let engine: CalendarEngine
    let focus: CalFocus
    let choose: (CalFocus) -> Void

    private var shown: [CalCalendar] { engine.calendars.filter(\.visible) }
    private var hidden: [CalCalendar] { engine.calendars.filter { !$0.visible } }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                FocusChip(title: "Everyone", contact: nil, tint: engine.accentColor, selected: focus == .everyone,
                          systemImage: "person.2.fill") { choose(.everyone) }
                ForEach(shown) { c in
                    FocusChip(title: firstName(c), contact: engine.person(of: c), tint: c.displayColor,
                              selected: focus == .person(c.otherID)) { choose(.person(c.otherID)) }
                }
                if !hidden.isEmpty {
                    Menu {
                        ForEach(hidden) { c in
                            Button(engine.displayName(c)) { choose(.person(c.otherID)) }
                        }
                    } label: {
                        Text("Hidden (\(hidden.count))")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background { Capsule().fill(.quaternary) }
                    }
                    .accessibilityLabel("Hidden calendars, \(hidden.count)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func firstName(_ c: CalCalendar) -> String {
        let full = engine.displayName(c)
        return full.split(separator: " ").first.map(String.init) ?? full
    }
}

struct FocusChip: View {
    let title: String
    let contact: CalContact?
    let tint: CalColor
    let selected: Bool
    var systemImage: String? = nil
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(CalOnTint(tint))
                        .background { Circle().fill(CalTint(tint)) }
                } else {
                    CalAvatar(contact: contact, fallbackName: title, tint: tint, size: 22)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(selected ? AnyShapeStyle(CalTint(tint).opacity(0.18)) : AnyShapeStyle(.quaternary))
            }
            .overlay {
                Capsule().strokeBorder(selected ? AnyShapeStyle(CalTint(tint).opacity(0.6)) : AnyShapeStyle(.clear), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Everyone" ? "Everyone" : "\(title)'s calendar")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Over a focused pair that's hidden or frozen: says so, and for a hidden
/// one offers to show it again.
struct PairStateBanner: View {
    let engine: CalendarEngine
    let pair: CalCalendar

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: pair.frozen ? "lock.fill" : "eye.slash").foregroundStyle(.secondary)
            Text(pair.frozen ? "You two aren't friends any more, so this calendar is read-only."
                             : "You hid this calendar.")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !pair.visible {
                Button("Show it again") { engine.setHidden(pair, false) }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(12)
        .calendarCard(cornerRadius: 18)
        .padding(.horizontal, 12)
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

/// The editor and an event's detail, as sheets. The detail's Edit closes the
/// detail and opens the editor once it has gone, so there's one sheet at a
/// time. Shared by the calendar and the day view, so each owns its sheets.
struct EventSheets: ViewModifier {
    let engine: CalendarEngine
    @Binding var editor: EditorRequest?
    @Binding var detail: CalOccurrence?

    func body(content: Content) -> some View {
        content
            .sheet(item: $editor) { req in
                NavigationStack { EventEditorView(engine: engine, request: req) }
                    .calendarAccent(engine.accentColor)
            }
            .sheet(item: $detail) { o in
                NavigationStack {
                    EventDetailView(engine: engine, occurrence: o) { editRequest in
                        detail = nil
                        let editor = $editor
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            editor.wrappedValue = editRequest
                        }
                    }
                }
                .calendarAccent(engine.accentColor)
                .presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func eventSheets(engine: CalendarEngine, editor: Binding<EditorRequest?>, detail: Binding<CalOccurrence?>) -> some View {
        modifier(EventSheets(engine: engine, editor: editor, detail: detail))
    }

    /// A small button on a glass card (the month arrows, Today). Glass on
    /// glass renders nearly invisible on iOS 26, so there it's a plain filled
    /// shape instead; iOS 27 draws the glass button properly.
    @ViewBuilder func cardButton(circle: Bool = false) -> some View {
        if #available(iOS 27.0, *) {
            if circle {
                buttonStyle(.glass).buttonBorderShape(.circle)
            } else {
                buttonStyle(.glass).controlSize(.small)
            }
        } else {
            buttonStyle(FilledCardButtonStyle(circle: circle))
        }
    }
}

/// iOS 26's stand-in for a glass button on a glass card: a filled circle or
/// capsule in the system's fill color, dimmed while pressed.
struct FilledCardButtonStyle: ButtonStyle {
    let circle: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(circle ? .body.weight(.semibold) : .subheadline.weight(.medium))
            .foregroundStyle(.tint)
            .padding(circle ? 8 : 0)
            .padding(.horizontal, circle ? 0 : 12)
            .padding(.vertical, circle ? 0 : 6)
            .background {
                if circle { Circle().fill(Color(uiColor: .tertiarySystemFill)) }
                else { Capsule().fill(Color(uiColor: .tertiarySystemFill)) }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(circle ? AnyShape(Circle()) : AnyShape(Capsule()))
    }
}

/// What the editor sheet is for.
enum EditorRequest: Identifiable {
    /// A new event on a day, in a pair when one is in focus.
    case new(CalDate, in: UUID? = nil)
    case event(CalEvent)
    case occurrence(CalOccurrence)
    case following(CalOccurrence)

    var id: String {
        switch self {
        case .new(let d, let c): "new-\(d)-\(c?.uuidString ?? "")"
        case .event(let e): "event-\(e.id)"
        case .occurrence(let o): "occ-\(o.id)"
        case .following(let o): "fol-\(o.id)"
        }
    }
}
