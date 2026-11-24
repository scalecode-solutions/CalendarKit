import SwiftUI

// The screens for intimate entries and cycle (0.8.0 design sprint, MVCALE-26
// and MVCALE-28; it stays in the kit, as decided in
// MVCALE-23 step 14). Kept in their own files: the rest of the kit reaches
// them through two hooks, `CalScope.kind` and the day view's sections.

/// What the grid, the agenda and the day view show (plan decision 20).
enum CalKind: String, CaseIterable, Sendable {
    case all, events, intimate

    static let storageKey = "CalendarKit.kind"

    var title: String {
        switch self {
        case .all: "All"
        case .events: "Events"
        case .intimate: "Intimate"
        }
    }

    var showsEvents: Bool { self != .intimate }
    var showsPrivate: Bool { self != .events }
}

// MARK: the month grid

/// One day's private marks: a heart per author, and the strongest cycle mark.
struct PrivateMarks: Equatable {
    var hearts: [CalHeart] = []
    var cycle: CalCycleDayInfo.Kind?

    var isEmpty: Bool { hearts.isEmpty && cycle == nil }

    /// What VoiceOver adds to a day: "1 private entry, period".
    var spoken: [String] {
        var parts: [String] = []
        let n = hearts.reduce(0) { $0 + $1.count }
        if n == 1 { parts.append("1 private entry") } else if n > 1 { parts.append("\(n) private entries") }
        if let cycle { parts.append(PrivateMarks.spoken(cycle)) }
        return parts
    }

    static func spoken(_ k: CalCycleDayInfo.Kind) -> String {
        switch k {
        case .logged(.spotting): "spotting"
        case .logged, .inPeriod: "period"
        case .predictedPeriod: "period expected"
        case .fertile(ovulation: true): "ovulation expected"
        case .fertile: "fertile window"
        case .fertilePossible: "fertility possible"
        }
    }

    /// Which cycle mark wins a day when more than one person's falls on it:
    /// logged, then expected period, then ovulation, then the window, then
    /// the faint "fertility possible" band, which never hides another.
    static func rank(_ k: CalCycleDayInfo.Kind) -> Int {
        switch k {
        case .logged, .inPeriod: 5
        case .predictedPeriod: 4
        case .fertile(ovulation: true): 3
        case .fertile: 2
        case .fertilePossible: 1
        }
    }
}

@MainActor
enum PrivateIndex {
    /// The marks for a run of days, for the pairs the scope shows (consented
    /// pairs only: the engine returns nothing else).
    static func marks(engine: CalendarEngine, from: CalDate, through: CalDate, zone: TimeZone,
                      scope: CalScope) -> [CalDate: PrivateMarks] {
        let today = CalDate(Date(), in: zone)
        _ = engine.revision
        guard scope.kind.showsPrivate else { return [:] }
        var out: [CalDate: PrivateMarks] = [:]
        let entries = engine.privateEntries(from: from, through: through, zone: zone, only: scope.only)
        for (day, es) in Dictionary(grouping: entries, by: { $0.day(in: zone) }) {
            out[day, default: PrivateMarks()].hearts = engine.hearts(es)
        }
        for c in cyclePairs(engine: engine, scope: scope) {
            for person in engine.cyclePeople(in: c) {
                guard let est = engine.cycle(of: person, in: c) else { continue }
                var d = from
                while d <= through {
                    if let k = est.info(on: d, today: today).kind {
                        let old = out[d]?.cycle
                        if old.map({ PrivateMarks.rank($0) < PrivateMarks.rank(k) }) ?? true {
                            out[d, default: PrivateMarks()].cycle = k
                        }
                    }
                    d = d.adding(days: 1)
                }
            }
        }
        return out
    }

    /// The pairs on screen that track cycles (both turned it on).
    static func cyclePairs(engine: CalendarEngine, scope: CalScope) -> [CalCalendar] {
        engine.calendars.filter { c in c.cycleOn && (scope.only.map { $0.contains(c.id) } ?? c.visible) }
    }

