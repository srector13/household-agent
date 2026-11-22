import SecondBrainKit
import SwiftUI

// MARK: - Review

struct ReviewView: View {
    var body: some View {
        Loader({ try await $0.review() }) { entries in
            List {
                if entries.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                           description: Text("Anything the model isn't sure about waits here for a yes or no."))
                }
                ForEach(entries) { e in ReviewCard(e: e) }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Review")
    }
}

private struct ReviewCard: View {
    @Environment(AppModel.self) private var app
    let e: ReviewEntry
    @State private var busy = false

    var body: some View {
        Section {
            NavigationLink(value: Route.event(e.event.id)) { MessageRow(m: e.event, showStatus: false) }
            ForEach(e.proposals) { p in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.body.weight(.medium))
                        Text(describe(p)).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: p.op == "create_event" ? "calendar" : p.collection != nil ? "bookmark" : "checklist")
                        .foregroundStyle(p.op == "create_event" ? .red : .green)
                }
            }
            if !e.reasons.isEmpty {
                Label(e.reasons.joined(separator: "\n"), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if !e.proposals.isEmpty {
                    Button { act("approve", "Added") } label: { Label("Add", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent).tint(.green)
                }
                Button { act("reject", "Skipped") } label: { Label("Skip", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
            }
            .disabled(busy)
        }
    }

    private func act(_ action: String, _ done: String) {
        busy = true
        let id = e.event.id
        Task {
            await app.run(done) { try await $0.eventAction(action, id) }
            busy = false
        }
    }

    private func describe(_ p: Proposal) -> String {
        var parts: [String] = []
        if let c = p.collection { parts.append(c) } else if let l = p.list { parts.append(l) }
        if let s = BrainDate.parse(p.start) {
            parts.append(p.allDay ? BrainDate.niceDay(s) : "\(BrainDate.niceDay(s)), \(BrainDate.time(s))")
        } else if let d = BrainDate.due(p.due, p.dueTime) {
            parts.append("due \(d)")
        }
        if let who = p.person { parts.append(who) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Activity

struct ActivityView: View {
    var initialStatus: String?
    @State private var status: String?
    @State private var query = ""
    @State private var debounced = ""

    var body: some View {
        Loader({ [status, debounced] api in try await api.activity(query: debounced, status: status) }) { a in
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            chip(nil, "All", a.counts.values.reduce(0, +))
                            ForEach(a.statuses) { s in
                                if let n = a.counts[s.key], n > 0 { chip(s.key, s.label, n) }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if a.events.isEmpty {
                    ContentUnavailableView.search(text: debounced)
                }
                ForEach(a.events) { m in
                    NavigationLink(value: Route.event(m.id)) { MessageRow(m: m) }
                }
            }
            .listStyle(.insetGrouped)
        }
        .id("\(status ?? "")|\(debounced)")
        .navigationTitle("Activity")
        .searchable(text: $query, prompt: "Search messages")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { debounced = query }
        }
        .onAppear { if status == nil { status = initialStatus } }
    }

    private func chip(_ key: String?, _ label: String, _ n: Int) -> some View {
        Button { status = key } label: {
            Text("\(label) \(n)").font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(status == key ? .regular.tint(.blue).interactive() : .regular.interactive(), in: .capsule)
        .foregroundStyle(status == key ? Color.white : Color.primary)
    }
}

struct MessageRow: View {
    let m: Message
    var showStatus = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if m.source == "mail" {
                AvatarView(name: m.sender, size: 38, symbol: "envelope.fill")
            } else if m.source == "capture" {
                AvatarView(name: "Me", size: 38, symbol: "plus.bubble.fill")
            } else if m.fromMe {
                AvatarView(name: "Me", size: 38, symbol: "arrowshape.turn.up.left.fill")
            } else {
                AvatarView(name: m.sender, photo: m.photo, size: 38)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(m.source == "capture" ? "Quick capture" : (m.fromMe ? "You → " : "") + (m.sender ?? "?"))
                        .font(.headline).lineLimit(1)
                    Spacer()
                    Text(BrainDate.ago(m.receivedAt)).font(.caption).foregroundStyle(.secondary)
                }
                Text((m.subject.map { "\($0) — " } ?? "") + m.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if !m.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(m.actions.prefix(3).enumerated()), id: \.offset) { _, a in
                            Pill(text: a.title, color: a.type == "create_event" ? .red : .green)
                        }
                    }
                }
                if showStatus && m.status != "done" {
                    Label(m.statusLabel + (m.reason.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""),
                          systemImage: Symbols.status(m.status).0)
                        .font(.caption).foregroundStyle(Symbols.status(m.status).1).lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Message detail

struct EventView: View {
    let eventId: String

    var body: some View {
        Loader({ try await $0.event(eventId) }) { d in
            EventDetailList(d: d)
        }
        .navigationTitle("Message")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EventDetailList: View {
    @Environment(AppModel.self) private var app
    let d: EventDetail
    @State private var confirmUndo = false
    @State private var editing = false

    var body: some View {
        let m = d.event
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(name: m.sender, photo: m.photo, size: 44,
                               symbol: m.source == "mail" ? "envelope.fill" : m.source == "capture" ? "plus.bubble.fill" : nil)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(m.source == "capture" ? "Quick capture" : (m.fromMe ? "You → " : "") + (m.sender ?? "?")).font(.headline)
                            Spacer()
                            Label(m.statusLabel, systemImage: Symbols.status(m.status).0)
                                .font(.caption.weight(.semibold)).foregroundStyle(Symbols.status(m.status).1)
                        }
                        if let s = m.subject { Text(s).font(.subheadline.weight(.semibold)) }
                        Text(m.text).textSelection(.enabled)
                        Text(BrainDate.parse(m.receivedAt).map { "\(BrainDate.niceDay($0)), \(BrainDate.time($0))" } ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !d.context.isEmpty {
                    DisclosureGroup("Earlier in the chat (\(d.context.count))") {
                        ForEach(Array(d.context.enumerated()), id: \.offset) { _, c in
                            Text(c).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !d.reasons.isEmpty || !d.proposals.isEmpty {
                Section("Waiting for you") {
                    ForEach(d.proposals) { p in Label(p.title, systemImage: p.op == "create_event" ? "calendar" : "checklist") }
                    ForEach(d.reasons, id: \.self) { r in Label(r, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                    if d.can.approve || d.can.reject {
                        HStack {
                            if d.can.approve {
                                Button { act("approve", "Added") } label: { Label("Add", systemImage: "checkmark").frame(maxWidth: .infinity) }
                                    .buttonStyle(.glassProminent).tint(.green)
                            }
                            if d.can.reject {
                                Button { act("reject", "Skipped") } label: { Label("Skip", systemImage: "xmark").frame(maxWidth: .infinity) }
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                }
            }

            if !d.items.isEmpty {
                Section("What it made") {
                    ForEach(d.items) { it in ItemLine(item: it).itemActions(ItemRef(it)) }
                }
            }

            if let r = d.reasoning, !r.isEmpty {
                Section("Why") { Text(r).font(.subheadline) }
            }

            Section {
                ForEach(d.trace) { t in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: icon(t.step)).foregroundStyle(color(t.step)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.label).font(.subheadline.weight(.semibold))
                            if let s = t.summary, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let ms = t.durationMs { Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
            } header: {
                HStack {
                    Text("Trace")
                    Spacer()
                    let total = d.trace.compactMap(\.durationMs).reduce(0, +)
                    Text("\(d.trace.count) steps" + (total > 0 ? " · \(total) ms" : "") + (d.promptVersion.map { " · \($0)" } ?? ""))
                        .textCase(nil)
                }
            }

            if !d.commands.isEmpty {
                Section("Sent to the Mac") {
                    ForEach(d.commands) { c in
                        HStack {
                            Text(c.op.replacingOccurrences(of: "_", with: " ") + (c.undo ? " (undo)" : ""))
                                .font(.subheadline)
                            if let t = c.title { Text(t).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer()
                            Pill(text: c.status, color: c.status == "done" ? .green : c.status == "failed" ? .red : .blue)
                        }
                        if let e = c.error { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            if let err = d.lastError {
                Section("Last error") { Text(err).font(.caption.monospaced()).foregroundStyle(.red) }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if d.can.approve {
                        Button { act("approve", "Added") } label: { Label("Add to Reminders", systemImage: "checkmark") }
                    }
                    if d.can.reject {
                        Button { act("reject", "Skipped") } label: { Label("Skip", systemImage: "xmark") }
                    }
                    if d.can.undo {
                        Button(role: .destructive) { confirmUndo = true } label: { Label("Undo everything", systemImage: "arrow.uturn.backward") }
                    }
                    if d.can.retry {
                        Button { act("retry", "Reprocessing") } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    }
                    Button { editing = true } label: { Label("Edit & reprocess", systemImage: "pencil") }
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("event-actions")
            }
        }
        .confirmationDialog("Undo what this message did?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Undo", role: .destructive) { act("undo", "Undone") }
        } message: {
            Text("Reminders and events it created are removed, changes are put back.")
        }
        .sheet(isPresented: $editing) { EditExtractionSheet(eventId: m.id, json: d.extraction) }
    }

    private func act(_ action: String, _ done: String) {
        let id = d.event.id
        Task { await app.run(done) { try await $0.eventAction(action, id) } }
    }

    private func icon(_ step: String) -> String {
        switch step {
        case "ingest": return "tray.and.arrow.down"
        case "allowlist": return "person.crop.circle.badge.checkmark"
        case "gate": return "line.3.horizontal.decrease.circle"
        case "extract": return "sparkles"
        case "extract_error": return "exclamationmark.triangle"
        case "plan": return "list.bullet.clipboard"
        case "queue", "command_sent": return "paperplane"
        case "command_result": return "laptopcomputer"
        case "review": return "hand.raised"
        case "undo": return "arrow.uturn.backward"
        default: return "circle"
        }
    }

    private func color(_ step: String) -> Color {
        switch step {
        case "extract_error": return .red
        case "review": return .orange
        case "undo": return .orange
        case "command_result": return .green
        default: return .blue
        }
    }
}

private struct EditExtractionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let eventId: String
    @State var json: String
    @State private var busy = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $json)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal)
                .navigationTitle("Edit extraction")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Reprocess") {
                            busy = true
                            let id = eventId, text = json
                            Task {
                                if await app.run("Reprocessing with your edits", { try await $0.reprocess(id, extraction: text) }) { dismiss() }
                                busy = false
                            }
                        }
                        .bold().disabled(busy)
                    }
                }
        }
    }
}
