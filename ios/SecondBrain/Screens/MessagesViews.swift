import SecondBrainKit
import SwiftUI

// MARK: - Activity (Mail-style)

struct ActivityView: View {
    var initialStatus: String?
    @State private var status: String?
    @State private var query = ""
    @State private var debounced = ""
    @State private var statuses: [Activity.StatusOption] = []
    @State private var appeared = false

    var body: some View {
        Loader({ [status, debounced] api in try await api.activity(query: debounced, status: status) }) { a in
            List {
                if a.events.isEmpty {
                    if debounced.isEmpty { ContentUnavailableView("No Messages", systemImage: "tray") }
                    else { ContentUnavailableView.search(text: debounced) }
                }
                ForEach(a.events) { m in
                    NavigationLink(value: Route.event(m.id)) { MessageRow(m: m) }
                }
            }
            .listStyle(.plain)
            .onAppear { statuses = a.statuses.filter { (a.counts[$0.key] ?? 0) > 0 } }
        }
        .id("\(status ?? "")|\(debounced)")
        .navigationTitle(status.flatMap { s in statuses.first { $0.key == s }?.label } ?? "Activity")
        .searchable(text: $query, prompt: "Search messages")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { debounced = query }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $status) {
                        Text("All Messages").tag(String?.none)
                        ForEach(statuses) { s in Text(s.label).tag(Optional(s.key)) }
                    }
                } label: {
                    Image(systemName: status == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter")
            }
        }
        .onAppear { if !appeared { status = initialStatus; appeared = true } }
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.source == "capture" ? "Quick capture" : (m.fromMe ? "You → " : "") + (m.sender ?? "?"))
                            .font(.headline)
                        Text(BrainDate.parse(m.receivedAt).map { "\(BrainDate.niceDay($0)) at \(BrainDate.time($0))" } ?? "")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(m.statusLabel, systemImage: Symbols.status(m.status).0)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Symbols.status(m.status).1)
                        .font(.title3)
                        .accessibilityLabel(m.statusLabel)
                }
                if let s = m.subject { Text(s).font(.headline) }
                Text(m.text).textSelection(.enabled)
                if !d.context.isEmpty {
                    DisclosureGroup("Earlier in the chat") {
                        ForEach(Array(d.context.enumerated()), id: \.offset) { _, c in
                            Text(c).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if d.can.approve || d.can.reject {
                Section {
                    ForEach(d.proposals) { p in
                        Label(p.title, systemImage: p.op == "create_event" ? "calendar" : "circle")
                    }
                    HStack(spacing: 10) {
                        if d.can.approve {
                            Button { act("approve", "Added") } label: { Text("Add").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent).tint(.green)
                        }
                        if d.can.reject {
                            Button { act("reject", "Skipped") } label: { Text("Skip").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                } header: {
                    HeaderRow("Waiting for You")
                } footer: {
                    if !d.reasons.isEmpty { Text(d.reasons.joined(separator: "\n")) }
                }
                .headerProminence(.increased)
            }

            if !d.items.isEmpty {
                Section {
                    ForEach(d.items) { it in ReminderRow(item: it) }
                } header: {
                    HeaderRow("What It Made")
                }
                .headerProminence(.increased)
            }

            if let r = d.reasoning, !r.isEmpty {
                Section("Why") { Text(r) }
            }

            Section {
                ForEach(d.trace) { t in
                    Label {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.label)
                                if let s = t.summary, !s.isEmpty { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let ms = t.durationMs { Text("\(ms) ms").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: icon(t.step)).foregroundStyle(color(t.step))
                    }
                }
            } header: {
                Text("How It Was Handled")
            } footer: {
                let total = d.trace.compactMap(\.durationMs).reduce(0, +)
                Text("\(d.trace.count) steps" + (total > 0 ? " · \(total) ms" : "") + (d.promptVersion.map { " · \($0)" } ?? ""))
            }

            if !d.commands.isEmpty {
                Section("Sent to the Mac") {
                    ForEach(d.commands) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(c.title ?? c.op.replacingOccurrences(of: "_", with: " ")).lineLimit(1)
                                Spacer()
                                Text(c.status.capitalized).font(.subheadline)
                                    .foregroundStyle(c.status == "done" ? Color.green : c.status == "failed" ? Color.red : Color.secondary)
                            }
                            Text(c.op.replacingOccurrences(of: "_", with: " ") + (c.undo ? " (undo)" : ""))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let e = c.error { Text(e).font(.subheadline).foregroundStyle(.red) }
                        }
                    }
                }
            }
            if let err = d.lastError {
                Section("Last Error") { Text(err).font(.footnote.monospaced()).foregroundStyle(.red) }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if d.can.undo {
                        Button(role: .destructive) { confirmUndo = true } label: { Label("Undo Everything", systemImage: "arrow.uturn.backward") }
                    }
                    if d.can.retry {
                        Button { act("retry", "Reprocessing") } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    }
                    Button { editing = true } label: { Label("Edit & Reprocess", systemImage: "pencil") }
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
        case "review", "undo": return .orange
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
                .navigationTitle("Edit Extraction")
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