    /// The pairs on screen with intimate entries on.
    static func intimatePairs(engine: CalendarEngine, scope: CalScope) -> [CalCalendar] {
        engine.calendars.filter { c in c.intimateOn && (scope.only.map { $0.contains(c.id) } ?? c.visible) }
    }
}

/// The cycle's band behind a day's number (plan decision 11): a filled tint
/// for logged days, a lighter one for expected ones, teal for the fertile
/// window, stronger on ovulation. Full width, so a run of days reads as one
/// band across the week.
struct CycleBand: View {
    let kind: CalCycleDayInfo.Kind
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme

    static let period = Color.pink
    static let fertile = Color.teal

    var body: some View {
        Rectangle()
            .fill(fill)
            .overlay {
                // Expected: dashed edges above and below only, so a run of
                // days reads as one band, not a row of boxes.
                if case .predictedPeriod = kind {
                    VStack {
                        DashedRule()
                        Spacer(minLength: 0)
                        DashedRule()
                    }
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch kind {
        case .logged(.spotting): CycleBand.period.opacity(0.14)
        case .logged, .inPeriod: CycleBand.period.opacity(0.32)
        case .predictedPeriod: CycleBand.period.opacity(0.08)
        case .fertile(ovulation: true): CycleBand.fertile.opacity(0.34)
        case .fertile: CycleBand.fertile.opacity(0.16)
        // About half the window's teal, no dashes (the dashes mean
        // "expected period"): MVCALE-127 step 5, picked by eye in light and
        // dark (dark needs a little more to show at all).
        case .fertilePossible: CycleBand.fertile.opacity(scheme == .dark ? 0.11 : 0.08)
        }
    }
}

/// A dashed hairline the width of its frame (an expected period's edges).
struct DashedRule: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: g.size.width, y: 0.5))
            }
            .stroke(CycleBand.period.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
        .frame(height: 1)
    }
}

/// A day's marks in the strip above its number (plan decisions 6 and 9,
/// MVCALE-50): a period drop and a heart per author. At most two marks fit
/// a cell at the largest text sizes (a mark with its halo is about 19pt of
/// a 40pt cell), so: one mark centered; two at the sides, the drop leading;
/// and a drop with two authors' hearts shows the drop and one heart holding
/// the day's total, in the color of whoever logged more (the viewer's on a
/// tie). VoiceOver still says every count (PrivateMarks.spoken).
struct DayMarks: View {
    let hearts: [CalHeart]
    let cycle: CalCycleDayInfo.Kind?
    let me: UUID
    let size: CGFloat

    var body: some View {
        let drop = DropMark.kind(cycle)
        let shown = DayMarks.hearts(hearts, besideADrop: drop != nil, me: me)
        HStack(alignment: .top, spacing: 0) {
            switch (drop, shown.count) {
            case (nil, 0):
                EmptyView()
            case (nil, 1):
                HeartMark(heart: shown[0], size: size).frame(maxWidth: .infinity)
            case (nil, _):
                HeartMark(heart: shown[0], size: size)
                Spacer(minLength: 0)
                HeartMark(heart: shown[1], size: size)
            case (let d?, 0):
                DropMark(kind: d, size: size).frame(maxWidth: .infinity)
            case (let d?, _):
                DropMark(kind: d, size: size)
                Spacer(minLength: 0)
                HeartMark(heart: shown[0], size: size)
            }
        }
        .accessibilityHidden(true)
    }

    /// The hearts that fit: all of them (at most two authors in a pair), or
    /// beside a drop, one holding the day's total.
    static func hearts(_ hearts: [CalHeart], besideADrop: Bool, me: UUID) -> [CalHeart] {
        guard besideADrop, hearts.count > 1 else { return hearts }
        let lead = hearts.max { a, b in
            a.count != b.count ? a.count < b.count : (a.author == me ? 0 : 1) > (b.author == me ? 0 : 1)
        }!
        return [CalHeart(author: lead.author, color: lead.color, count: hearts.reduce(0) { $0 + $1.count },
                         hollow: hearts.allSatisfy(\.hollow))]
    }
}

