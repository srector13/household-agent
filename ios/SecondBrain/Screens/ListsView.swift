import SecondBrainKit
import SwiftUI

struct ListsView: View {
    @State private var tab = "todos"

    var body: some View {
        Loader({ api in try await api.items(tab: tab) }) { page in
            ItemsList(page: page, tab: tab)
        }
        .id(tab)
        .navigationTitle("Lists")
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $tab) {
                Text("To-dos & events").tag("todos")
                Text("Collections").tag("collections")
                Text("Done").tag("history")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)
            .accessibilityIdentifier("lists-tabs")
        }
    }
}

private struct ItemsList: View {
    let page: ItemsPage
    let tab: String

    var body: some View {
        List {
            if tab == "collections" {
                if page.groups.isEmpty {
                    ContentUnavailableView("No saved notes yet", systemImage: "gift",
                                           description: Text("When someone mentions a gift idea, a place to try or a show to watch, it lands here — and in its own Reminders list."))
                }
                ForEach(page.groups) { g in
                    ForEach(g.people) { p in
                        Section {
                            ForEach(p.items) { it in ItemCard(item: it).itemActions(ItemRef(it)) }
                        } header: {
                            HStack {
                                Text(g.label ?? g.key)
                                Text("· \(p.person)").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(p.items.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                if page.items.isEmpty {
                    ContentUnavailableView(tab == "todos" ? "Nothing here yet" : "Nothing finished yet",
                                           systemImage: "checklist")
                }
                Section {
                    ForEach(page.items) { it in ItemCard(item: it).itemActions(ItemRef(it)) }
                } header: {
                    if !page.items.isEmpty {
                        Text(tab == "todos" ? "\(page.counts["todos"] ?? page.items.count) open" : "Done & cancelled")
                    }
                }
                if tab == "todos" && !page.upcoming.isEmpty {
                    Section("Next 14 days") {
                        ForEach(page.upcoming) { u in AgendaRow(u: u) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// A full item: what it is, where it lives in Reminders/Calendar, why it exists, its history.
struct ItemCard: View {
    @Environment(AppModel.self) private var app
    let item: Item
    @State private var showLog = false
    @State private var busy = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: Symbols.item(item), color: Color.category(item), size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.body.weight(.semibold))
                        .strikethrough(item.isGone).foregroundStyle(item.isGone ? .secondary : .primary)
                    Spacer(minLength: 4)
                    statusPill
                }
                if item.category == "promise" { Pill(text: "promise", color: .teal) }
                if item.category == "waiting" { Pill(text: "waiting on \(item.person ?? "someone")", color: .blue) }
                Text(whereText).font(.subheadline).foregroundStyle(.secondary)
                if let step = item.firstStep {
                    Label { Text("**Start:** \(step)") } icon: { Image(systemName: "shoeprints.fill") }
                        .font(.caption).foregroundStyle(.green)
                } else if item.isReminder && item.isOpen && item.collection == nil && item.category != "waiting" && item.status != "proposed" {
                    Button {
                        Task {
                            busy = true
                            let id = item.id
                            await app.run("Steps added to the reminder") { _ = try await $0.breakdown(id) }
                            busy = false
                        }
                    } label: {
                        Label(busy ? "Thinking…" : "Break it down", systemImage: "shoeprints.fill").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                }
                if let o = item.origin {
                    Text("\(o.fromMe ? "You" : (o.sender ?? "?")): “\(o.text)”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 14) {
                    if let ev = item.originEventId {
                        NavigationLink(value: Route.event(ev)) { Text("Message").font(.caption.weight(.semibold)) }
                            .buttonStyle(.borderless)
                    }
                    if let u = item.url, let url = URL(string: u) {
                        Link(destination: url) { Label("Link", systemImage: "link").font(.caption.weight(.semibold)) }
                            .buttonStyle(.borderless)
                    }
                    if let log = item.log, log.count > 1 {
                        Button { withAnimation { showLog.toggle() } } label: {
                            Text("History (\(log.count))").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if showLog, let log = item.log {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, h in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(BrainDate.ago(h.at)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                Text(h.action).bold()
                                if let d = h.detail { Text(d).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(8)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 10))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch item.status {
            case "active": return ("on Mac", .green)
            case "planned": return ("sending", .blue)
            case "proposed": return ("in review", .orange)
            case "failed": return ("failed", .red)
            case "deleted": return ("deleted in Reminders", .secondary)
            default: return (item.status, .secondary)
            }
        }()
        return Pill(text: text, color: color)
    }

    private var whereText: String {
        var parts: [String] = []
        if item.kind == "event" {
            if let l = item.list { parts.append(l) }
            if let s = BrainDate.parse(item.start) {
                parts.append(item.allDay ? BrainDate.niceDay(s) : "\(BrainDate.niceDay(s)), \(BrainDate.time(s))")
            }
            if let loc = item.location { parts.append(loc) }
        } else {
            var place = item.list ?? "Reminders"
            if let sec = item.section { place += " › \(sec)" }
            parts.append(place + item.tags.map { " #\($0)" }.joined())
            if let due = BrainDate.due(item.due, item.dueTime) { parts.append("due \(due)") }
        }
        if item.section == nil && item.tags.isEmpty, let p = item.person { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}
