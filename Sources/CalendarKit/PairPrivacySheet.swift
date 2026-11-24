import SwiftUI

// A pair's privacy settings (0.8.0 design sprint, MVCALE-26; PROVISIONAL):
// the person's own two consents (intimate entries, cycle), the pair's partner
// list, and each member's cycle settings. "Intimate" is the word on screen;
// the types say "private".

/// One pair's privacy: what this person has turned on, whether the other has
/// too, the partner list both share, and cycle settings. Pushed from the
/// pair's row in the calendar settings.
public struct PairPrivacySheet: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let calendarID: UUID
    /// The partner a swipe asked to remove. The dialog hangs off the List, not
    /// a section header a List can drop once it scrolls away (Frond's review).
    @State private var removing: CalPartner?

    public init(engine: CalendarEngine, calendar: CalCalendar) {
        self.engine = engine
        self.calendarID = calendar.id
    }

    public var body: some View {
        if let c = engine.calendar(calendarID) {
            List {
                ConsentSection(engine: engine, pair: c, kind: .intimate)
                if c.intimateOn { PartnersSection(engine: engine, pair: c, removing: $removing) }
                ConsentSection(engine: engine, pair: c, kind: .cycle)
                // Each person tracks their own cycle (MVCALE-51): settings for
                // whoever has it on.
                ForEach(engine.cyclePeople(in: c), id: \.self) { person in
                    CycleSettingsSection(engine: engine, pair: c, person: person,
                                         title: person == engine.config.currentUserID ? "Your cycle" : "\(engine.personName(person, in: c, host: host))’s cycle")
                }
            }
            .calendarBackdrop(engine)
            .calendarAccent(engine.accentColor)
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { p in
                Button("Remove", role: .destructive) { remove(p, engine) }
            } message: { _ in
                Text("Past entries keep the name.")
            }
        } else {
            ContentUnavailableView("This calendar is gone", systemImage: "calendar.badge.exclamationmark")
        }
    }
}

/// What one consent stands at, for the line under its switch.
enum ConsentState: Equatable {
    case frozen, off, waitingForThem, waitingForMe, on

    init(mine: Bool, theirs: Bool, frozen: Bool) {
        if frozen { self = .frozen }
        else if mine && theirs { self = .on }
        else if mine { self = .waitingForThem }
        else if theirs { self = .waitingForMe }
        else { self = .off }
    }

    /// The line under the switch, only when it says something the switch
    /// doesn't (design review: short, a line at most).
    func text(_ name: String, _ kind: CalConsentKind) -> String? {
        if kind == .cycle {
            // Each person's own: only whether the other tracks theirs.
            switch self {
            case .frozen: return "You two aren’t friends any more."
            case .waitingForMe, .on: return "\(name) tracks theirs here."
            case .off, .waitingForThem: return nil
            }
        }
        switch self {
        case .frozen: return "You two aren’t friends any more."
        case .off, .on: return nil
        case .waitingForThem: return "On for you. It starts once \(name) turns it on too."
        case .waitingForMe: return "\(name) turned it on. It starts if you do too."
        }
    }
}

private struct ConsentSection: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let pair: CalCalendar
    let kind: CalConsentKind

    private var mine: Bool { kind == .intimate ? pair.intimateMine : pair.cycleMine }
    private var theirs: Bool { kind == .intimate ? pair.intimateTheirs : pair.cycleTheirs }

    var body: some View {
        let state = ConsentState(mine: mine, theirs: theirs, frozen: pair.frozen)
        Section {
            Toggle(kind == .intimate ? "Intimate entries" : "Track my cycle",
                   isOn: Binding(get: { mine }, set: { engine.setConsent(pair, kind, $0) }))
                // Off is always allowed; on needs friends (the server refuses a frozen pair).
                .disabled(pair.frozen && !mine)
                .accessibilityIdentifier(kind == .intimate ? "privacy.intimate" : "privacy.cycle")
            if let line = state.text(engine.personName(pair.otherID, in: pair, host: host), kind) {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(kind == .intimate ? "privacy.intimate.state" : "privacy.cycle.state")
            }
        } header: {
            Text(kind == .intimate ? "Intimate" : "Cycle")
        } footer: {
            if kind == .intimate {
                Text("Shows once you've both turned it on.")
            } else {
                Text("Period days and estimates. Not a medical device or birth control.")
            }
        }
    }
}

private struct PartnersSection: View {
    let engine: CalendarEngine
    let pair: CalCalendar
    @State private var newName = ""
    @State private var newColor: CalColor = .none
    @Binding var removing: CalPartner?

    var body: some View {
        // Removed partners (archived under the hood) stay on old entries only.
        // Your own list (MVCALE-51): the other member keeps theirs.
        let partners = engine.myPartners(of: pair).filter { !$0.archived }
        Section {
            ForEach(partners) { p in
                NavigationLink {
                    PartnerEditor(engine: engine, partner: p)
                } label: {
                    HStack(spacing: 10) {
                        PartnerDot(color: p.color)
                        Text(p.name)
                    }
                }
                .swipeActions {
                    if !pair.frozen {
                        // There's no way back, so a swipe asks too.
                        Button("Remove", role: .destructive) { removing = p }
                    }
                }
                .accessibilityIdentifier("privacy.partner.\(p.name)")
            }
            if !partners.isEmpty {
                // Yours alone, on this device: new entries and quick logs start
                // with it (design review, 2026-11-16).
                Picker("My default", selection: Binding(get: { engine.defaultPartner(in: pair) },
                                                         set: { engine.setDefaultPartner($0, in: pair) })) {
                    Text("None").tag(UUID?.none)
                    ForEach(partners) { p in Text(p.name).tag(UUID?.some(p.id)) }
                }
                .accessibilityIdentifier("privacy.partner.default")
            }
            if !pair.frozen {
                HStack {
                    TextField("Add a name", text: $newName)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .accessibilityIdentifier("privacy.partner.name")
                    PartnerColorMenu(selection: $newColor)
                    Button("Add", action: add)
                        .disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("privacy.partner.add")
                }
            }
        } header: {
            Text("My partners")
        } footer: {
            Text("Who you pick from when you log. A color tints their heart.")
        }
    }