/// A period drop (design review, MVCALE-50): filled for a logged day (fainter for
/// spotting), outlined for an expected one, with the hearts' halo.
struct DropMark: View {
    enum Kind: Equatable { case logged, spotting, expected }
    let kind: Kind
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    static func kind(_ k: CalCycleDayInfo.Kind?) -> Kind? {
        switch k {
        case .logged(.spotting): .spotting
        case .logged, .inPeriod: .logged
        case .predictedPeriod: .expected
        default: nil
        }
    }

    var body: some View {
        ZStack {
            Image(systemName: "drop.fill")
                .font(.system(size: size * 1.3, weight: .black))
                .foregroundStyle(Color(uiColor: .systemBackground).opacity(scheme == .dark ? 0.8 : 1))
            Image(systemName: kind == .expected ? "drop" : "drop.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(CycleBand.period.opacity(kind == .spotting ? 0.5 : 1))
        }
    }
}

struct HeartMark: View {
    let heart: CalHeart
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Image(systemName: "heart.fill")
                .font(.system(size: size * 1.3, weight: .black))
                .foregroundStyle(Color(uiColor: .systemBackground).opacity(scheme == .dark ? 0.8 : 1))
            Image(systemName: heart.hollow ? "heart" : "heart.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(CalTint(heart.color))
            if heart.count > 1 {
                Text("\(heart.count)")
                    .font(.system(size: size * 0.6, weight: .heavy))
                    .foregroundStyle(heart.hollow ? AnyShapeStyle(CalTint(heart.color)) : AnyShapeStyle(CalOnTint(heart.color)))
                    .offset(y: -size * 0.05)
            }
        }
    }
}

// MARK: the + menu

/// What + offers, when a pair on screen has intimate entries or cycle on.
struct AddMenu: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let appearance: CalendarAppearance
    /// The pairs + may add private things to (writable, consented, in scope).
    let intimate: [CalCalendar]
    let cycle: [CalCalendar]
    let canAddEvent: Bool
    let newEvent: () -> Void
    let newPrivate: () -> Void
    /// The day "Log period" writes to (today on the month, the day shown in
    /// the day view); nil leaves it out.
    let periodDay: CalDate?
    let label: AnyView

    private var me: UUID { engine.config.currentUserID }

    var body: some View {
        Menu {
            Button(action: newEvent) { Label("Event", systemImage: "calendar") }
                .disabled(!canAddEvent)
            if !intimate.isEmpty {
                Button(action: newPrivate) { Label("Intimate", systemImage: "heart") }
                if intimate.count == 1 {
                    Button { engine.quickLog(in: intimate[0]) } label: { Label("Quick log", systemImage: "bolt.heart") }
                } else {
                    Menu {
                        ForEach(intimate) { c in Button(engine.displayName(c, host: host)) { engine.quickLog(in: c) } }
                    } label: { Label("Quick log", systemImage: "bolt.heart") }
                }
            }
            if let periodDay, !cycle.isEmpty {
                // pair (when more than one) → whose → flow. Either member may
                // log for either; picking a flow writes the day.
                Menu {
                    if cycle.count == 1 {
                        periodPeople(cycle[0], periodDay)
                    } else {
                        ForEach(cycle) { c in Menu(engine.displayName(c, host: host)) { periodPeople(c, periodDay) } }
                    }
                } label: { Label("Log period", systemImage: "drop") }
                .accessibilityIdentifier("logPeriodMenu")
            }
        } label: { label }
        .accessibilityLabel("Add")
        .accessibilityIdentifier("addMenu")
    }

    @ViewBuilder private func periodPeople(_ pair: CalCalendar, _ day: CalDate) -> some View {
        // Only whoever tracks their cycle here (MVCALE-51).
        ForEach(engine.cyclePeople(in: pair), id: \.self) { person in
            Menu(person == me ? "You" : engine.personName(person, in: pair, host: host)) {
                CycleFlowButtons(engine: engine, pair: pair, person: person, day: day)
            }
        }
    }
}

