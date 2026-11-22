import SecondBrainKit
import SwiftUI

// Content follows Apple's own iOS 26 apps (Reminders, Mail, Contacts): plain grouped lists, a
// check circle, one line of metadata, details in a sheet. Liquid Glass stays in the navigation
// layer (tab bar, toolbars) — never on rows or cards.

// MARK: - Reminders-style item row

/// One item, like a row in Reminders: check circle (or a symbol for events / saved notes), the
/// title, and one line of metadata. Tap for details; swipe or long-press for actions.
struct ReminderRow: View {
    @Environment(AppModel.self) private var app
    let item: Item
    var showPerson = true
    @State private var done: Bool?
    @State private var showDetail = false

    var body: some View {
        let isDone = done ?? item.isDone
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            leading(isDone)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .foregroundStyle(isDone || item.isGone ? .secondary : .primary)
                    .strikethrough(item.isGone)
                if let step = item.firstStep, item.isOpen {
                    Text("Start: \(step)").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if let meta = RowMeta.text(for: item, showPerson: showPerson) {
                    meta.font(.subheadline).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if item.url != nil {
                Image(systemName: "link").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) { ItemDetailSheet(item: item) }
        .itemActions(ItemRef(item))
    }

    @ViewBuilder
    private func leading(_ isDone: Bool) -> some View {
        if item.isReminder && item.collection == nil && (item.isOpen || item.isDone) && item.status != "proposed" {
            Button {
                let on = !isDone
                done = on
                let id = item.id
                Task { if !(await app.run(on ? "Done" : nil) { try await $0.setDone(id, on) }) { done = nil } }
            } label: {
                Image(systemName: isDone ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
        } else {
            Image(systemName: Symbols.item(item))
                .font(.body)
                .foregroundStyle(Color.category(item))
                .frame(width: 24)
        }
    }
}

/// The metadata line under a row: when (red if late) · where · who.
enum RowMeta {
    static func text(for item: Item, showPerson: Bool = true, now: Date = Date()) -> Text? {
        var parts: [Text] = []
        if item.kind == "event", let s = BrainDate.parse(item.start) {
            parts.append(Text(item.allDay ? BrainDate.niceDay(s) : "\(BrainDate.niceDay(s)), \(BrainDate.time(s))"))
        } else if let d = BrainDate.day(item.due) {
            let late = item.isOpen && Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: now)
            let when = BrainDate.due(item.due, item.dueTime, now: now) ?? ""
            parts.append(Text(item.category == "waiting" ? "Expected \(when)" : when).foregroundStyle(late ? Color.red : Color.secondary))
        }
        switch item.category {
        case "promise": parts.append(Text("Promised \(item.person ?? "")"))
        case "waiting": parts.append(Text("Waiting on \(item.person ?? "")"))
        default:
            if let c = item.collectionLabel { parts.append(Text(c)) }
            else if let l = item.list, item.kind == "event" || l != "Household" { parts.append(Text(l)) }
            if showPerson, let p = item.person { parts.append(Text(p)) }
        }
        guard !parts.isEmpty else { return nil }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text("  ·  ").foregroundStyle(.tertiary) + $1 }
            .foregroundStyle(.secondary)
    }
}

// MARK: - Item details (like Reminders' Details sheet)

struct ItemDetailSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let item: Item
    @State private var showDate = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(kindLabel, systemImage: Symbols.item(item))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.category(item))
                        Text(item.title).font(.title2.bold())
                        if let step = item.firstStep {
                            Text("Start: \(step)").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if item.kind == "event", let s = BrainDate.parse(item.start) {
                        LabeledContent("Starts", value: item.allDay ? BrainDate.niceDay(s) : "\(BrainDate.niceDay(s)), \(BrainDate.time(s))")
                        if let e = BrainDate.parse(item.end), !item.allDay { LabeledContent("Ends", value: BrainDate.time(e)) }
                        if let loc = item.location { LabeledContent("Location", value: loc) }
                    } else {
                        LabeledContent("Due", value: BrainDate.due(item.due, item.dueTime) ?? "No date")
                    }
                    if let l = item.list { LabeledContent(item.kind == "event" ? "Calendar" : "List", value: l + (item.section.map { " › \($0)" } ?? "")) }
                    if let p = item.person { LabeledContent(item.category == "waiting" ? "Waiting on" : "Person", value: p) }
                    if !item.tags.isEmpty { LabeledContent("Tags", value: item.tags.map { "#\($0)" }.joined(separator: " ")) }
                    if let u = item.url, let url = URL(string: u) {
                        Link(destination: url) { Label(url.host() ?? u, systemImage: "link") }
                    }
                }

