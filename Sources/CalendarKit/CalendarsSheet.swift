import SwiftUI
import os

private let uiLog = Logger(subsystem: "CalendarKit", category: "ui")

/// Calendar settings, pushed by the host (e.g. from a gear; CalendarLab:
/// from the account button): which calendars to show and in what color; for
/// your own calendar its name, labels, who it's shared with, and its history.
/// The host appends its own sections through `extra`.
public struct CalendarSettingsView<Extra: View>: View {
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
                ForEach(engine.calendars) { c in
                    HStack(spacing: 10) {
                        CalAvatar(contact: engine.owner(of: c), fallbackName: engine.displayName(c), tint: c.displayColor, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(engine.displayName(c))
                            Text(roleText(c)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Picker("Color", selection: Binding(get: { c.prefColor }, set: { engine.setColor(c, $0) })) {
                                ForEach(CalColor.allCases, id: \.self) { col in
                                    Text(col == .none ? (c.color == .none ? "Automatic" : "Owner's color") : col.title).tag(col)
                                }
                            }
                        } label: {
                            Circle().fill(CalTint(c.displayColor)).frame(width: 18, height: 18)
                        }
                        .accessibilityLabel("Color for \(engine.displayName(c))")
                        Toggle("Show \(engine.displayName(c))", isOn: Binding(get: { c.visible }, set: { engine.setVisible(c, $0) }))
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Show")
            } footer: {
                // Sync status sits under the list it's about.
                if engine.pendingCount > 0 {
                    Text("\(engine.pendingCount) change\(engine.pendingCount == 1 ? "" : "s") waiting to sync.")
                } else if let e = engine.lastError {
                    Text(e)
                }
            }
            Section {
                Picker("Opens on", selection: $opensOn) {
                    ForEach(CalendarOpensOn.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Last used opens Month or Agenda, whichever you were on.")
            }
            if let own = engine.ownCalendar {
                Section("My calendar") {
                    NavigationLink("Name and color") { OwnCalendarSettings(engine: engine, calendar: own).calendarAccent(engine.accentColor) }
                    NavigationLink("Labels") { LabelsView(engine: engine).calendarAccent(engine.accentColor) }
                    NavigationLink("Sharing") { SharingView(engine: engine).calendarAccent(engine.accentColor) }
                    NavigationLink("Activity") { ActivityView(engine: engine).calendarAccent(engine.accentColor) }
                }
            }
            extra
        }
        .calendarBackdrop(engine)
        .calendarAccent(engine.accentColor)
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func roleText(_ c: CalCalendar) -> String {
        switch c.role {
        case .owner: return "Yours"
        case .edit: return "Shared with you · can edit"
        case .view: return "Shared with you · view only"
        }
    }
}

struct OwnCalendarSettings: View {
    let engine: CalendarEngine
    let calendar: CalCalendar
    @State private var name: String
    @State private var color: CalColor

    init(engine: CalendarEngine, calendar: CalCalendar) {
        self.engine = engine
        self.calendar = calendar
        _name = State(initialValue: calendar.name)
        _color = State(initialValue: calendar.color)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name (optional)", text: $name)
            } footer: {
                Text("Leave it empty to show your name. Everyone you share with sees this name and color.")
            }
            Section("Color") { ColorRow(selection: $color) }
        }
        .calendarBackdrop(engine)
        .navigationTitle("My calendar")
        .onDisappear {
            let n = name.trimmingCharacters(in: .whitespaces)
            if n != calendar.name || color != calendar.color {
                engine.renameOwnCalendar(n == calendar.name ? nil : String(n.prefix(60)), color: color == calendar.color ? nil : color)
            }
        }
    }
}

struct LabelsView: View {
    let engine: CalendarEngine
    @State private var newName = ""
    @State private var newColor: CalColor = .none

