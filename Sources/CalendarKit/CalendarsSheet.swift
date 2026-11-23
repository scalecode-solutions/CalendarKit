import SwiftUI
import os


/// Calendar settings, pushed by the host (e.g. from a gear; CalendarLab:
/// from the account button): your own color, where the calendar opens, and
/// each pair (shown or hidden, its color, and from its row its labels and
/// history). The host appends its own sections through `extra`.
public struct CalendarSettingsView<Extra: View>: View {
    @Environment(\.calendarHostPeople) private var host
    @Bindable var engine: CalendarEngine
    let extra: Extra
    @AppStorage(CalendarOpensOn.storageKey) private var opensOn: CalendarOpensOn = .lastUsed

    public init(engine: CalendarEngine, @ViewBuilder extra: () -> Extra) {
        self.engine = engine
        self.extra = extra()
    }

    public var body: some View {
        List {
            Section {
                Picker("My color", selection: $engine.myColor) {
                    ForEach(CalColor.allCases, id: \.self) { col in
                        Text(col == .none ? "Automatic" : col.title).tag(col)
                    }
                }
                Picker("Opens on", selection: $opensOn) {
                    ForEach(CalendarOpensOn.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Your color marks what you add.")
            }
            Section {
                if engine.calendars.isEmpty {
                    Text("Your calendars with friends show up here.").foregroundStyle(.secondary)
                }
                // Listed by the names on screen (the host's), though the
                // engine keeps its own order for the saved auto colours.
                ForEach(engine.calendars.sorted {
                    (engine.displayName($0, host: host).lowercased(), $0.id.uuidString)
                        < (engine.displayName($1, host: host).lowercased(), $1.id.uuidString)
                }) { c in
                    HStack(spacing: 10) {
                        // A pair's own settings (labels, activity, privacy) live
                        // with the conversation in the host: PairSettingsView.
                        HStack(spacing: 10) {
                            CalAvatar(contact: engine.person(of: c), fallbackName: engine.displayName(c, host: host), tint: c.displayColor, size: 28,
                                      personID: c.otherID)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(engine.displayName(c, host: host))
                                Text(stateText(c)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        Menu {
                            Picker("Color", selection: Binding(get: { c.prefColor }, set: { engine.setColor(c, $0) })) {
                                ForEach(CalColor.allCases, id: \.self) { col in
                                    Text(col == .none ? "Automatic" : col.title).tag(col)
                                }
                            }
                        } label: {
                            Circle().fill(CalTint(c.displayColor)).frame(width: 18, height: 18)
                        }
                        .accessibilityLabel("Color for \(engine.displayName(c, host: host))")
                        Toggle("Show \(engine.displayName(c, host: host))", isOn: Binding(get: { c.visible }, set: { engine.setVisible(c, $0) }))
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Calendars")
            } footer: {
                // Sync status sits under the list it's about.
                if engine.pendingCount > 0 {
                    Text("\(engine.pendingCount) change\(engine.pendingCount == 1 ? "" : "s") waiting to sync.")
                } else if let e = engine.lastError {
                    Text(e)
                } else {
                    Text("One calendar with each friend. Hiding one only hides it for you.")
                }
            }
            extra
        }
        .calendarBackdrop(engine)
        .calendarAccent(engine.accentColor)
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stateText(_ c: CalCalendar) -> String {
        if c.frozen { return "Read-only: you aren't friends now" }
        return c.visible ? "Shown" : "Hidden"
    }
}

/// One pair's settings: its labels, its history and its privacy. A host
/// pushes it from the conversation with that person (its settings page,
/// beside search), not from the calendar: these are the two people's things,
/// while CalendarSettingsView holds only the person's own (their color, where
/// it opens, which pairs show). The host keeps the engine running while it's
/// on screen, as for the calendar.
public struct PairSettingsView: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let otherID: UUID

    public init(engine: CalendarEngine, otherID: UUID) {
        self.engine = engine
        self.otherID = otherID
    }

    public var body: some View {
        Group {
            // A friend with no pair on the server yet is listed too (synthesized):
            // its first label or consent opens the pair.
            if let c = engine.calendars.first(where: { $0.otherID == otherID }) {
                List {
                    Section {
                        NavigationLink("Labels") { LabelsView(engine: engine, pairID: c.id).calendarAccent(engine.accentColor) }
                            .accessibilityIdentifier("pair.labels")
                        NavigationLink("Activity") { ActivityView(engine: engine, pair: c).calendarAccent(engine.accentColor) }
                            .accessibilityIdentifier("pair.activity")
                        NavigationLink("Privacy") { PairPrivacySheet(engine: engine, calendar: c) }
                            .accessibilityIdentifier("pair.privacy")
                    } footer: {
                        Text(c.frozen ? "You two aren't friends any more, so this calendar is read-only."
                                      : "These belong to your calendar with \(engine.personName(c.otherID, in: c, host: host)): you both see and change them.")
                    }
                }
                .calendarBackdrop(engine)
            } else if engine.loadState == .idle || engine.loadState == .loading {
                ProgressView()
            } else {
                ContentUnavailableView("No calendar together", systemImage: "calendar",
                                       description: Text("A calendar with someone starts once you're friends."))
            }
        }
        .calendarAccent(engine.accentColor)
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LabelsView: View {
    let engine: CalendarEngine
    let pairID: UUID
    @State private var newName = ""
    @State private var newColor: CalColor = .none

    private var pair: CalCalendar? { engine.calendar(pairID) }

    var body: some View {
        List {
            Section {
                ForEach(engine.labels(of: pairID)) { l in
                    HStack {
                        Circle().fill(l.color == .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(CalTint(l.color))).frame(width: 12, height: 12)
                        Text(l.name)
                    }
                    .swipeActions { if pair?.frozen == false { Button("Delete", role: .destructive) { engine.deleteLabel(l) } } }
                }
            } footer: {
                Text("Shared by you both. Deleting one keeps its events.")
            }
            if let pair, !pair.frozen {
                Section("New label") {
                    TextField("Name", text: $newName)
                    ColorRow(selection: $newColor)
                    Button("Add") {
                        engine.saveLabel(in: pair, name: newName.trimmingCharacters(in: .whitespaces), color: newColor)
                        newName = ""
                        newColor = .none
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .calendarBackdrop(engine)
        .navigationTitle("Labels")
    }
}

struct ActivityView: View {
    @Environment(\.calendarHostPeople) private var host
    let engine: CalendarEngine
    let pair: CalCalendar
    @State private var rows: [CalActivity] = []
    @State private var next: String?
    @State private var error: String?

    var body: some View {
        List {
            if rows.isEmpty && error == nil { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(rows) { a in
                VStack(alignment: .leading, spacing: 2) {
                    Text(sentence(a))
                    Text(a.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if next != nil { Button("Load more") { Task { await load(more: true) } } }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .calendarBackdrop(engine)
        .navigationTitle("Activity")
        .task { await load(more: false) }
    }

    private func who(_ id: UUID?) -> String {
        if id == engine.config.currentUserID { return "You" }
        return id.flatMap { engine.personName($0, host: host) } ?? "Someone"
    }

    private func sentence(_ a: CalActivity) -> String {
        switch a.kind {
        case "event_added": return "\(who(a.actorID)) added “\(a.detail)”"
        case "event_changed": return "\(who(a.actorID)) changed “\(a.detail)”"
        case "event_deleted": return "\(who(a.actorID)) deleted “\(a.detail)”"
        // Plan decision 16: no time, partner or content, ever.
        case "intimate_added": return "\(who(a.actorID)) added a private entry"
        case "intimate_changed": return "\(who(a.actorID)) changed a private entry"
        case "intimate_deleted": return "\(who(a.actorID)) deleted a private entry"
        default: return a.detail
        }
    }

    private func load(more: Bool) async {
        do {
            let r = try await engine.activity(of: pair, cursor: more ? next : nil)
            rows = more ? rows + r.rows : r.rows
            next = r.next
            error = nil
        } catch {
            self.error = "Couldn't load activity."
        }
    }
}

public extension CalendarSettingsView where Extra == EmptyView {
    init(engine: CalendarEngine) { self.init(engine: engine) { EmptyView() } }
}