    private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        guard !trimmed.isEmpty else { return }
        engine.savePartner(CalPartner(calendarID: pair.id, name: String(trimmed.prefix(60)), color: newColor))
        newName = ""
        newColor = .none
    }
}

/// Remove a partner: gone from settings and the pickers, still named on past
/// entries (archived on the server; there's no way back, by design).
@MainActor
private func remove(_ p: CalPartner, _ engine: CalendarEngine) {
    var q = p
    q.archived = true
    engine.savePartner(q)
}

private struct PartnerEditor: View {
    let engine: CalendarEngine
    @State var partner: CalPartner
    @State private var confirmRemove = false
    /// As it was opened: Remove doesn't save an unsaved rename.
    private let original: CalPartner

    init(engine: CalendarEngine, partner: CalPartner) {
        self.engine = engine
        _partner = State(initialValue: partner)
        original = partner
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $partner.name)
                .accessibilityIdentifier("privacy.partner.edit.name")
            Picker("Heart color", selection: $partner.color) {
                ForEach(CalColor.allCases, id: \.self) { c in
                    Text(c == .none ? "Whoever logged it" : c.title).tag(c)
                }
            }
            if engine.calendar(partner.calendarID)?.frozen == false {
                Section {
                    Button("Remove", role: .destructive) { confirmRemove = true }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("privacy.partner.edit.remove")
                } footer: {
                    Text("Past entries keep the name.")
                }
            }
        }
        .confirmationDialog("Remove \(partner.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                remove(original, engine)
                dismiss()
            }
        }
        .navigationTitle("Partner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    partner.name = String(partner.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                    engine.savePartner(partner)
                    dismiss()
                }
                .disabled(partner.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || engine.calendar(partner.calendarID)?.frozen != false)
                .accessibilityIdentifier("privacy.partner.edit.save")
            }
        }
    }
}

private struct PartnerColorMenu: View {
    @Binding var selection: CalColor

    var body: some View {
        Menu {
            Picker("Heart color", selection: $selection) {
                ForEach(CalColor.allCases, id: \.self) { c in
                    Text(c == .none ? "Whoever logged it" : c.title).tag(c)
                }
            }
        } label: {
            PartnerDot(color: selection).frame(width: 22, height: 22)
        }
        .accessibilityLabel("Heart color: \(selection == .none ? "whoever logged it" : selection.title)")
    }
}

private struct PartnerDot: View {
    let color: CalColor
    var body: some View {
        Image(systemName: color == .none ? "heart" : "heart.fill")
            .foregroundStyle(color == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(CalTint(color)))
            .accessibilityHidden(true)
    }
}

/// One member's cycle settings. 0 = measure from what's logged; the measured
/// (or default) value shows beside "Automatic".
private struct CycleSettingsSection: View {
    let engine: CalendarEngine
    let pair: CalCalendar
    let person: UUID
    let title: String

    private var current: CalCycleSettings {
        engine.cycle(of: person, in: pair)?.settings ?? CalCycleSettings(calendarID: pair.id, personID: person)
    }

    var body: some View {
        let est = engine.cycle(of: person, in: pair)
        let s = current
        Section(title) {
            Picker("Cycle length", selection: Binding(get: { s.cycleLength }, set: { save(cycle: $0) })) {
                Text("Automatic (\(est?.cycleLength ?? 28) days)").tag(0)
                ForEach(20...45, id: \.self) { Text("\($0) days").tag($0) }
            }
            .accessibilityIdentifier("privacy.cycleLength.\(person == engine.config.currentUserID ? "me" : "them")")
            Picker("Period length", selection: Binding(get: { s.periodLength }, set: { save(period: $0) })) {
                Text("Automatic (\(est?.periodLength ?? 5) days)").tag(0)
                ForEach(1...10, id: \.self) { Text("\($0) day\($0 == 1 ? "" : "s")").tag($0) }
            }
            .accessibilityIdentifier("privacy.periodLength.\(person == engine.config.currentUserID ? "me" : "them")")
            if let next = est?.nextPeriodLabel(today: CalDate(Date(), in: .current)) {
                LabeledContent("Next period, estimated", value: next)
            }
        }
        .disabled(pair.frozen)
    }

    private func save(cycle: Int? = nil, period: Int? = nil) {
        var s = current
        if let cycle { s.cycleLength = cycle }
        if let period { s.periodLength = period }
        engine.saveCycleSettings(s)
    }
}

extension CalCycleEstimator {
    /// The settings sheet's "Next period, estimated": "Tue, Dec 22", or
    /// while past it with none logged, "Tue, Nov 24 · not logged yet" rather
    /// than a date that's gone by (MVCALE-127 step 4). While cycles are
    /// unsettled, the range it may come in: "Dec 3 – Dec 17" (step 5). Both
    /// people see it.
    func nextPeriodLabel(today: CalDate) -> String? {
        guard let next = predictedStarts(count: 1).first else { return nil }
        let date: String
        if let range = nextRange {
            let f = CalFormat.template("MMMd")
            date = f.string(from: range.lowerBound.utcMidnight) + " – " + f.string(from: range.upperBound.utcMidnight)
        } else {
            date = CalFormat.template("EEEMMMd").string(from: next.utcMidnight)
        }
        return overdue(today: today) == nil ? date : date + " · not logged yet"
    }
}
