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
        case .new(let day, let pairs):
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
            _content = State(initialValue: CalPrivateContent(at: at, timeZone: zone.identifier))
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
        case .new(_, let pairs): pairs.compactMap { engine.calendar($0) }
        case .edit(let e): engine.calendar(e.calendarID).map { [$0] } ?? []
        }
    }

    private var pair: CalCalendar? { calendarID.flatMap { engine.calendar($0) } }
    /// Where partners come from, when there are none yet.
    private var noPartners: String {
        let who = pair.map { engine.displayName($0) } ?? "them"
        return "No partners yet. Add them under Privacy in your settings with \(who)."
    }
    /// A frozen pair (or one whose consent went off) is read-only.
    private var readOnly: Bool { pair.map { $0.frozen || !$0.intimateOn } ?? true }
    private var partners: [CalPartner] { pair.map { engine.partners(of: $0) } ?? [] }
    /// The names offered: every current one, and archived ones this entry already has.
    private var offered: [CalPartner] { partners.filter { !$0.archived || content.partnerIDs.contains($0.id) } }

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

    private var whoSection: some View {
        Section {
            Toggle("Solo", isOn: Binding(get: { content.solo }, set: { on in
                content.solo = on
                if on { content.partnerIDs = []; content.finishedInside = [:] }
            }))
            if !content.solo {
                ForEach(offered) { p in
                    Button { toggle(p) } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(p.color == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(CalTint(p.color)))
                            Text(p.name).foregroundStyle(.primary)
                            if p.archived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if content.partnerIDs.contains(p.id) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityAddTraits(content.partnerIDs.contains(p.id) ? .isSelected : [])
                }
                // Partners are managed in the pair's settings only (design review,
                // 2026-11-16): here they're picked, never added.
                if offered.isEmpty {
                    Text(noPartners)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("noPartners")
                }
            }
        } header: {
            Text("Who")
        } footer: {
            if content.needsWho { Text("Pick who, or Solo. Until then it shows as a hollow heart.") }
        }
    }

    private var finishedSection: some View {
        Section("Finished inside") {
            ForEach(content.partnerIDs, id: \.self) { id in
                Picker(partners.first { $0.id == id }?.name ?? "Partner",
                       selection: Binding(get: { content.finishedInside[id] ?? "" },
                                          set: { content.finishedInside[id] = $0.isEmpty ? nil : $0 })) {
                    ForEach(["", "yes", "no", "unsure"], id: \.self) { Text(PrivateChoices.title($0)).tag($0) }
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

    private func toggle(_ p: CalPartner) {
        if let i = content.partnerIDs.firstIndex(of: p.id) {
            content.partnerIDs.remove(at: i)
            content.finishedInside[p.id] = nil
        } else {
            content.partnerIDs.append(p.id)
        }
    }

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
