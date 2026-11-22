import SecondBrainKit
import SwiftUI

struct PeopleView: View {
    var body: some View {
        Loader({ try await $0.people() }) { people in
            let watched = people.filter { !$0.mentioned }
            let mentioned = people.filter(\.mentioned)
            List {
                if people.isEmpty {
                    ContentUnavailableView("No one yet", systemImage: "person.2",
                                           description: Text("Add people to watch in Settings → People & chats."))
                }
                if !watched.isEmpty {
                    Section {
                        ForEach(watched) { p in PersonRow(p: p) }
                    } footer: {
                        Text("Who you're keeping track of — promises, gift ideas, and what you know.")
                    }
                }
                if !mentioned.isEmpty {
                    Section("Also mentioned") {
                        ForEach(mentioned) { p in PersonRow(p: p) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("People")
    }
}

private struct PersonRow: View {
    let p: Person

    var body: some View {
        NavigationLink(value: Route.person(p.key)) {
            HStack(spacing: 12) {
                AvatarView(name: p.label, photo: p.photo, size: 44, symbol: p.group ? "person.3.fill" : nil)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(p.label).font(.headline)
                        if let c = p.contactName, c != p.label { Text("· \(c)").foregroundStyle(.secondary) }
                    }
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if p.promises > 0 { parts.append("🤝 \(p.promises)") }
        if p.waiting > 0 { parts.append("⏳ \(p.waiting)") }
        if p.todos > 0 { parts.append("☑️ \(p.todos)") }
        if p.gifts > 0 { parts.append("🎁 \(p.gifts)") }
        if p.facts > 0 { parts.append("👤 \(p.facts)") }
        let counts = parts.joined(separator: " ")
        let last = p.last.map { BrainDate.ago($0) } ?? (p.mentioned ? "mentioned in your messages" : nil)
        return [counts.nonEmpty, last].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "nothing yet"
    }
}

struct PersonView: View {
    let key: String

    var body: some View {
        Loader({ try await $0.person(key) }) { d in
            PersonDetailList(d: d)
                .navigationTitle(d.person.label)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PersonDetailList: View {
    let d: PersonDetail

    var body: some View {
        let p = d.person
        List {
            Section {
                VStack(spacing: 8) {
                    AvatarView(name: p.label, photo: p.photo, size: 96, symbol: p.group ? "person.3.fill" : nil)
                    Text(p.label).font(.title2.bold())
                    Text(caption).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            section("🤝 You promised \(p.label)", d.promises)
            section("⏳ Waiting on \(p.label)", d.waiting)
            section("☑️ To-dos from \(p.label)", d.todos)
            section("🎁 Gift ideas", d.gifts)
            section("👤 Things to remember", d.facts)
            section("🔖 Saved", d.other)
            if [d.promises, d.waiting, d.todos, d.gifts, d.facts, d.other].allSatisfy(\.isEmpty) {
                Section { Text("Nothing open with \(p.label) right now.").foregroundStyle(.secondary) }
            }
            if !d.messages.isEmpty {
                Section("Recent messages") {
                    ForEach(d.messages) { m in
                        NavigationLink(value: Route.event(m.eventId)) { Bubble(m: m) }
                    }
                }
            }
            if !d.done.isEmpty {
                Section("Done lately") {
                    ForEach(d.done) { it in ItemLine(item: it) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { it in ItemLine(item: it).itemActions(ItemRef(it)) }
            } header: {
                HStack { Text(title); Spacer(); Text("\(items.count)").foregroundStyle(.secondary) }
            }
        }
    }

    private var caption: String {
        let p = d.person
        var parts: [String] = []
        if let c = p.contactName, c != p.label { parts.append(c) }
        if let last = p.last { parts.append("last message \(BrainDate.ago(last))") } else if p.mentioned { parts.append("mentioned in your messages") }
        return parts.joined(separator: " · ")
    }
}

/// A compact item row: check (for open reminders), title, when, link.
struct ItemLine: View {
    @Environment(AppModel.self) private var app
    let item: Item
    @State private var done: Bool?

    var body: some View {
        let isDone = done ?? item.isDone
        HStack(spacing: 12) {
            if item.isReminder && item.collection == nil && (item.isOpen || item.isDone) {
                Button {
                    let on = !isDone
                    done = on
                    let id = item.id
                    Task { if !(await app.run(on ? "Done" : nil) { try await $0.setDone(id, on) }) { done = nil } }
                } label: { CheckCircle(on: isDone) }
                .buttonStyle(.plain)
            } else {
                Image(systemName: Symbols.item(item)).foregroundStyle(Color.category(item)).frame(width: 24)
            }
            NavigationLink(value: Route.event(item.originEventId ?? "")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).strikethrough(isDone || item.isGone).foregroundStyle(isDone || item.isGone ? .secondary : .primary)
                    if let m = meta { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let u = item.url, let url = URL(string: u) {
                Link(destination: url) { Image(systemName: "link") }.buttonStyle(.borderless)
            }
        }
    }

    private var meta: String? {
        var parts: [String] = []
        if let due = BrainDate.due(item.due, item.dueTime) { parts.append((item.category == "waiting" ? "expected " : "due ") + due) }
        if let s = BrainDate.parse(item.start) {
            parts.append(item.allDay ? BrainDate.niceDay(s) : "\(BrainDate.niceDay(s)), \(BrainDate.time(s))")
        }
        if let c = item.collectionLabel, item.category != "collection" || parts.isEmpty { parts.append(c) }
        if let created = item.createdAt { parts.append(BrainDate.ago(created)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct Bubble: View {
    let m: PersonDetail.ChatMessage

    var body: some View {
        HStack {
            if m.fromMe { Spacer(minLength: 40) }
            Text(m.text)
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(m.fromMe ? Color.white : Color.primary)
                .background(m.fromMe ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color(uiColor: .secondarySystemFill)), in: .rect(cornerRadius: 18))
            if !m.fromMe { Spacer(minLength: 40) }
        }
    }
}
