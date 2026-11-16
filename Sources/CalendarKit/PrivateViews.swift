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
        case .logged: "period"
        case .predictedPeriod: "period expected"
        case .fertile(ovulation: true): "ovulation expected"
        case .fertile: "fertile window"
        }
    }

    /// Which cycle mark wins a day when more than one person's falls on it:
    /// logged, then expected period, then ovulation, then the window.
    static func rank(_ k: CalCycleDayInfo.Kind) -> Int {
        switch k {
        case .logged: 4
        case .predictedPeriod: 3
        case .fertile(ovulation: true): 2
        case .fertile: 1
        }
    }
}

@MainActor
enum PrivateIndex {
    /// The marks for a run of days, for the pairs the scope shows (consented
    /// pairs only: the engine returns nothing else).
    static func marks(engine: CalendarEngine, from: CalDate, through: CalDate, zone: TimeZone,
                      scope: CalScope) -> [CalDate: PrivateMarks] {
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
                    if let k = est.info(on: d).kind {
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
        case .logged: CycleBand.period.opacity(0.32)
        case .predictedPeriod: CycleBand.period.opacity(0.08)
        case .fertile(ovulation: true): CycleBand.fertile.opacity(0.34)
        case .fertile: CycleBand.fertile.opacity(0.16)
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

/// A day's hearts in the strip above its number (plan decisions 6 and 9):
/// one per author (one centered; two, one at each side), in the partner's color or
/// the author's, hollow while who is still unset. A count of more than one
/// sits inside its heart. Each has a halo in the card's color, so a heart
/// reads on any cycle band whatever color it is (Torsion's review).
struct HeartMarks: View {
    let hearts: [CalHeart]
    let size: CGFloat

    var body: some View {
        // One heart centered over the number; two, one at each side.
        HStack(alignment: .top, spacing: 0) {
            if hearts.count > 1 {
                HeartMark(heart: hearts[0], size: size)
                Spacer(minLength: 0)
                HeartMark(heart: hearts[1], size: size)
            } else if let only = hearts.first {
                HeartMark(heart: only, size: size).frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
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
    let engine: CalendarEngine
    let appearance: CalendarAppearance
    /// The pairs + may add private things to (writable, consented, in scope).
    let intimate: [CalCalendar]
    let cycle: [CalCalendar]
    let canAddEvent: Bool
    let newEvent: () -> Void
    let newPrivate: () -> Void
    /// nil: the cycle has its own place already (the day view).
    let logPeriod: (() -> Void)?
    let label: AnyView

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
                        ForEach(intimate) { c in Button(engine.displayName(c)) { engine.quickLog(in: c) } }
                    } label: { Label("Quick log", systemImage: "bolt.heart") }
                }
            }
            if let logPeriod, !cycle.isEmpty {
                Button(action: logPeriod) { Label("Log period", systemImage: "drop") }
            }
        } label: { label }
        .accessibilityLabel("Add")
        .accessibilityIdentifier("addMenu")
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
        if scope.kind.showsPrivate {
            if !intimate.isEmpty { intimateSection(intimate) }
            ForEach(cycle) { c in CycleDaySection(engine: engine, pair: c, day: day, open: open) }
        }
    }

    private func intimateSection(_ pairs: [CalCalendar]) -> some View {
        let entries = engine.privateEntries(from: day, through: day, zone: zone, only: scope.only)
        let writable = pairs.filter { !$0.frozen }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Intimate", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(CycleBand.period)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !writable.isEmpty {
                    Button("Log") { open(.new(day: day, pairs: writable.map(\.id))) }
                        .cardButton()
                        .accessibilityLabel("Log an intimate entry")
                }
            }
            if entries.isEmpty {
                Text("Nothing logged.").foregroundStyle(.secondary)
            }
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

    private var addedBy: String {
        engine.calendar(entry.calendarID).map { engine.displayName($0) } ?? "them"
    }
}

/// One pair's cycle on a day: whose cycle, what the day is, and the flow
/// logged, changed in place. Either member may log for either of them.
struct CycleDaySection: View {
    let engine: CalendarEngine
    let pair: CalCalendar
    let day: CalDate
    let open: (PrivateSheet) -> Void
    @State private var legend = false

    private var me: UUID { engine.config.currentUserID }

    var body: some View {
        let tracked = engine.cyclePeople(in: pair)
        let untracked = [me, pair.otherID].filter { !tracked.contains($0) }
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
            ForEach(tracked, id: \.self) { person in personRow(person) }
            if !pair.frozen && !untracked.isEmpty {
                Menu {
                    ForEach(untracked, id: \.self) { p in
                        Menu(name(p)) { flowButtons(p, current: nil) }
                    }
                } label: {
                    Label(tracked.isEmpty ? "Log a period day" : "Track someone else", systemImage: "plus.circle")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("logPeriodMenu")
            }
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
        let info = est?.info(on: day)
        let logged = est?.days.last { $0.date == day }
        return VStack(alignment: .leading, spacing: 6) {
            Text(name(person)).font(.subheadline.weight(.semibold))
            Text(describe(info)).font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if !pair.frozen {
                Menu {
                    flowButtons(person, current: logged)
                } label: {
                    Label(logged.map { "Flow: \($0.flow.title)" } ?? "Log flow", systemImage: logged == nil ? "plus" : "drop.fill")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityIdentifier("flowMenu")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func flowButtons(_ person: UUID, current: CalCycleDay?) -> some View {
        ForEach(CalFlow.allCases, id: \.self) { f in
            Button {
                engine.logCycleDay(in: pair, for: person, on: day, flow: f)
            } label: {
                if current?.flow == f { Label(f.title, systemImage: "checkmark") } else { Text(f.title) }
            }
        }
        if let current {
            Button("None", role: .destructive) { engine.removeCycleDay(current) }
        }
    }

    private func name(_ person: UUID) -> String {
        person == me ? "You" : engine.displayName(pair)
    }

    private func describe(_ info: CalCycleDayInfo?) -> String {
        guard let info else { return "Nothing logged yet." }
        var parts: [String] = []
        if let d = info.cycleDay { parts.append("Day \(d) of the cycle") }
        if let k = info.kind { parts.append(PrivateMarks.spoken(k).prefix(1).uppercased() + PrivateMarks.spoken(k).dropFirst()) }
        return parts.isEmpty ? "Nothing logged yet." : parts.joined(separator: " · ")
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
    static let disclaimer = "Estimates from your entries. Not a medical device and not a contraceptive method."
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Intimate") {
                    row(Image(systemName: "heart.fill").foregroundStyle(.pink), "An entry. Its color is the partner's, else whoever logged it.")
                    row(Image(systemName: "heart").foregroundStyle(.pink), "Who isn't filled in yet (a quick log).")
                }
                Section {
                    row(band(.logged(.medium)), "Period, logged")
                    row(band(.logged(.spotting)), "Spotting, logged")
                    row(band(.predictedPeriod), "Period, expected")
                    row(band(.fertile(ovulation: false)), "Fertile window, expected")
                    row(band(.fertile(ovulation: true)), "Ovulation, expected")
                } header: {
                    Text("Cycle")
                } footer: {
                    Text("Ovulation is estimated as 14 days before the next period, and the fertile window as the 5 days before it. \(CycleLegend.disclaimer)")
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
    case new(day: CalDate, pairs: [UUID])
    case edit(CalPrivateEntry)

    var id: String {
        switch self {
        case .new(let d, _): "new-\(d)"
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
