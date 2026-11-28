import SecondBrainKit
import SwiftUI

struct ListsView: View {
    var body: some View {
        Loader({ api -> ListsOverview in
            async let todos = api.items(tab: "todos")
            async let cols = api.items(tab: "collections")
            return ListsOverview(todos: try await todos, collections: try await cols)
        }) { o in
            ListTiles(o: o)
        }
        .navigationTitle("Lists")
    }
}

private struct ListsOverview {
    var todos: ItemsPage
    var collections: ItemsPage
}

/// Like Reminders' smart lists: two big tiles, then a tile per collection saved from your messages.
private struct ListTiles: View {
    let o: ListsOverview
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let open = o.todos.items.filter { $0.status != "proposed" }
        let scheduled = open.filter { $0.due != nil || $0.start != nil }
        List {
            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    Tile(key: "scheduled", title: "Scheduled", count: scheduled.count, symbol: "calendar", color: .red)
                    Tile(key: "all", title: "All To-Dos", count: open.count, symbol: "tray.fill", color: .slate)
                    Tile(key: "waiting", title: "Waiting On", count: open.filter { $0.category == "waiting" }.count,
                         symbol: "hourglass", color: .blue)
                    Tile(key: "done", title: "Done", count: nil, symbol: "checkmark", color: .green)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !o.collections.groups.isEmpty {
                Section {
                    ForEach(o.collections.groups) { g in
                        let all = g.people.flatMap(\.items)
                        NavigationLink(value: Route.list("col:" + g.key)) {
                            HStack(spacing: 12) {
                                IconTile(symbol: symbol(g.key), color: color(g.key), size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.label ?? g.key)
                                    Text(preview(g)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(all.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } header: {
                    HeaderRow("Saved From Your Messages")
                }
                .headerProminence(.increased)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("lists-tiles")
    }

    private func preview(_ g: ItemsPage.Group) -> String {
        let people = g.people.map(\.person).filter { $0 != "Unassigned" }
        if g.key == "gift_ideas" || g.key == "about_person", !people.isEmpty { return people.joined(separator: ", ") }
        return g.people.flatMap(\.items).prefix(3).map(\.title).joined(separator: ", ")
    }

    private func symbol(_ key: String) -> String {
        switch key {
        case "gift_ideas": return "gift.fill"
        case "about_person": return "person.text.rectangle.fill"
        case "places": return "mappin.and.ellipse"
        case "watch_read", "media": return "play.rectangle.fill"
        case "recipes": return "fork.knife"
        case "someday": return "sparkles"
        default: return "bookmark.fill"
        }
    }

    private func color(_ key: String) -> Color {
        switch key {
        case "gift_ideas": return .orange
        case "about_person": return .teal
        case "places": return .red
        case "recipes": return .green
        case "someday": return .yellow
        default: return .blue
        }
    }
}

private struct Tile: View {
    let key: String
    let title: String
    let count: Int?
    let symbol: String
    let color: Color

    var body: some View {
        NavigationLink(value: Route.list(key)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32).background(color, in: .circle)
                    Spacer()
                    if let count { Text("\(count)").font(.title.bold()).monospacedDigit().foregroundStyle(.primary) }
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tile-\(key)")
    }
}

/// One list: Scheduled / All / Waiting On / Done, or a saved collection.
struct ListDetailView: View {
    let key: String

    var body: some View {
        Loader({ [key] api in try await api.items(tab: Self.tab(key)) }) { page in
            ItemsList(page: filtered(page), tab: Self.tab(key), mode: key)
        }
        .navigationTitle(title)
    }

    static func tab(_ key: String) -> String {
        key == "done" ? "history" : key.hasPrefix("col:") ? "collections" : "todos"
    }

    private var title: String {
        switch key {
        case "scheduled": return "Scheduled"
        case "all": return "All To-Dos"
        case "waiting": return "Waiting On"
        case "done": return "Done"
        default: return String(key.dropFirst(4)).replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func filtered(_ p: ItemsPage) -> ItemsPage {
        var p = p
        switch key {
        case "scheduled": p.items = p.items.filter { $0.due != nil || $0.start != nil || $0.status == "proposed" }
        case "waiting": p.items = p.items.filter { $0.category == "waiting" }
        default:
            if key.hasPrefix("col:") { p.groups = p.groups.filter { "col:" + $0.key == key } }
        }
        return p
    }
}

private struct ItemsList: View {
    let page: ItemsPage
    let tab: String
    var mode = ""

    var body: some View {
        List {
            switch tab {
            case "collections":
                if page.groups.isEmpty {
                    ContentUnavailableView("No saved notes yet", systemImage: "gift",
                                           description: Text("Gift ideas, places to try and shows to watch from your messages land here — and in their own Reminders lists."))
                }
                ForEach(page.groups) { g in
                    ForEach(g.people) { p in
                        Section {
                            ForEach(p.items) { it in ReminderRow(item: it, showPerson: false, showCollection: false) }
                        } header: {
                            HeaderRow(g.label ?? g.key, detail: p.person)
                        }
                        .headerProminence(.increased)
                    }
                }
            case "history":
                if page.items.isEmpty {
                    ContentUnavailableView("Nothing finished yet", systemImage: "checkmark.circle")
                }
                Section {
                    ForEach(page.items) { it in ReminderRow(item: it) }
                }
            default:
                if page.items.isEmpty {
                    ContentUnavailableView("All clear", systemImage: "checklist",
                                           description: Text("To-dos and events from your messages show up here."))
                }
                ForEach(buckets) { b in
                    Section {
                        ForEach(b.items) { it in ReminderRow(item: it) }
                    } header: {
                        HeaderRow(b.title, detail: "\(b.items.count)")
                            .foregroundStyle(b.title == "Overdue" ? Color.red : Color.primary)
                    }
                    .headerProminence(.increased)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    struct Bucket: Identifiable {
        let title: String
        var items: [Item]
        var id: String { title }
    }

    /// Like Reminders' Scheduled list: Overdue, Today, Tomorrow, Upcoming, No Date.
    private var buckets: [Bucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var b: [String: [Item]] = [:]
        for it in page.items {
            let d: Date?
            if it.kind == "event" { d = BrainDate.parse(it.start).map { cal.startOfDay(for: $0) } }
            else { d = BrainDate.day(it.due) }
            let key: String
            if it.status == "proposed" { key = "Waiting for Review" }
            else if let d {
                let days = cal.dateComponents([.day], from: today, to: d).day ?? 0
                key = days < 0 ? "Overdue" : days == 0 ? "Today" : days == 1 ? "Tomorrow" : "Upcoming"
            } else {
                key = "No Date"
            }
            b[key, default: []].append(it)
        }
        func when(_ it: Item) -> Date {
            BrainDate.parse(it.start) ?? BrainDate.parse(it.due.map { $0 + "T" + (it.dueTime ?? "23:59") }) ?? .distantFuture
        }
        return ["Overdue", "Today", "Tomorrow", "Upcoming", "No Date", "Waiting for Review"].compactMap { k in
            b[k].map { Bucket(title: k, items: $0.sorted { when($0) < when($1) }) }
        }
    }
}