                if !item.steps.isEmpty {
                    Section("Steps") {
                        ForEach(Array(item.steps.enumerated()), id: \.offset) { _, s in Label(s, systemImage: "circle") }
                    }
                }

                if let o = item.origin {
                    Section("Where it came from") {
                        Text("“\(o.text)”").italic()
                        if let ev = item.originEventId {
                            Button {
                                dismiss()
                                app.open(link: "/events/\(ev)")
                            } label: {
                                Label("Open \(o.fromMe ? "your" : (o.sender.map { "\($0)'s" } ?? "the")) message", systemImage: "message")
                            }
                        }
                    }
                }

                if item.isOpen && item.status != "proposed" {
                    Section {
                        if item.isReminder && item.collection == nil {
                            Button { Task { await act("Done") { try await $0.setDone(item.id, true) } } } label: {
                                Label("Mark done", systemImage: "checkmark.circle")
                            }
                            Button { dismiss(); app.focusItem = item.id } label: { Label("Focus on this", systemImage: "scope") }
                        }
                        Button { showDate = true } label: {
                            Label(item.kind == "event" ? "Move…" : "Change the date…", systemImage: "calendar")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                if let log = item.log, !log.isEmpty {
                    Section("History") {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, h in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.action.capitalized)
                                Text([BrainDate.ago(h.at), h.detail].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.bold() }
            }
            .sheet(isPresented: $showDate) { DatePickSheet(ref: ItemRef(item), options: nil) }
            .confirmationDialog("Delete “\(item.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let id = item.id
                    Task {
                        await app.run("Deleted", undo: { await app.run("Restored") { try await $0.restore(id) } }) { try await $0.delete(id) }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var kindLabel: String {
        switch item.category {
        case "promise": return "Promise"
        case "waiting": return "Waiting on"
        case "collection": return item.collectionLabel ?? "Saved"
        default: return item.kind == "event" ? "Event" : "Reminder"
        }
    }

    private func act(_ msg: String, _ body: @escaping (BrainAPI) async throws -> Void) async {
        if await app.run(msg, body) { dismiss() }
    }
}

// MARK: - Mail-style message row

struct MessageRow: View {
    let m: Message
    var showStatus = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(BrainDate.ago(m.receivedAt)).font(.subheadline).foregroundStyle(.secondary)
                }
                Text((m.subject.map { "\($0) — " } ?? "") + m.text)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if !m.actions.isEmpty {
                    Label(m.actions.map(\.title).joined(separator: ", "),
                          systemImage: m.actions.contains { $0.type == "create_event" } ? "calendar" : "checklist")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                if showStatus && m.status != "done" {
                    Label(m.statusLabel + (m.reason.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""),
                          systemImage: Symbols.status(m.status).0)
                        .font(.footnote).foregroundStyle(Symbols.status(m.status).1).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        if m.source == "capture" { return "Quick capture" }
        return (m.fromMe ? "You → " : "") + (m.sender ?? "?")
    }

    @ViewBuilder private var avatar: some View {
        switch m.source {
        case "mail": AvatarView(name: m.sender, size: 40, symbol: "envelope.fill")
        case "capture": AvatarView(name: "Me", size: 40, symbol: "plus.bubble.fill")
        default:
            if m.fromMe { AvatarView(name: "Me", size: 40, symbol: "arrowshape.turn.up.left.fill") }
            else { AvatarView(name: m.sender, photo: m.photo, size: 40) }
        }
    }
}

// MARK: - Section header with a trailing action

/// A title-case section header with an optional trailing control (like "Coming Up   See All").
struct HeaderRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            trailing().font(.subheadline.weight(.regular)).textCase(nil)
        }
        .textCase(nil)
    }
}

extension HeaderRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title, detail: detail) { EmptyView() }
    }
}
