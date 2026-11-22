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
                                           description: Text("Add people to watch in Settings → People & Chats."))
                }
                if !watched.isEmpty {
                    Section {
                        ForEach(watched) { p in PersonRow(p: p) }
                    }
                }
                if !mentioned.isEmpty {
                    Section {
                        ForEach(mentioned) { p in PersonRow(p: p) }
                    } header: {
                        HeaderRow("Also Mentioned")
                    }
                    .headerProminence(.increased)
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
                    Text(p.label).font(.body.weight(.semibold))
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if p.promises > 0 { parts.append("\(p.promises) promise\(p.promises == 1 ? "" : "s")") }
        if p.waiting > 0 { parts.append("waiting on \(p.waiting)") }
        if p.todos > 0 { parts.append("\(p.todos) to-do\(p.todos == 1 ? "" : "s")") }
        if p.gifts > 0 { parts.append("\(p.gifts) gift idea\(p.gifts == 1 ? "" : "s")") }
        if parts.isEmpty, let last = p.last { return "Last message \(BrainDate.ago(last))" }
        if parts.isEmpty { return p.mentioned ? "Mentioned in your messages" : "Nothing open" }
        return parts.joined(separator: " · ")
    }
}

struct PersonView: View {
    let key: String

    var body: some View {
        Loader({ try await $0.person(key) }) { d in
            PersonDetailList(d: d)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Like a Contacts card: big photo and name, quick actions, then everything you're tracking.
private struct PersonDetailList: View {
    let d: PersonDetail

    var body: some View {
        let p = d.person
        List {
            Section {
                VStack(spacing: 10) {
                    AvatarView(name: p.label, photo: p.photo, size: 104, symbol: p.group ? "person.3.fill" : nil)
                    Text(p.label).font(.title.bold())
                    if !caption.isEmpty { Text(caption).font(.subheadline).foregroundStyle(.secondary) }
                    if let h = p.handle, !p.group {
                        HStack(spacing: 10) {
                            ContactAction(title: "Message", symbol: "message.fill", url: URL(string: "sms:\(h.filter { !$0.isWhitespace })"))
                            if !h.contains("@") {
                                ContactAction(title: "Call", symbol: "phone.fill", url: URL(string: "tel:\(h.filter { $0.isNumber || $0 == "+" })"))
                            } else {
                                ContactAction(title: "Mail", symbol: "envelope.fill", url: URL(string: "mailto:\(h)"))
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            section("You Promised", d.promises)
            section("Waiting On \(p.label)", d.waiting)
            section("To-Dos", d.todos)
            section("Gift Ideas", d.gifts)
            section("Things to Remember", d.facts)
            section("Saved", d.other)
            if [d.promises, d.waiting, d.todos, d.gifts, d.facts, d.other].allSatisfy(\.isEmpty) {
                Section { Text("Nothing open with \(p.label) right now.").foregroundStyle(.secondary) }
            }
            if !d.messages.isEmpty {
                Section {
                    ForEach(d.messages) { m in
                        NavigationLink(value: Route.event(m.eventId)) { Bubble(m: m) }
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HeaderRow("Recent Messages")
                }
                .headerProminence(.increased)
            }
            if !d.done.isEmpty {
                Section {
                    ForEach(d.done) { it in ReminderRow(item: it, showPerson: false) }
                } header: {
                    HeaderRow("Done Lately")
                }
                .headerProminence(.increased)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { it in ReminderRow(item: it, showPerson: false) }
            } header: {
                HeaderRow(title, detail: "\(items.count)")
            }
            .headerProminence(.increased)
        }
    }

    private var caption: String {
        let p = d.person
        var parts: [String] = []
        if let c = p.contactName, c != p.label { parts.append(c) }
        if let last = p.last { parts.append("Last message \(BrainDate.ago(last))") } else if p.mentioned { parts.append("Mentioned in your messages") }
        return parts.joined(separator: " · ")
    }
}

/// The Message / Call buttons under a contact's name.
private struct ContactAction: View {
    let title: String
    let symbol: String
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                VStack(spacing: 4) {
                    Image(systemName: symbol).font(.title3)
                    Text(title).font(.caption.weight(.medium))
                }
                .frame(width: 84, height: 56)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 14))
        }
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
                .background(m.fromMe ? Color.blue : Color(uiColor: .systemGray5), in: .rect(cornerRadius: 18))
            if !m.fromMe { Spacer(minLength: 40) }
        }
    }
}
