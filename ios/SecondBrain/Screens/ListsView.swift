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
        .safeAreaBar(edge: .top) {
            Picker("Show", selection: $tab) {
                Text("Scheduled").tag("todos")
                Text("Collections").tag("collections")
                Text("Done").tag("history")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("lists-tabs")
        }
    }
}

private struct ItemsList: View {
    let page: ItemsPage
    let tab: String

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
