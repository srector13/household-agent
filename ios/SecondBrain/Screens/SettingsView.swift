import SecondBrainKit
import SwiftUI

/// Holds the brain's settings while you edit them; every change is saved right away (like iOS Settings).
@MainActor
@Observable
final class SettingsStore {
    var values: [String: JSONValue]
    var sources: [String: String]
    var saving = false
    @ObservationIgnored weak var app: AppModel?

    init(_ s: SettingsSnapshot, app: AppModel) {
        values = s.values
        sources = s.sources
        self.app = app
    }

    subscript(path: String) -> JSONValue { values[path] ?? .null }

    func string(_ p: String) -> String { values[p]?.string ?? "" }
    func bool(_ p: String) -> Bool { values[p]?.bool ?? false }
    func int(_ p: String) -> Int { values[p]?.int ?? 0 }
    func double(_ p: String) -> Double { values[p]?.double ?? 0 }
    func isFromFile(_ p: String) -> Bool { sources[p] == "file" || sources[p] == "env" }

    /// Saves one setting. On failure the old value comes back and the reason is shown.
    func set(_ path: String, _ value: JSONValue) {
        let old = values[path]
        values[path] = value
        Task { await save(.nested(path, value), revert: { self.values[path] = old }) }
    }

    func save(_ patch: JSONValue, revert: (() -> Void)? = nil) async {
        guard let api = app?.api else { return }
        saving = true
        defer { saving = false }
        do {
            let v = try await api.patchSettings(patch)
            values = v.values
            sources = v.sources
            app?.show("Saved")
            app?.changed()
        } catch {
            revert?()
            app?.show(error.localizedDescription, error: true)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Loader({ try await $0.settings() }) { s in SettingsRoot(store: SettingsStore(s, app: app)) }
            .navigationTitle("Settings")
    }
}

private struct SettingsRoot: View {
    @State var store: SettingsStore

