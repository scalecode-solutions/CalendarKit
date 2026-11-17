import SwiftUI

// The intimate entry editor (0.8.0 design sprint, MVCALE-26; PROVISIONAL).
// The fields are plan decision 14: when, who or solo, how long, what,
// protection, finished inside per partner, orgasms, who initiated, where,
// satisfaction, notes, and positions in a section hidden by default.

/// The choices offered for the list fields. Stored as these keys; shown by title.
enum PrivateChoices {
    static let types = ["vaginal", "oral_giving", "oral_receiving", "anal", "manual", "toys", "other"]
    static let protection = ["none", "condom", "pill", "iud", "withdrawal", "other"]
    static let locations = ["bedroom", "living_room", "shower", "car", "outdoors", "hotel", "other"]
    static let positions = ["missionary", "on_top", "from_behind", "spooning", "standing", "sitting", "side_by_side", "other"]
    static let initiated = ["", "me", "partner", "mutual"]
    /// Finished inside, per partner ("" = not set, never sent).
    static let finished = ["yes", "no", "unsure"]

    static func title(_ key: String) -> String {
        switch key {
        case "": "Not set"
        case "oral_giving": "Oral (giving)"
        case "oral_receiving": "Oral (receiving)"
        case "iud": "IUD"
        case "living_room": "Living room"
        case "on_top": "On top"
        case "from_behind": "From behind"
        case "side_by_side": "Side by side"
        case "me": "Me"
        case "partner": "Partner"
        case "mutual": "Both"
        case "yes": "Yes"
        case "no": "No"
        case "unsure": "Unsure"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}

struct PrivateEntryEditor: View {
    let engine: CalendarEngine
    let sheet: PrivateSheet
    @Environment(\.dismiss) private var dismiss

    @State private var content: CalPrivateContent
    @State private var calendarID: UUID?
    @State private var showPositions: Bool
    @State private var confirmDelete = false

    init(engine: CalendarEngine, sheet: PrivateSheet) {
        self.engine = engine
        self.sheet = sheet
        switch sheet {
        case .new(let day, let pairs, let subject):
            // Today: now. Another day: that day at the current time.
            let now = Date()
            let zone = TimeZone.current
            var at = now
            if CalDate(now, in: zone) != day {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                let t = cal.dateComponents([.hour, .minute], from: now)
                at = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                   hour: t.hour, minute: t.minute)) ?? now
            }
            var c = CalPrivateContent(at: at, timeZone: zone.identifier)
            c.subjectID = subject
            if let first = pairs.first.flatMap({ engine.calendar($0) }) {
                c.partnerIDs = Self.startingWho(engine: engine, pair: first, subject: subject).map { [$0] } ?? []
            }
            _content = State(initialValue: c)
            _calendarID = State(initialValue: pairs.first)
            _showPositions = State(initialValue: false)
        case .edit(let e):
            _content = State(initialValue: e.content)
            _calendarID = State(initialValue: e.calendarID)
            _showPositions = State(initialValue: !e.content.positions.isEmpty)
        }
    }

    private var existing: CalPrivateEntry? {
        if case .edit(let e) = sheet { return e }
        return nil
    }

    private var pairChoices: [CalCalendar] {
        switch sheet {
        case .new(_, let pairs, _): pairs.compactMap { engine.calendar($0) }
        case .edit(let e): engine.calendar(e.calendarID).map { [$0] } ?? []
        }
    }

    private var pair: CalCalendar? { calendarID.flatMap { engine.calendar($0) } }
    /// Where partners come from, when there are none yet.
    private var noPartners: String {
        let who = pair.map { engine.displayName($0) } ?? "them"
        if forOther { return "\(who) hasn't added any partners yet. They add their own under Privacy." }
        return "No partners yet. Add them under Privacy in your settings with \(who)."
    }
    /// A frozen pair (or one whose consent went off) is read-only.
    private var readOnly: Bool { pair.map { $0.frozen || !$0.intimateOn } ?? true }
    /// Every partner on the pair, both members': to name what an entry has.
    private var partners: [CalPartner] { pair.map { engine.partners(of: $0) } ?? [] }
    /// Whose encounter this is: the entry's subject, or for a new one, whoever
    /// it's being logged for (you, unless + said otherwise).
    private var subject: UUID {
        content.subjectID ?? existing?.createdBy ?? engine.config.currentUserID
    }

    /// For: whose encounter it is (MVCALE-53, design review): You or the other
    /// member, at the top. Changing it starts Who over from that person's
    /// list and default, and turns Solo off; on an existing entry too, so no
    /// partner carries across from one person's list to the other's.
    private var forWho: Binding<UUID> {
        Binding(get: { subject }, set: { person in
            guard person != subject else { return }
            content.subjectID = person
            content.solo = false
            content.finishedInside = [:]
            content.partnerIDs = pair.flatMap {
                Self.startingWho(engine: engine, pair: $0, subject: person)
            }.map { [$0] } ?? []
        })
    }
    private var forOther: Bool { subject != engine.config.currentUserID }

