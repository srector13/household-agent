import SecondBrainKit
import SwiftUI

/// What a row needs to act on an item.
struct ItemRef: Hashable {
    var id: String
    var kind: String = "reminder"
    var title: String
    var isDone = false
    var isOpen = true

    init(_ item: Item) {
        id = item.id; kind = item.kind; title = item.title; isDone = item.isDone; isOpen = item.isOpen && item.status != "proposed"
    }

    init(id: String, kind: String = "reminder", title: String, isDone: Bool = false, isOpen: Bool = true) {
        self.id = id; self.kind = kind; self.title = title; self.isDone = isDone; self.isOpen = isOpen
    }

    var isReminder: Bool { kind != "event" }
}

extension View {
    /// Mail-style swipes (right: Done; left: Later, Delete) and a long-press menu for an item row.
    func itemActions(_ ref: ItemRef) -> some View { modifier(ItemActions(ref: ref)) }
}

struct ItemActions: ViewModifier {
    @Environment(AppModel.self) private var app
    let ref: ItemRef
    @State private var options: SnoozeOptions?
    @State private var showSnooze = false
    @State private var showPicker = false
    @State private var confirmDelete = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if !ref.isOpen {
            content
        } else {
            content
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if ref.isReminder {
                        Button { Task { await done() } } label: { Label("Done", systemImage: "checkmark") }
                            .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { Task { await delete() } } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                    Button { Task { await later() } } label: {
                        Label(ref.isReminder ? "Later" : "Move", systemImage: "clock")
                    }
                    .tint(.orange)
                }
                .contextMenu {
                    if ref.isReminder {
                        Button { Task { await done() } } label: { Label("Mark done", systemImage: "checkmark.circle") }
                        Button { app.focusItem = ref.id } label: { Label("Focus on this", systemImage: "scope") }
                        Button { Task { await later() } } label: { Label("Remind me later…", systemImage: "clock") }
                    }
                    Button { Task { await pick() } } label: { Label(ref.isReminder ? "Pick a date…" : "Move…", systemImage: "calendar") }
                    Divider()
                    Button(role: .destructive) { Task { await delete() } } label: { Label("Delete", systemImage: "trash") }
                }
                .confirmationDialog("Remind me", isPresented: $showSnooze, titleVisibility: .visible, presenting: options) { o in
                    ForEach(o.options) { opt in
                        Button("\(opt.label) · \(opt.sub)") { Task { await snooze(opt.key) } }
                    }
                    Button("Pick a date & time…") { showPicker = true }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $showPicker) {
                    DatePickSheet(ref: ref, options: options)
                        .presentationDetents([.medium, .large])
                }
        }
    }

    private func done() async {
        let id = ref.id
        await app.run("Done", undo: { await app.run { try await $0.setDone(id, false) } }) { try await $0.setDone(id, true) }
    }

    private func delete() async {
        let id = ref.id
        await app.run("Deleted", undo: { await app.run("Restored") { try await $0.restore(id) } }) { try await $0.delete(id) }
    }

    private func load() async -> SnoozeOptions? {
        guard let api = app.api else { return nil }
        do { return try await api.snoozeOptions(ref.id) } catch {
            app.show(error.localizedDescription, error: true)
            return nil
        }
    }

    private func later() async {
        guard let o = await load() else { return }
        options = o
        if o.kind == "event" { showPicker = true } else { showSnooze = true }
    }

    private func pick() async {
        options = await load()
        if options != nil { showPicker = true }
    }

    private func snooze(_ key: String) async {
        let id = ref.id
        guard let api = app.api else { return }
        do {
            let r = try await api.snooze(id, key: key)
            app.show("Moved to \(r.label ?? "later")")
            app.changed()
        } catch {
            app.show(error.localizedDescription, error: true)
        }
    }
}

/// Choose a day (and maybe a time) for a reminder, or a new start for an event.
struct DatePickSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let ref: ItemRef
    var options: SnoozeOptions?
    @State private var date = Date()
    @State private var withTime = false
    @State private var busy = false

    var isEvent: Bool { (options?.kind ?? ref.kind) == "event" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ref.title).font(.headline)
                }
                if isEvent {
                    DatePicker("Starts", selection: $date)
                } else {
                    DatePicker("Day", selection: $date, displayedComponents: .date)
                    Toggle("At a time", isOn: $withTime.animation())
                    if withTime {
                        DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                    }
                    Section {
                        Button("Remove the date", role: .destructive) { Task { await save(clear: true) } }
                    }
                }
            }
            .navigationTitle(isEvent ? "Move" : "Pick a date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(clear: false) } }.bold().disabled(busy)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        if isEvent, let s = BrainDate.parse(options?.start) {
            date = s
        } else if let d = BrainDate.day(options?.due) {
            var c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            if let t = options?.dueTime?.split(separator: ":").compactMap({ Int($0) }), t.count == 2 {
                c.hour = t[0]; c.minute = t[1]; withTime = true
            } else {
                c.hour = 9
            }
            date = Calendar.current.date(from: c) ?? Date()
        }
    }

    private func save(clear: Bool) async {
        busy = true
        defer { busy = false }
        let id = ref.id, d = date, time = withTime, event = isEvent
        guard let api = app.api else { return }
        do {
            let r: ActionReply
            if clear {
                r = try await api.reschedule(id, due: nil)
            } else if event {
                r = try await api.reschedule(id, due: nil, start: BrainDate.localISO(d))
            } else {
                r = try await api.reschedule(id, due: BrainDate.dayString(d), dueTime: time ? BrainDate.timeString(d) : nil)
            }
            app.show(r.label == "No date" ? "Date removed" : "Moved to \(r.label ?? "then")")
            app.changed()
            dismiss()
        } catch {
            app.show(error.localizedDescription, error: true)
        }
    }
}