    var body: some View {
        List {
            Section {
                page("People & chats", "person.2.fill", .green) { PeoplePage(store: store) }
                page("Notifications", "bell.badge.fill", .red) { NotificationsPage(store: store) }
                page("Daily rhythm", "sun.max.fill", .orange) { DailyPage(store: store) }
            }
            Section {
                page("Reminders & calendar", "checklist", .blue) { RulesPage(store: store) }
                page("Collections", "gift.fill", .orange) { CollectionsPage(store: store) }
            }
            Section {
                page("Model", "sparkles", .teal) { ModelPage(store: store) }
                page("Alerts & app", "app.badge.fill", .gray) { AlertsPage(store: store) }
                page("Mail", "envelope.fill", .blue) { MailPage(store: store) }
            } footer: {
                Text("Changes apply right away — no restart needed. Settings from the config file show “from file” until you change them here.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func page<V: View>(_ title: String, _ symbol: String, _ color: Color, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink {
            dest().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } label: {
            Label { Text(title) } icon: { IconTile(symbol: symbol, color: color, size: 29) }
        }
    }
}

// MARK: - Field editors

private struct ToggleField: View {
    let store: SettingsStore
    let path: String
    let label: String
    var help: String?

    var body: some View {
        Toggle(isOn: Binding(get: { store.bool(path) }, set: { store.set(path, .bool($0)) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct TextFieldRow: View {
    let store: SettingsStore
    let path: String
    let label: String
    var placeholder = ""
    var help: String?
    var keyboard: UIKeyboardType = .default
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            if let help { Text(help).font(.caption2).foregroundStyle(.secondary) }
        }
        .onAppear { text = store[path].string ?? store[path].display.replacingOccurrences(of: "—", with: "") }
    }

    private func commit() {
        let cur = store[path].string ?? ""
        guard text != cur else { return }
        store.set(path, .string(text))
    }
}

private struct NumberField: View {
    let store: SettingsStore
    let path: String
    let label: String
    var decimal = false
    var help: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                TextField("0", text: $text)
                    .keyboardType(decimal ? .decimalPad : .numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .focused($focused)
                    .onChange(of: focused) { _, f in if !f { commit() } }
            }
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { text = store[path].display == "—" ? "" : store[path].display }
    }

    private func commit() {
        guard let n = Double(text.replacingOccurrences(of: ",", with: ".")), n != store[path].double else { return }
        store.set(path, .number(decimal ? n : n.rounded()))
    }
}

private struct TimeField: View {
    let store: SettingsStore
    let path: String
    let label: String

    var body: some View {
        DatePicker(label, selection: Binding(get: { date(store.string(path)) }, set: { store.set(path, .string(BrainDate.timeString($0))) }),
                   displayedComponents: .hourAndMinute)
    }

    private func date(_ hhmm: String) -> Date {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = p.first ?? 9
        c.minute = p.count > 1 ? p[1] : 0
        return Calendar.current.date(from: c) ?? Date()
    }
}

private struct SecretField: View {
    let store: SettingsStore
    let path: String
    let label: String
    var help: String?
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !store[path].isNull {
                    Button("Clear", role: .destructive) { store.set(path, .null) }.font(.caption).buttonStyle(.borderless)
                }
            }
            SecureField(store[path].isNull ? "not set" : "•••••••• saved — type to replace", text: $text)
                .onSubmit {
                    guard !text.isEmpty else { return }
                    store.set(path, .string(text))
                    text = ""
                }
            if let help { Text(help).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

private struct ListField: View {
    let store: SettingsStore
    let path: String
    let label: String
    var placeholder = "Add…"
    @State private var newValue = ""

    var items: [String] { store[path].array?.compactMap(\.string) ?? [] }

    var body: some View {
        Section(label) {
            ForEach(items, id: \.self) { v in Text(v).font(.body.monospaced()) }
                .onDelete { idx in
                    var a = items
                    a.remove(atOffsets: idx)
                    store.set(path, .array(a.map { .string($0) }))
                }
            HStack {
                TextField(placeholder, text: $newValue).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add", action: add).disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let v = newValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        store.set(path, .array((items + [v]).map { .string($0) }))
        newValue = ""
    }
}

// MARK: - Pages

private struct PeoplePage: View {
    let store: SettingsStore
    @State private var editing: EditEntry?

    struct EditEntry: Identifiable {
        let id = UUID()
        var index: Int?
        var entry: [String: JSONValue]
    }

    var entries: [[String: JSONValue]] { store["watch.imessage.allow"].array?.compactMap(\.object) ?? [] }

    var body: some View {
        Form {
            Section {
                ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
                    Button { editing = EditEntry(index: i, entry: e) } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: e["label"]?.string, size: 34, symbol: e["chat_id"]?.string != nil ? "person.3.fill" : nil)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(e["label"]?.string ?? "Unnamed").foregroundStyle(.primary)
                                    if e["is_me"]?.bool == true { Pill(text: "this is me", color: .blue) }
                                    if e["enabled"]?.bool == false { Pill(text: "paused") }
                                }
                                Text(e["handle"]?.string ?? e["chat_id"]?.string ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    var a = entries
                    a.remove(atOffsets: idx)
                    store.set("watch.imessage.allow", .array(a.map { .object($0) }))
                }
                Button { editing = EditEntry(index: nil, entry: ["enabled": true, "is_me": false]) } label: {
                    Label("Add a person or group chat", systemImage: "plus")
                }
            } header: {
                Text("Watched")
            } footer: {
                Text("Only these conversations are read. Add your own number and mark it “This is me” to text yourself notes.")
            }
            Section {
                ToggleField(store: store, path: "watch.imessage.allow_self_notes", label: "Read my own messages in watched chats",
                            help: "Lets “I'll send it tonight” become a promise you track.")
            }
        }
        .sheet(item: $editing) { e in
            EntrySheet(entry: e.entry) { new in
                var a = entries
                if let i = e.index { a[i] = new } else { a.append(new) }
                store.set("watch.imessage.allow", .array(a.map { .object($0) }))
            }
        }
    }
}

private struct EntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: [String: JSONValue]
    let onSave: ([String: JSONValue]) -> Void

    private func text(_ k: String) -> Binding<String> {
        Binding(get: { entry[k]?.string ?? "" }, set: { entry[k] = $0.isEmpty ? .null : .string($0) })
    }

    private func flag(_ k: String) -> Binding<Bool> {
        Binding(get: { entry[k]?.bool ?? false }, set: { entry[k] = .bool($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Sarah)", text: text("label"))
                    TextField("Phone or email", text: text("handle"))
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("For a group chat, leave the phone empty and paste its chat id (shown on the Status page of the web dashboard).")
                }
                Section {
                    TextField("Group chat id (optional)", text: text("chat_id"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Toggle("Watching", isOn: flag("enabled"))
                    Toggle("This is me (notes to self)", isOn: flag("is_me"))
                }
            }
            .navigationTitle(entry["label"]?.string ?? "New person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(entry); dismiss() }
                        .bold()
                        .disabled((entry["handle"]?.string ?? entry["chat_id"]?.string ?? "").isEmpty)
                }
            }
        }
    }
}

private struct NotificationsPage: View {
    let store: SettingsStore

    var body: some View {
        Form {
            Section {
                ToggleField(store: store, path: "push.enabled", label: "Notifications")
            } footer: {
                Text("These decide what the brain notifies about — in this app and the web app. Turn notifications on for this phone under More → Server & notifications.")
            }
            Section("What to tell me about") {
                ToggleField(store: store, path: "push.new_items", label: "Something was added", help: "“Added to Reminders: Call the plumber · Tue”")
                ToggleField(store: store, path: "push.daily", label: "Today's three & the evening recap")
                ToggleField(store: store, path: "push.review", label: "Something needs a yes or no")
                ToggleField(store: store, path: "push.followups", label: "Follow-ups that are due")
                ToggleField(store: store, path: "push.weekly", label: "Weekly reset nudge")
                ToggleField(store: store, path: "push.system", label: "Problems (Mac offline, model down)", help: "Ignores quiet hours.")
            }
            Section {
                Toggle("Quiet hours", isOn: Binding(
                    get: { !store.string("push.quiet_start").isEmpty },
                    set: { on in
                        Task {
                            await store.save(.nested("push.quiet_start", .string(on ? "22:00" : ""))
                                .merged(with: .nested("push.quiet_end", .string(on ? "07:00" : ""))))
                        }
                    }))
                if !store.string("push.quiet_start").isEmpty {
                    TimeField(store: store, path: "push.quiet_start", label: "From")
                    TimeField(store: store, path: "push.quiet_end", label: "Until")
                }
            } footer: {
                Text("Held until morning, except problems and focus timers you started.")
            }
            Section {
                ToggleField(store: store, path: "push.discord_too", label: "Also send to Discord")
            }
        }
    }
}

private struct DailyPage: View {
    let store: SettingsStore
    private let days = [("mon", "Monday"), ("tue", "Tuesday"), ("wed", "Wednesday"), ("thu", "Thursday"),
                        ("fri", "Friday"), ("sat", "Saturday"), ("sun", "Sunday")]

    var body: some View {
        Form {
            Section {
                ToggleField(store: store, path: "daily.enabled", label: "Plan my day automatically")
                TimeField(store: store, path: "daily.morning_time", label: "Morning picks at")
                TimeField(store: store, path: "daily.evening_time", label: "Evening recap at")
                Stepper("\(store.int("daily.count")) things a day",
                        value: Binding(get: { store.int("daily.count") }, set: { store.set("daily.count", .from($0)) }), in: 1...7)
            } footer: {
                Text("A few things each morning, a short recap each evening. Unfinished picks move back off Today — no overdue pile. 3 is the sweet spot.")
            }
            Section {
                ToggleField(store: store, path: "daily.today_view", label: "Put the picks in Reminders' Today view",
                            help: "They get today's date while picked, and their old date back in the evening if not done.")
                ToggleField(store: store, path: "daily.discord", label: "Send the briefing and recap to Discord")
            }
            Section {
                Picker("Weekly reset on", selection: Binding(get: { store.string("daily.weekly_day") },
                                                             set: { store.set("daily.weekly_day", .string($0)) })) {
                    ForEach(days, id: \.0) { d in Text(d.1).tag(d.0) }
                }
                TimeField(store: store, path: "daily.weekly_time", label: "At")
            } footer: {
                Text("A 2-minute swipe through anything that's gone stale.")
            }
        }
    }
}

private struct RulesPage: View {
    let store: SettingsStore

    var body: some View {
        Form {
            Section("Reminders") {
                TextFieldRow(store: store, path: "rules.reminder_list", label: "Everything goes to this list")
                ToggleField(store: store, path: "rules.no_time_due_now", label: "No time given? Due right now",
                            help: "“Pack a bag for the kids” is due now, not later today.")
                TimeField(store: store, path: "rules.default_alert_time", label: "Later days with no time, remind me at")
                ToggleField(store: store, path: "rules.create_missing_lists", label: "Create lists that don't exist")
                ToggleField(store: store, path: "rules.person_tags", label: "File under the person (sections & tags)")
                ToggleField(store: store, path: "rules.person_in_title", label: "Also put the name in the title")
                ToggleField(store: store, path: "rules.breakdown", label: "Add a first step to big tasks")
            }
            Section("Promises & follow-ups") {
                ToggleField(store: store, path: "rules.track_promises", label: "Track promises I make")
                ToggleField(store: store, path: "rules.self_updates", label: "My replies can update or finish items")
                TextFieldRow(store: store, path: "rules.waiting_list", label: "Waiting-on list")
                NumberField(store: store, path: "rules.waiting_default_days", label: "Follow up after (days)")
                NumberField(store: store, path: "rules.open_item_days", label: "Items stay linkable (days)",
                            help: "How long a later message can still change an item.")
            }
            Section("Calendar") {
                TextFieldRow(store: store, path: "rules.calendars.default", label: "Calendar")
                NumberField(store: store, path: "rules.calendars.default_duration_min", label: "Default length (min)")
                NumberField(store: store, path: "rules.calendars.alert_minutes_before", label: "Alert before (min)")
            }
            Section {
                NumberField(store: store, path: "rules.review_threshold", label: "Ask me below confidence", decimal: true,
                            help: "0–1. Lower = fewer questions, more mistakes.")
            }
        }
    }
}

private struct CollectionsPage: View {
    let store: SettingsStore
    @State private var editing: EditCol?

    struct EditCol: Identifiable {
        let id = UUID()
        var index: Int?
        var c: [String: JSONValue]
    }

    var cols: [[String: JSONValue]] { store["collections"].array?.compactMap(\.object) ?? [] }

    var body: some View {
        Form {
            Section {
                ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                    HStack {
                        Button { editing = EditCol(index: i, c: c) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c["label"]?.string ?? c["key"]?.string ?? "?").foregroundStyle(.primary)
                                Text((c["list"]?.string ?? "") + (c["group_by_person"]?.bool == true ? " · by person" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { c["enabled"]?.bool ?? true }, set: { on in
                            var a = cols
                            a[i]["enabled"] = .bool(on)
                            store.set("collections", .array(a.map { .object($0) }))
                        }))
                        .labelsHidden()
                    }
                }
                Button { editing = EditCol(index: nil, c: ["enabled": true, "group_by_person": false]) } label: {
                    Label("Add a collection", systemImage: "plus")
                }
            } footer: {
                Text("Things worth keeping that aren't to-dos: gift ideas, places to try, shows to watch. Each has its own Reminders list.")
            }
        }
        .sheet(item: $editing) { e in
            CollectionSheet(c: e.c, isNew: e.index == nil) { new in
                var a = cols
                if let i = e.index { a[i] = new } else { a.append(new) }
                store.set("collections", .array(a.map { .object($0) }))
            }
        }
    }
}

private struct CollectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var c: [String: JSONValue]
    let isNew: Bool
    let onSave: ([String: JSONValue]) -> Void

    private func text(_ k: String) -> Binding<String> {
        Binding(get: { c[k]?.string ?? "" }, set: { c[k] = .string($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNew {
                        TextField("Key (e.g. books)", text: text("key")).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField("Name", text: text("label"))
                    TextField("Reminders list", text: text("list"))
                }
                Section {
                    TextField("What belongs here (the model reads this)", text: text("description"), axis: .vertical).lineLimit(3...8)
                } footer: {
                    Text("Be specific: “Restaurants, shops or trips someone suggests trying.”")
                }
                Section {
                    Toggle("One column per person", isOn: Binding(get: { c["group_by_person"]?.bool ?? false }, set: { c["group_by_person"] = .bool($0) }))
                    Toggle("On", isOn: Binding(get: { c["enabled"]?.bool ?? true }, set: { c["enabled"] = .bool($0) }))
                }
            }
            .navigationTitle(isNew ? "New collection" : (c["label"]?.string ?? "Collection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(c); dismiss() }.bold()
                        .disabled((c["key"]?.string ?? "").isEmpty || (c["label"]?.string ?? "").isEmpty)
                }
            }
        }
    }
}

private struct ModelPage: View {
    @Environment(AppModel.self) private var app
    let store: SettingsStore
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextFieldRow(store: store, path: "llm.base_url", label: "Server (OpenAI-compatible)", keyboard: .URL)
                TextFieldRow(store: store, path: "llm.model", label: "Model")
                SecretField(store: store, path: "llm.api_key", label: "API key", help: "Usually empty for your own vLLM.")
            }
            Section {
                NumberField(store: store, path: "llm.temperature", label: "Temperature", decimal: true)
                ToggleField(store: store, path: "llm.disable_thinking", label: "Skip “thinking” (faster)")
                NumberField(store: store, path: "llm.timeout_s", label: "Timeout (seconds)", decimal: true)
                NumberField(store: store, path: "llm.max_tokens", label: "Max tokens")
            }
            Section {
                Button {
                    testing = true
                    Task {
                        defer { testing = false }
                        guard let api = app.api else { return }
                        do {
                            let data = try await api.raw(try api.request("POST", "/api/settings/test-llm", body: Data("{}".utf8)))
                            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                            let models = (obj["models"] as? [String])?.joined(separator: ", ") ?? ""
                            result = "✅ Reachable · \(obj["latency_ms"] ?? "?") ms · \(models)"
                        } catch {
                            result = "❌ " + error.localizedDescription
                        }
                    }
                } label: { Text(testing ? "Testing…" : "Test the model") }
                if let result { Text(result).font(.caption) }
            }
        }
    }
}

private struct AlertsPage: View {
    let store: SettingsStore