/// Period started (or ended, inside an open period), then Spotting · Light ·
/// Medium · Heavy for one person on one day, the current ones checked, and
/// No flow to take the flow back (the marks stay).
struct CycleFlowButtons: View {
    let engine: CalendarEngine
    let pair: CalCalendar
    let person: UUID
    let day: CalDate

    var body: some View {
        let est = engine.cycle(of: person, in: pair)
        let current = est?.days.last { $0.date == day }
        let info = est?.info(on: day, today: CalDate(Date(), in: .current))
        // The two taps a period (MVCALE-52); the flow below is optional.
        // Started: on any day not inside an open period (or already its start).
        if info?.openPeriod == nil || current?.starts == true {
            Button {
                engine.markPeriodStart(in: pair, for: person, on: day, !(current?.starts ?? false))
            } label: {
                if current?.starts == true { Label("Period started", systemImage: "checkmark") } else { Text("Period started") }
            }
        }
        // Ended: inside an open period (or already its end).
        if info?.openPeriod != nil || current?.ends == true {
            Button {
                engine.markPeriodEnd(in: pair, for: person, on: day, !(current?.ends ?? false))
            } label: {
                if current?.ends == true { Label("Period ended", systemImage: "checkmark") } else { Text("Period ended") }
            }
        }
        ForEach(CalFlow.allCases, id: \.self) { f in
            Button {
                engine.logCycleDay(in: pair, for: person, on: day, flow: f)
            } label: {
                if current?.flow == f { Label(f.title, systemImage: "checkmark") } else { Text(f.title) }
            }
        }
        if current?.flow != nil {
            Button("No flow", role: .destructive) { engine.clearCycleFlow(in: pair, for: person, on: day) }
        }
    }
}

// MARK: the day view's sections

/// The day view's Intimate and Cycle sections, between its header and its
/// events (plan decision 7).
struct PrivateDaySections: View {
    let engine: CalendarEngine
    let day: CalDate
    let zone: TimeZone
    let scope: CalScope
    let open: (PrivateSheet) -> Void

    var body: some View {
        let intimate = PrivateIndex.intimatePairs(engine: engine, scope: scope)
        let cycle = PrivateIndex.cyclePairs(engine: engine, scope: scope)
        // Only what the day holds: an empty day shows neither card, and +
        // adds (design review, 2026-11-16).
        if scope.kind.showsPrivate {
            let entries = intimate.isEmpty ? [] : engine.privateEntries(from: day, through: day, zone: zone, only: scope.only)
            if !entries.isEmpty { intimateSection(entries) }
            ForEach(cycle.filter { CycleDaySection.hasSomething(engine: engine, pair: $0, day: day) }) { c in
                CycleDaySection(engine: engine, pair: c, day: day)
            }
        }
    }

