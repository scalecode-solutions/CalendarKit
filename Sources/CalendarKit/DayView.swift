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
    /// The pair in focus, if one is: new events go there, rows say who added them.
    let inPair: UUID?
    /// Focused on one person: then + adds only to `inPair`, and with none, nothing.
    let focused: Bool
    /// What's on screen (the pairs, and All / Events / Intimate): the private
    /// sections follow it as the events do.
    let scope: CalScope
    /// The day's occurrences, from the calendar screen, so the day shows
    /// exactly what the grid does.
    let occurrences: (CalDate) -> [CalOccurrence]

    @State private var day: CalDate
    @State private var editor: EditorRequest?
    @State private var detail: CalOccurrence?
    @State private var privateSheet: PrivateSheet?

    init(engine: CalendarEngine, appearance: CalendarAppearance, zone: TimeZone, day: CalDate,
         showOwners: Bool, inPair: UUID? = nil, focused: Bool = false, scope: CalScope = .everyone,
         occurrences: @escaping (CalDate) -> [CalOccurrence]) {
        self.engine = engine
        self.appearance = appearance
        self.zone = zone
        self.showOwners = showOwners
        self.inPair = inPair
        self.focused = focused
        self.scope = scope
        self.occurrences = occurrences
        _day = State(initialValue: day)
    }

    private var today: CalDate { CalDate(Date(), in: zone) }

    /// Something can be added here: a pair that isn't frozen.
    private var canAdd: Bool {
        CalFocus.canAdd(focused: focused, pair: inPair, writable: engine.writableCalendars)
    }

    var body: some View {
        let occ = occurrences(day)
        ZStack {
            CalendarBackdrop(colors: engine.backdropColors)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    PrivateDaySections(engine: engine, day: day, zone: zone, scope: scope) { privateSheet = $0 }
                    if scope.kind.showsEvents { events(occ) }
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
                let intimate = PrivateIndex.intimatePairs(engine: engine, scope: scope).filter { !$0.frozen }
                let cycle = PrivateIndex.cyclePairs(engine: engine, scope: scope).filter { !$0.frozen }
                if intimate.isEmpty && cycle.isEmpty {
                    Button { editor = .new(day, in: inPair) } label: { Image(systemName: "plus") }
                        .accessibilityLabel(appearance.newEvent)
                        .disabled(!canAdd)
                } else {
                    // The private cards show only what the day holds, so +
                    // is where an entry or a period day is added.
                    AddMenu(engine: engine, appearance: appearance, intimate: intimate, cycle: cycle,
                            canAddEvent: canAdd, newEvent: { editor = .new(day, in: inPair) },
                            newPrivate: { privateSheet = .new(day: day, pairs: intimate.map(\.id)) },
                            periodDay: day, label: AnyView(Image(systemName: "plus")))
                }
            }
        }
        .calendarAccent(engine.accentColor)
        .eventSheets(engine: engine, editor: $editor, detail: $detail)
        .privateSheets(engine: engine, sheet: $privateSheet)
        // VoiceOver can't swipe between days; these do the same.
        .accessibilityAction(named: "Previous day") { step(-1) }
        .accessibilityAction(named: "Next day") { step(1) }
    }

    // MARK: sections

    /// Stacked, so nothing is cut at large text sizes: "Tomorrow", the full
    /// date (wrapping, never scaled down), then ‹ … Today … › with the
    /// chevrons at the two ends (they don't move when Today comes and goes).
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let when = relative {
                    Text(when).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                }
                Text(CalFormat.template(day.year == today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy").string(from: day.utcMidnight))
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("dayViewHeader")
            HStack(spacing: 8) {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
                    .cardButton(circle: true)
                    .accessibilityLabel("Previous day")
                Spacer(minLength: 0)
                if day != today {
                    Button { withAnimation(.snappy) { day = today } } label: { Text("Today").frame(minHeight: 32) }
                        .cardButton()
                }
                Spacer(minLength: 0)
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }
                    .cardButton(circle: true)
                    .accessibilityLabel("Next day")
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .calendarCard(cornerRadius: 24)
    }

    @ViewBuilder private func events(_ occ: [CalOccurrence]) -> some View {
        if occ.isEmpty {
            HStack {
                Text(appearance.emptyDay).foregroundStyle(.secondary)
                Spacer()
                Button("Add") { editor = .new(day, in: inPair) }
                    .disabled(!canAdd)
                    .accessibilityLabel(appearance.newEvent)
            }
            .padding(16)
            .calendarCard(cornerRadius: 20)
        } else {
            // Keyed by day too, as in the agenda: one multi-day occurrence is
            // the same id on each of its days.
            ForEach(occ.map { AgendaItem(day: day, occurrence: $0) }) { item in
                Button { detail = item.occurrence } label: {
                    AgendaRow(occurrence: item.occurrence, day: day, engine: engine, showOwner: showOwners,
                              inPair: inPair != nil)
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
