import SwiftUI

/// The calendar: a month grid with a dot per calendar on each day and the
/// selected day's events below, or an agenda of everything coming up. The kit
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
        DayList(day: selected, occurrences: index[selected] ?? [], engine: engine, appearance: appearance,
                showOwners: engine.calendars.filter(\.visible).count > 1) { detail = $0 }
    }

    // MARK: month

    private var monthHeader: some View {
        HStack {
            Text(monthTitle).font(.title2.weight(.semibold))
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
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMMyyyy", options: 0, locale: .current)
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: CalDate(month.year, month.month, 1).utcMidnight)
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
                        DayCell(day: day, inMonth: layout.contains(day), isToday: day == today,
                                isSelected: day == selected, colors: dotColors(index[day] ?? []))
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

    /// One dot per calendar with something that day (at most 3).
    private func dotColors(_ occ: [CalOccurrence]) -> [CalColor] {
        var seen: [UUID] = []
        var out: [CalColor] = []
        for o in occ where !seen.contains(o.calendar.id) {
            seen.append(o.calendar.id)
            out.append(o.calendar.displayColor)
            if out.count == 3 { break }
        }
        return out
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

/// Everything coming up, from today, grouped by day (empty days skipped).
/// Reaches further as you scroll.
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if g.isEmpty {
                    Text(appearance.emptyAgenda)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .calendarCard(cornerRadius: 20)
                }
                ForEach(g, id: \.0) { day, occ in
                    Text(title(day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(day == today ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(occ) { o in
                        Button { open(o) } label: {
                            OccurrenceRow(occurrence: o, day: day, engine: engine, showOwner: showOwners)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .calendarCard(cornerRadius: 20)
                        }
                        .buttonStyle(.plain)
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

    private func title(_ d: CalDate) -> String {
        switch today.days(to: d) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let f = DateFormatter()
            f.timeZone = TimeZone(identifier: "UTC")
            let sameYear = d.year == today.year
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: sameYear ? "EEEEMMMMd" : "EEEEMMMMdyyyy", options: 0, locale: .current)
            return f.string(from: d.utcMidnight)
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
    let colors: [CalColor]
    @Environment(\.calendarAccent) private var accent

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
                .frame(width: 32, height: 32)
                .background {
                    if isSelected { Circle().fill(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(uiColor: .label))) }
                }
            HStack(spacing: 3) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                    Circle().fill(CalTint(c)).frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.description)\(colors.isEmpty ? "" : ", has events")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "EEEEMMMMd", options: 0, locale: .current)
        return f.string(from: day.utcMidnight)
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
            if showOwner {
                CalAvatar(contact: engine.owner(of: occurrence.calendar), fallbackName: engine.displayName(occurrence.calendar),
                          tint: occurrence.calendar.displayColor)
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
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            if s == e { return f.string(from: s) }
            return "\(f.string(from: s)) – \(f.string(from: e))"
        }
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