    /// Who a new entry starts with (design review, MVCALE-51): the subject's
    /// default partner (synced, so an entry For the other knows theirs).
    static func startingWho(engine: CalendarEngine, pair: CalCalendar, subject: UUID?) -> UUID? {
        engine.defaultPartner(of: subject ?? engine.config.currentUserID, in: pair)
    }

    /// "Not set" is offered only while there's nothing to start from: with a
    /// default (or their one partner) Who is simply which partner.
    private var offersNotSet: Bool {
        guard let pair else { return true }
        return content.partnerIDs.isEmpty
            || Self.startingWho(engine: engine, pair: pair, subject: forOther ? subject : nil) == nil
    }
    /// The names offered (MVCALE-51): the subject's own current list, never
    /// the other member's, so nobody picks themselves; plus whoever this entry
    /// already names, so it reads as it is. Either of you may edit it (plan
    /// decision 18); Who always draws from the subject's list.
    private var offered: [CalPartner] {
        let theirs = partners.filter { $0.ownerID == subject }
        return theirs.filter { !$0.archived || content.partnerIDs.contains($0.id) }
            + partners.filter { p in content.partnerIDs.contains(p.id) && !theirs.contains { $0.id == p.id } }
    }

    var body: some View {
        Form {
            whenSection
            whoSection
            if !content.solo && !content.partnerIDs.isEmpty { finishedSection }
            whatSection
            detailsSection
            Section {
                TextField("Notes", text: $content.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            positionsSection
            if existing != nil && !readOnly {
                Section {
                    Button("Delete entry", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .disabled(readOnly)
        // Another pair chosen for a new entry: its partners, and its default.
        .onChange(of: calendarID) { _, id in
            guard existing == nil, let c = id.flatMap({ engine.calendar($0) }) else { return }
            content.subjectID = nil // the other member differs from pair to pair: back to You
            content.solo = false
            content.partnerIDs = Self.startingWho(engine: engine, pair: c, subject: content.subjectID).map { [$0] } ?? []
            content.finishedInside = [:]
        }
        .scrollContentBackground(.hidden)
        .calendarBackdrop(engine)
        .navigationTitle("Intimate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(readOnly ? "Close" : "Cancel") { dismiss() } }
            if !readOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(pair == nil)
                }
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let existing { engine.deletePrivate(existing) }
                dismiss()
            }
        }
    }

    // MARK: sections

    private var whenSection: some View {
        Section {
            if let pair {
                Picker("For", selection: forWho) {
                    Text("You").tag(engine.config.currentUserID)
                    Text(engine.displayName(pair)).tag(pair.otherID)
                }
                .accessibilityIdentifier("for")
            }
            DatePicker("When", selection: $content.at)
            if pairChoices.count > 1 {
                Picker("Calendar", selection: $calendarID) {
                    ForEach(pairChoices) { c in Text(engine.displayName(c)).tag(Optional(c.id)) }
                }
            }
            Stepper(value: $content.durationMinutes, in: 0...600, step: 5) {
                LabeledContent("Duration", value: content.durationMinutes == 0 ? "Not set" : "\(content.durationMinutes) min")
            }
            Stepper(value: $content.foreplayMinutes, in: 0...300, step: 5) {
                LabeledContent("Foreplay", value: content.foreplayMinutes == 0 ? "Not set" : "\(content.foreplayMinutes) min")
            }
        } footer: {
            if readOnly, let pair {
                Text(pair.frozen ? "You two aren't friends any more, so this is read-only."
                                 : "Intimate entries are off for this calendar.")
            }
        }
    }

    /// What Who is set to: one pick from a dropdown (design review, 2026-11-16: a
    /// plain dropdown, not a visible roster). An older entry naming several
    /// partners keeps them as its own choice until someone picks another.
    enum Who: Hashable {
        case notSet, solo, partner(UUID), several([UUID])
    }

    private var who: Binding<Who> {
        Binding(get: {
            let c = content
            if c.solo { return .solo }
            switch c.partnerIDs.count {
            case 0: return .notSet
            case 1: return .partner(c.partnerIDs[0])
            default: return .several(c.partnerIDs)
            }
        }, set: { w in
            switch w {
            case .notSet: content.solo = false; content.partnerIDs = []
            case .solo: content.solo = true; content.partnerIDs = []
            case .partner(let id): content.solo = false; content.partnerIDs = [id]
            case .several(let ids): content.solo = false; content.partnerIDs = ids
            }
            // Finished inside is kept only for whoever is still named.
            content.finishedInside = content.finishedInside.filter { content.partnerIDs.contains($0.key) }
        })
    }

    private var whoSection: some View {
        Section {
            // Solo is a switch of its own, above Who (MVCALE-51).
            Toggle("Solo", isOn: Binding(get: { content.solo }, set: { on in
                // Off again: back to whoever it starts with (the default).
                let start = pair.flatMap { Self.startingWho(engine: engine, pair: $0, subject: forOther ? subject : nil) }
                who.wrappedValue = on ? .solo : start.map(Who.partner) ?? .notSet
            }))
                .accessibilityIdentifier("solo")
            if !content.solo { whoPicker }
        } footer: {
            if forOther, let pair {
                Text("For \(engine.displayName(pair)): who comes from their partner list.")
            } else if content.needsWho {
                Text("Turn on Solo or pick who. Until then it shows as a hollow heart.")
            }
        }
    }

    @ViewBuilder private var whoPicker: some View {
            Picker("Who", selection: who) {
                if offersNotSet { Text("Not set").tag(Who.notSet) }
                if content.partnerIDs.count > 1 {
                    Text(PrivateEntryRow.names(content.partnerIDs, partners: partners)).tag(Who.several(content.partnerIDs))
                }
                ForEach(offered) { p in
                    Text(p.archived ? "\(p.name) (removed)" : p.name).tag(Who.partner(p.id))
                }
            }
            .accessibilityIdentifier("who")
            // Partners are managed in the pair's settings only (design review,
            // 2026-11-16): here they're picked, never added.
            if offered.isEmpty {
                Text(noPartners)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("noPartners")
            }
    }

    private var finishedSection: some View {
        Section {
            ForEach(content.partnerIDs, id: \.self) { id in
                // One partner (the usual case): just "Finished inside".
                Picker(content.partnerIDs.count == 1 ? "Finished inside" : "Finished inside: \(partners.first { $0.id == id }?.name ?? "Partner")",
                       selection: Binding(get: { content.finishedInside[id] ?? "" },
                                          set: { content.finishedInside[id] = $0.isEmpty ? nil : $0 })) {
                    ForEach([""] + PrivateChoices.finished, id: \.self) { Text(PrivateChoices.title($0)).tag($0) }
                }
            }
        }
    }

    private var whatSection: some View {
        Section("What") {
            MultiPick(title: "Type", options: PrivateChoices.types, selection: $content.types)
            MultiPick(title: "Protection", options: PrivateChoices.protection, selection: $content.protection)
        }
    }

    private var detailsSection: some View {
        Section("Details") {
            Stepper(value: $content.orgasmsMe, in: 0...20) {
                LabeledContent("My orgasms", value: "\(content.orgasmsMe)")
            }
            if !content.solo {
                Stepper(value: $content.orgasmsPartner, in: 0...20) {
                    LabeledContent("Partner's orgasms", value: "\(content.orgasmsPartner)")
                }
                Picker("Who initiated", selection: $content.initiatedBy) {
                    ForEach(PrivateChoices.initiated, id: \.self) { Text(PrivateChoices.title($0)).tag($0) }
                }
            }
            Picker("Where", selection: $content.location) {
                Text("Not set").tag("")
                ForEach(PrivateChoices.locations, id: \.self) { Text(PrivateChoices.title($0)).tag($0) }
            }
            if !content.location.isEmpty {
                TextField("Where, in your words", text: $content.locationNote)
            }
            HStack {
                Text("Satisfaction")
                Spacer()
                ForEach(1...5, id: \.self) { n in
                    Button {
                        content.satisfaction = content.satisfaction == n ? 0 : n
                    } label: {
                        Image(systemName: n <= content.satisfaction ? "heart.fill" : "heart")
                            .foregroundStyle(CycleBand.period)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(n) of 5")
                    .accessibilityAddTraits(n == content.satisfaction ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Satisfaction")
        }
    }

    private var positionsSection: some View {
        Section {
            Toggle("Positions", isOn: $showPositions.animation())
            if showPositions {
                MultiPick(title: "Positions", options: PrivateChoices.positions, selection: $content.positions)
            }
        } footer: {
            Text("Hidden unless you turn it on.")
        }
    }

    // MARK: actions

    private func save() {
        guard let pair else { return }
        // A quick log stays one until who is filled in.
        if !content.needsWho { content.quickLog = false }
        if let existing {
            var e = existing
            e.content = content
            engine.savePrivate(e)
        } else {
            engine.savePrivate(CalPrivateEntry(calendarID: pair.id, content: content, createdBy: engine.config.currentUserID))
        }
        dismiss()
    }
}

/// A list field: a row with what's picked, pushing a list of checkmarks.
struct MultiPick: View {
    let title: String
    let options: [String]
    @Binding var selection: [String]

    var body: some View {
        NavigationLink {
            List(options, id: \.self) { o in
                Button {
                    if let i = selection.firstIndex(of: o) { selection.remove(at: i) } else { selection.append(o) }
                } label: {
                    HStack {
                        Text(PrivateChoices.title(o)).foregroundStyle(.primary)
                        Spacer()
                        if selection.contains(o) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .accessibilityAddTraits(selection.contains(o) ? .isSelected : [])
            }
            .navigationTitle(title)
        } label: {
            LabeledContent(title, value: selection.isEmpty ? "Not set" : selection.map(PrivateChoices.title).joined(separator: ", "))
        }
    }
}