    var body: some View {
        List {
            Section {
                ForEach(engine.ownCalendar.map { engine.labels(of: $0.id) } ?? []) { l in
                    HStack {
                        Circle().fill(l.color == .none ? AnyShapeStyle(.quaternary) : AnyShapeStyle(CalTint(l.color))).frame(width: 12, height: 12)
                        Text(l.name)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { engine.deleteLabel(l) } }
                }
            } footer: {
                Text("Labels belong to your calendar: everyone you share with sees them. Deleting one keeps its events.")
            }
            Section("New label") {
                TextField("Name", text: $newName)
                ColorRow(selection: $newColor)
                Button("Add") {
                    engine.saveLabel(name: newName.trimmingCharacters(in: .whitespaces), color: newColor)
                    newName = ""
                    newColor = .none
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .calendarBackdrop(engine)
        .navigationTitle("Labels")
    }
}

/// Who can see (or edit) your calendar. Online only.
struct SharingView: View {
    let engine: CalendarEngine
    @State private var grants: [CalGrant] = []
    @State private var contacts: [CalContact] = []
    @State private var error: String?
    @State private var picking = false

    var body: some View {
        List {
            Section {
                if grants.isEmpty { Text("Only you can see your calendar.").foregroundStyle(.secondary) }
                ForEach(grants) { g in
                    HStack(spacing: 10) {
                        CalAvatar(contact: engine.people[g.granteeID], fallbackName: name(g.granteeID), tint: .gray, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name(g.granteeID))
                            Text(g.role == .edit ? "Can add and change events" : "Can view")
                                .font(.caption).foregroundStyle(.secondary)
                            if let until = g.expiresAt {
                                Text("Until \(until.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Stop Sharing", role: .destructive) { Task { await revoke(g) } }
                        Button(g.role == .edit ? "View Only" : "Allow Editing") { Task { await setRole(g, g.role == .edit ? .view : .edit) } }
                            .tint(.blue)
                    }
                }
            } footer: {
                Text("People you share with see every event on your calendar. Sharing starts as view only.")
            }
            Section { Button("Share…") { picking = true } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .calendarBackdrop(engine)
        .navigationTitle("Sharing")
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $picking) {
            NavigationStack {
                // The picker loads its own contacts: a list handed into a sheet
                // from here arrived empty (stale copy) in the Lab.
                ShareWithView(engine: engine, excluding: Set(grants.map(\.granteeID) + [engine.config.currentUserID])) { who, role, until in
                    picking = false
                    Task {
                        do { try await engine.share(with: who.id, role: role, until: until); await load() }
                        catch { self.error = "Couldn't share: \(describe(error))" }
                    }
                }
            }
            .calendarAccent(engine.accentColor)
        }
    }

    private func name(_ id: UUID) -> String { engine.people[id]?.name ?? contacts.first { $0.id == id }?.name ?? "Someone" }

    private func load() async {
        do {
            async let g = engine.grants()
            async let c = engine.contacts()
            (grants, contacts) = try await (g, c)
            uiLog.notice("sharing loaded: \(grants.count, privacy: .public) shares, \(contacts.count, privacy: .public) contacts")
            error = nil
        } catch {
            uiLog.error("sharing load failed: \(String(describing: error), privacy: .public)")
            self.error = "Couldn't load sharing: \(describe(error))"
        }
    }

    private func revoke(_ g: CalGrant) async {
        do { try await engine.revoke(g); await load() } catch { self.error = "Couldn't stop sharing: \(describe(error))" }
    }

    private func setRole(_ g: CalGrant, _ role: CalRole) async {
        do { try await engine.share(with: g.granteeID, role: role, until: g.expiresAt, note: g.label); await load() }
        catch { self.error = "Couldn't change it: \(describe(error))" }
    }

    private func describe(_ e: Error) -> String {
        guard let t = e as? CalTransportError else { return "try again" }
        switch t {
        case .notFound: return "they aren't in your contacts"
        case .limit: return "you've shared with as many people as you can"
        case .unavailable: return "can't reach the calendar"
        default: return "try again"
        }
    }
}

struct ShareWithView: View {
    let engine: CalendarEngine
    let excluding: Set<UUID>
    let done: (CalContact, CalRole, Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [CalContact]?
    @State private var loadError: String?
    @State private var chosen: CalContact?
    @State private var canEdit = false
    @State private var hasEnd = false
    @State private var end = Date().addingTimeInterval(7 * 86_400)

    var body: some View {
        Form {
            Section("Share with") {
                if let loadError { Text(loadError).foregroundStyle(.red) }
                else if people == nil { ProgressView() }
                else if people?.isEmpty == true { Text("No one else to share with.").foregroundStyle(.secondary) }
                ForEach(people ?? []) { p in
                    Button { chosen = p } label: {
                        HStack {
                            CalAvatar(contact: p, fallbackName: p.name, tint: .gray, size: 28)
                            Text(p.name).foregroundStyle(.primary)
                            Spacer()
                            if chosen?.id == p.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            Section {
                Toggle("Can add and change events", isOn: $canEdit)
                Toggle("End sharing on a date", isOn: $hasEnd)
                if hasEnd { DatePicker("Ends", selection: $end, in: Date()...) }
            }
        }
        .calendarBackdrop(engine)
        .navigationTitle("Share")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                people = try await engine.contacts().filter { !excluding.contains($0.id) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                loadError = "Couldn't load your contacts."
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Share") { if let c = chosen { done(c, canEdit ? .edit : .view, hasEnd ? end : nil) } }.disabled(chosen == nil)
            }
        }
    }
}

struct ActivityView: View {
    let engine: CalendarEngine
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

    private func who(_ id: UUID?) -> String { id.flatMap { engine.people[$0]?.name } ?? "Someone" }

    private func sentence(_ a: CalActivity) -> String {
        switch a.kind {
        case "event_added": return "\(who(a.actorID)) added “\(a.detail)”"
        case "event_changed": return "\(who(a.actorID)) changed “\(a.detail)”"
        case "event_deleted": return "\(who(a.actorID)) deleted “\(a.detail)”"
        case "share":
            let parts = a.detail.split(separator: " ")
            let person = parts.first.flatMap { UUID(uuidString: String($0)) }
            return "Shared with \(who(person))" + (parts.last == "edit" ? " (can edit)" : " (view only)")
        case "unshare":
            let parts = a.detail.split(separator: " ")
            let person = parts.first.flatMap { UUID(uuidString: String($0)) }
            let why = parts.dropFirst().joined(separator: " ")
            return "Stopped sharing with \(who(person))" + (why == "revoked" || why.isEmpty ? "" : " (\(why))")
        default: return a.detail
        }
    }

    private func load(more: Bool) async {
        do {
            let r = try await engine.activity(cursor: more ? next : nil)
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