    var body: some View {
        Form {
            Section("Discord") {
                SecretField(store: store, path: "alerts.discord_webhook_url", label: "Webhook URL")
                NumberField(store: store, path: "alerts.heartbeat_timeout_s", label: "Mac offline after (seconds)")
            }
            Section("App") {
                TextFieldRow(store: store, path: "dashboard.app_name", label: "Name")
                TextFieldRow(store: store, path: "dashboard.public_url", label: "Dashboard URL",
                             help: "Used in alert links, e.g. https://brain.your-tailnet.ts.net", keyboard: .URL)
                TextFieldRow(store: store, path: "timezone", label: "Time zone", placeholder: "America/Chicago")
            }
        }
    }
}

private struct MailPage: View {
    let store: SettingsStore

    var body: some View {
        Form {
            Section {
                ToggleField(store: store, path: "watch.mail.enabled", label: "Read mail")
                TextFieldRow(store: store, path: "watch.mail.host", label: "IMAP server", keyboard: .URL)
                NumberField(store: store, path: "watch.mail.port", label: "Port")
                TextFieldRow(store: store, path: "watch.mail.username", label: "Username", keyboard: .emailAddress)
                SecretField(store: store, path: "watch.mail.password", label: "Password (app-specific)")
            }
            ListField(store: store, path: "watch.mail.folders", label: "Folders", placeholder: "INBOX")
            ListField(store: store, path: "watch.mail.allow_senders", label: "Only from", placeholder: "*@school.example.org")
        }
    }
}