    private func intimateSection(_ entries: [CalPrivateEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Intimate", systemImage: "heart.fill")
                .font(.headline)
                .foregroundStyle(CycleBand.period)
                .accessibilityAddTraits(.isHeader)
            ForEach(entries) { e in
                Button { open(.edit(e)) } label: { PrivateEntryRow(engine: engine, entry: e, zone: zone) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("privateEntryRow")
            }
        }
        .padding(16)
        .calendarCard(cornerRadius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intimateSection")
    }
}

/// One intimate entry in a list, stacked like 0.7.2's rows: its time, then
/// who, then a few details. VoiceOver says only "Private entry" and the time
/// (plan decision 21); the details are one tap away.
struct PrivateEntryRow: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let entry: CalPrivateEntry
    let zone: TimeZone

    private var heart: CalHeart? { engine.hearts([entry]).first }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.content.needsWho ? "heart" : "heart.fill")
                .font(.body.weight(.bold))
                .foregroundStyle(CalTint(heart?.color ?? .pink))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(time).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(who).font(.body.weight(.medium))
                    .foregroundStyle(entry.content.needsWho ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let more = details { Text(more).font(.subheadline).foregroundStyle(.secondary) }
                if entry.createdBy != engine.config.currentUserID {
                    Text("Added by \(addedBy)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Private entry, \(time)")
        .accessibilityHint("Opens it")
    }

    private var time: String {
        let f = CalFormat.template("jmm", zone: TimeZone(identifier: entry.content.timeZone) ?? zone)
        return f.string(from: entry.content.at)
    }

    private var who: String {
        let c = entry.content
        if c.solo { return "Solo" }
        if c.needsWho { return "Who? Add the details" }
        let names = engine.partners(of: engine.calendar(entry.calendarID) ?? .placeholder(entry.calendarID))
        return PrivateEntryRow.names(c.partnerIDs, partners: names)
    }

    /// "Jordan", or for an older entry naming several, "Jordan +1".
    static func names(_ ids: [UUID], partners: [CalPartner]) -> String {
        let byID = Dictionary(partners.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        guard let first = ids.first else { return "Someone" }
        let name = byID[first] ?? "Someone"
        return ids.count > 1 ? "\(name) +\(ids.count - 1)" : name
    }

    private var details: String? {
        let c = entry.content
        var parts: [String] = []
        if c.durationMinutes > 0 { parts.append("\(c.durationMinutes) min") }
        parts.append(contentsOf: c.types.prefix(2).map(PrivateChoices.title))
        if c.satisfaction > 0 { parts.append("Satisfaction \(c.satisfaction)/5") }
        if c.quickLog && parts.isEmpty { parts.append("Quick log") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var addedBy: String { Self.addedBy(entry, engine: engine, host: host) }

    /// "Added by …": whoever made the entry, by name, not the pair's name.
    @MainActor static func addedBy(_ entry: CalPrivateEntry, engine: CalendarEngine, host: CalendarHostPeople) -> String {
        engine.calendar(entry.calendarID).map { engine.personName(entry.createdBy, in: $0, host: host) } ?? "them"
    }
}

/// One pair's cycle on a day, shown only when it holds something: a person's
/// logged day (with its flow, changed in place), or else one plain line for
/// an estimate ("Period expected"). Logging a new day is + → Log period.
struct CycleDaySection: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let pair: CalCalendar
    let day: CalDate
    @State private var legend = false

    private var me: UUID { engine.config.currentUserID }
    private var today: CalDate { CalDate(Date(), in: .current) }

    /// Whether the day has a logged day or an estimate for anyone tracked.
    @MainActor static func hasSomething(engine: CalendarEngine, pair: CalCalendar, day: CalDate) -> Bool {
        let today = CalDate(Date(), in: .current)
        return engine.cyclePeople(in: pair).contains { engine.cycle(of: $0, in: pair)?.info(on: day, today: today).hasSomething == true }
    }

    var body: some View {
        let shown = engine.cyclePeople(in: pair).filter { engine.cycle(of: $0, in: pair)?.info(on: day, today: today).hasSomething == true }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cycle", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(CycleBand.period)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { legend = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("What the colors mean")
            }
            ForEach(shown, id: \.self) { person in personRow(person) }
            Text(CycleLegend.disclaimer).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .calendarCard(cornerRadius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cycleSection")
        .sheet(isPresented: $legend) { CycleLegend().presentationDetents([.medium, .large]) }
    }

    private func personRow(_ person: UUID) -> some View {
        let est = engine.cycle(of: person, in: pair)
        let info = est?.info(on: day, today: today)
        let kind = info?.kind
        let logged = est?.days.last { $0.date == day }
        let isPeriod: Bool = { if case .inPeriod = kind { return true }; if case .logged(let f) = kind { return f != .spotting }; return false }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(name(person)).font(.subheadline.weight(.semibold))
            if logged != nil || isPeriod {
                Text(CycleDaySection.periodLine(logged, info)).font(.body)
                if !pair.frozen {
                    if info?.askIfEnded == true {
                        // Past the usual length and not ended yet: ask, in the app only.
                        Text("Still on your period?").font(.subheadline)
                        HStack {
                            Button("Ended yesterday") { endedYesterday(person) }.cardButton()
                            Button("Ended today") { engine.markPeriodEnd(in: pair, for: person, on: day) }.cardButton()
                        }
                        .accessibilityIdentifier("askIfEnded")
                    } else if info?.openPeriod != nil && logged?.ends != true {
                        Button("Ended today") { engine.markPeriodEnd(in: pair, for: person, on: day) }
                            .cardButton()
                            .accessibilityIdentifier("endedToday")
                    }
                    Menu {
                        CycleFlowButtons(engine: engine, pair: pair, person: person, day: day)
                    } label: {
                        Label(logged?.flow.map { "Flow: \($0.title)" } ?? "Add flow", systemImage: "drop.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .accessibilityIdentifier("flowMenu")
                }
            } else if let kind {
                Label(CycleDaySection.estimate(kind), systemImage: CycleDaySection.symbol(kind))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cycleEstimate")
            }
            if est?.unsettled == true, let kind, CycleDaySection.isEstimate(kind) {
                // MVCALE-127 Q5: say what it is, not why (the partner sees it
                // too), and never "irregular".
                Text(CycleDaySection.unsettledLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cycleUnsettled")
            }
            if let info, let late = CycleDaySection.lateLine(info, unsettled: est?.unsettled == true) {
                // Both people see it (Travis, 2026-11-24: the pair's same screen).
                Text(late)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cycleLate")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// "Period · day 3", "Period · started", "Spotting"; in a short cycle,
    /// "Period · day 6 · fertile window" (MVCALE-127 finding 8: the period's
    /// mark wins the grid, so the day says both).
    static func periodLine(_ logged: CalCycleDay?, _ info: CalCycleDayInfo?) -> String {
        if logged?.flow == .spotting && logged?.starts != true { return "Spotting" }
        var parts = ["Period"]
        if logged?.starts == true { parts.append("started") }
        else if logged?.ends == true { parts.append("ended") }
        else if let d = info?.cycleDay { parts.append("day \(d)") }
        if info?.fertileToo == true { parts.append("fertile window") }
        return parts.joined(separator: " · ")
    }

    /// Under an estimate while cycles are unsettled (MVCALE-127 step 5).
    static let unsettledLine = "Cycles vary right now, so this is a wider estimate."

    /// An estimated mark (not a logged day).
    static func isEstimate(_ k: CalCycleDayInfo.Kind) -> Bool {
        switch k {
        case .predictedPeriod, .fertile, .fertilePossible: true
        case .logged, .inPeriod: false
        }
    }

    /// The day before this one was the last.
    private func endedYesterday(_ person: UUID) {
        engine.markPeriodEnd(in: pair, for: person, on: day.adding(days: -1))
    }

    /// Today, when a period is past its estimate by more than the grace
    /// period (MVCALE-127 step 4): "Not logged yet · 4 days past the
    /// estimate", never "late" (it may only be unlogged, and the partner sees
    /// it too). Past 60 days since the last start, only the cycle day: a
    /// count of days past stops meaning much, and keeps saying "late".
    /// While cycles are unsettled the count runs from the end of the expected
    /// range, not the dashed (median) estimate, so it says "the expected
    /// range" (Travis, 2026-11-24, from the Lab pass).
    static func lateLine(_ info: CalCycleDayInfo, unsettled: Bool) -> String? {
        guard let n = info.daysPastEstimate else { return nil }
        if let d = info.cycleDay, d > 60 { return "Cycle day \(d)" }
        return "Not logged yet · \(n) day\(n == 1 ? "" : "s") past the \(unsettled ? "expected range" : "estimate")"
    }

    /// "Period expected · estimate".
    static func estimate(_ k: CalCycleDayInfo.Kind) -> String {
        let s = PrivateMarks.spoken(k)
        return s.prefix(1).uppercased() + s.dropFirst() + " · estimate"
    }

    static func symbol(_ k: CalCycleDayInfo.Kind) -> String {
        switch k {
        case .logged, .inPeriod: "drop.fill"
        case .predictedPeriod: "drop"
        case .fertile: "circle.dotted"
        case .fertilePossible: "circle.dashed"
        }
    }

    private func name(_ person: UUID) -> String { Self.name(person, pair: pair, engine: engine, host: host) }

    /// Whose cycle a row is: "You", or the person by name, not the pair's name.
    @MainActor static func name(_ person: UUID, pair: CalCalendar, engine: CalendarEngine, host: CalendarHostPeople) -> String {
        person == engine.config.currentUserID ? "You" : engine.personName(person, in: pair, host: host)
    }
}

extension CalFlow {
    var title: String {
        switch self {
        case .spotting: "Spotting"
        case .light: "Light"
        case .medium: "Medium"
        case .heavy: "Heavy"
        }
    }
}

/// What the grid's marks mean, and what the estimates are (plan decisions 9,
/// 11 and 12).
struct CycleLegend: View {
    static let disclaimer = "Estimates only. Not a medical device or birth control."
    /// No shading (MVCALE-127 open question 2: in the legend only, so an
    /// empty day still shows no card). Never "safe".
    static let lowerChance = "No shading: lower chance, not zero"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Intimate") {
                    row(Image(systemName: "heart.fill").foregroundStyle(.pink), "An entry. Its color is the partner's, else whoever logged it.")
                    row(Image(systemName: "heart").foregroundStyle(.pink), "Who isn't filled in yet (a quick log).")
                    row(HeartMark(heart: CalHeart(author: UUID(), color: .pink, count: 2, hollow: false), size: 16),
                        "Two or more that day: the count is inside the heart.")
                }
                Section {
                    row(DropMark(kind: .logged, size: 16), "A period day, logged (fainter for spotting)")
                    row(DropMark(kind: .expected, size: 16), "A period day, expected")
                    row(band(.logged(.medium)), "Period, logged")
                    row(band(.logged(.spotting)), "Spotting, logged")
                    row(band(.predictedPeriod), "Period, expected")
                    row(band(.fertile(ovulation: false)), "Fertile window, expected")
                    row(band(.fertile(ovulation: true)), "Ovulation, expected")
                    row(band(.fertilePossible), "Fertility possible, estimated")
                    row(Color.clear.frame(width: 34, height: 18).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4))),
                        CycleLegend.lowerChance)
                } header: {
                    Text("Cycle")
                } footer: {
                    Text(CycleLegend.disclaimer)
                }
            }
            .navigationTitle("What the colors mean")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func band(_ k: CalCycleDayInfo.Kind) -> some View {
        CycleBand(kind: k, height: 18).frame(width: 34).clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func row(_ mark: some View, _ text: String) -> some View {
        HStack(spacing: 12) {
            mark.frame(width: 34)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: sheets

/// The private sheet on screen: a new entry (on a day, into one of these
/// pairs) or an existing one.
enum PrivateSheet: Identifiable {
    /// `for`: whose encounter it is, when logging one for the other member
    /// (MVCALE-51); nil, your own.
    case new(day: CalDate, pairs: [UUID], for: UUID? = nil)
    case edit(CalPrivateEntry)

    var id: String {
        switch self {
        case .new(let d, _, let who): "new-\(d)-\(who?.uuidString ?? "")"
        case .edit(let e): "edit-\(e.id)"
        }
    }
}

extension View {
    func privateSheets(engine: CalendarEngine, sheet: Binding<PrivateSheet?>) -> some View {
        self.sheet(item: sheet) { s in
            NavigationStack { PrivateEntryEditor(engine: engine, sheet: s) }
                .calendarAccent(engine.accentColor)
        }
    }
}

extension CalCalendar {
    /// A stand-in while a pair isn't loaded (its partner list is empty).
    static func placeholder(_ id: UUID) -> CalCalendar { CalCalendar(id: id, otherID: id) }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
