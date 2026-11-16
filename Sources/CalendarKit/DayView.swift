import SwiftUI

/// One day, agenda style: pushed when a day is tapped in the month or an
/// agenda day header is. Each row leads with its time. The previous and next
/// day are a chevron or a sideways swipe away, and Today comes back. `+` adds
/// to the day shown. Built as plain sections (the day's header, then its
/// events), so more kinds of entry can become sections of their own.
struct DayView: View {
    @Bindable var engine: CalendarEngine
    let appearance: CalendarAppearance
    let zone: TimeZone
    let showOwners: Bool
    /// The day's occurrences, from the calendar screen, so the day shows
    /// exactly what the grid does.
    let occurrences: (CalDate) -> [CalOccurrence]

    @State private var day: CalDate
    @State private var editor: EditorRequest?
    @State private var detail: CalOccurrence?

    init(engine: CalendarEngine, appearance: CalendarAppearance, zone: TimeZone, day: CalDate,
         showOwners: Bool, occurrences: @escaping (CalDate) -> [CalOccurrence]) {
        self.engine = engine
        self.appearance = appearance
        self.zone = zone
        self.showOwners = showOwners
        self.occurrences = occurrences
        _day = State(initialValue: day)
    }

    private var today: CalDate { CalDate(Date(), in: zone) }

    var body: some View {
        let occ = occurrences(day)
        ZStack {
            CalendarBackdrop(colors: engine.backdropColors)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    events(occ)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .refreshable { await engine.refresh() }
            .simultaneousGesture(swipe)
        }
        .navigationTitle(CalFormat.template("EEEMMMd").string(from: day.utcMidnight))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .new(day) } label: { Image(systemName: "plus") }
                    .accessibilityLabel(appearance.newEvent)
                    .disabled(engine.writableCalendars.isEmpty)
            }
        }
        .calendarAccent(engine.accentColor)
        .eventSheets(engine: engine, editor: $editor, detail: $detail)
        // VoiceOver can't swipe between days; these do the same.
        .accessibilityAction(named: "Previous day") { step(-1) }
        .accessibilityAction(named: "Next day") { step(1) }
    }

    // MARK: sections

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let when = relative {
                    Text(when).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                }
                Text(CalFormat.template(day.year == today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy").string(from: day.utcMidnight))
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("dayViewHeader")
            Spacer(minLength: 4)
            if day != today {
                Button("Today") { withAnimation(.snappy) { day = today } }
                    .cardButton()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                .cardButton(circle: true)
                .accessibilityLabel("Previous day")
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
                .cardButton(circle: true)
                .accessibilityLabel("Next day")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .calendarCard(cornerRadius: 24)
    }

    @ViewBuilder private func events(_ occ: [CalOccurrence]) -> some View {
        if occ.isEmpty {
            HStack {
                Text(appearance.emptyDay).foregroundStyle(.secondary)
                Spacer()
                Button("Add") { editor = .new(day) }
                    .disabled(engine.writableCalendars.isEmpty)
                    .accessibilityLabel(appearance.newEvent)
            }
            .padding(16)
            .calendarCard(cornerRadius: 20)
        } else {
            // Keyed by day too, as in the agenda: one multi-day occurrence is
            // the same id on each of its days.
            ForEach(occ.map { AgendaItem(day: day, occurrence: $0) }) { item in
                Button { detail = item.occurrence } label: {
                    AgendaRow(occurrence: item.occurrence, day: day, engine: engine, showOwner: showOwners)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: moving between days

    /// "Today", "Tomorrow" or "Yesterday" over the date, when it's one of those.
    private var relative: String? {
        switch today.days(to: day) {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: nil
        }
    }

    private func step(_ n: Int) {
        withAnimation(.snappy) { day = day.adding(days: n) }
    }

    /// A sideways swipe moves a day. Drags that start at the leading edge are
    /// left to the system's swipe back, and mostly vertical ones to scrolling.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .global).onEnded { v in
            guard v.startLocation.x > 24, abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            if v.translation.width < -60 { step(1) } else if v.translation.width > 60 { step(-1) }
        }
    }
}
