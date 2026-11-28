import SecondBrainKit
import SwiftUI

struct PeopleView: View {
    @Environment(AppModel.self) private var app
    @State private var picked: PickedContact?

    var body: some View {
        Loader({ api -> PeopleAndItems in
            async let people = api.people()
            async let page = api.items(tab: "todos")
            return PeopleAndItems(people: try await people, items: try await page.items)
        }) { d in
            PeopleGrid(people: d.people, items: d.items)
        }
        .navigationTitle("People")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { ContactPicker.present { picked = $0 } } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add someone from Contacts")
                    .accessibilityIdentifier("add-person")
            }
        }
        .sheet(item: $picked) { c in AddPersonSheet(contact: c) }
    }
}

private struct PeopleAndItems {
    var people: [Person]
    var items: [Item]
}

/// Faces first, like a Contacts favorites row, then what's open between you and them.
private struct PeopleGrid: View {
    let people: [Person]
    let items: [Item]

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 8)]

    var body: some View {
        let watched = people.filter { !$0.mentioned }
        let mentioned = people.filter(\.mentioned)
        let between = items.filter { ($0.category == "promise" || $0.category == "waiting") && $0.person != nil }
        List {
            if people.isEmpty {
                ContentUnavailableView {
                    Label("No one yet", systemImage: "person.2")
                } description: {
                    Text("Tap + to pick someone from Contacts. Second Brain starts reading your texts with them right away.")
                }
            }
            if !watched.isEmpty {
                Section {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
                        ForEach(watched) { p in Face(p: p) }
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            }
            if !between.isEmpty {
                Section {
                    ForEach(between) { it in ReminderRow(item: it, showPerson: true) }
                } header: {
                    HeaderRow("Between You")
                }
                .headerProminence(.increased)
            }
            if !mentioned.isEmpty {
                Section {
                    ForEach(mentioned) { p in
                        NavigationLink(value: Route.person(p.key)) {
                            HStack(spacing: 12) {
                                AvatarView(name: p.label, photo: p.photo, size: 34)
                                Text(p.label)
                            }
                        }
                    }
                } header: {
                    HeaderRow("Also Mentioned")
                }
                .headerProminence(.increased)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("people-grid")
    }
}

private struct Face: View {
    @Environment(AppModel.self) private var app
    let p: Person

    var body: some View {
        let open = p.promises + p.waiting + p.todos
        // A button, not a NavigationLink: inside a List a link would draw a chevron next to each face.
        Button { app.paths[.people, default: []].append(.person(p.key)) } label: {
            VStack(spacing: 6) {
                AvatarView(name: p.label, photo: p.photo, size: 64, symbol: p.group ? "person.3.fill" : nil)
                    .overlay(alignment: .topTrailing) {
                        if open > 0 {
                            Text("\(open)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: .capsule)
                                .overlay(Capsule().stroke(Color(.systemGroupedBackground), lineWidth: 2))
                                .offset(x: 4, y: -2)
                        }
                    }
                Text(p.label).font(.footnote.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(p.label + (open > 0 ? ", \(open) open" : ""))
    }
}

struct PersonView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let key: String
    @State private var confirmStop = false

    var body: some View {
        Loader({ try await $0.person(key) }) { d in
            PersonDetailList(d: d)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if key.hasPrefix("h-") || key.hasPrefix("c-") {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Stop Watching Texts", systemImage: "eye.slash", role: .destructive) { confirmStop = true }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .confirmationDialog("Stop reading texts from them?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Watching", role: .destructive) {
                Task {
                    if await app.run("Stopped watching", { try await $0.removePerson(key) }) { dismiss() }
                }
            }
        } message: {
            Text("What's already saved stays. New messages from them won't be read.")
        }
    }
}

// MARK: - Add from Contacts

/// What we need from a contact the user picked.
struct PickedContact: Identifiable {
    let id = UUID()
    var name: String
    var nickname: String?
    var phones: [Handle]
    var emails: [Handle]
    var photo: Data?

    struct Handle: Hashable {
        var label: String
        var value: String
    }

    var handles: [Handle] { phones + emails }
    var short: String { nickname?.nonEmpty ?? name.split(separator: " ").first.map(String.init) ?? name }
}

struct AddPersonSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let contact: PickedContact
    @State private var label = ""
    @State private var handle = ""
    @State private var isMe = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 6) {
                        Group {
                            if let d = contact.photo, let img = UIImage(data: d) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                AvatarView(name: contact.name, size: 96)
                            }
                        }
                        .frame(width: 96, height: 96).clipShape(Circle())
                        Text(contact.name).font(.title2.bold())
                        Label(contact.photo == nil ? "From Contacts" : "From Contacts · photo included", systemImage: "person.crop.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section("Show As") {
                    TextField("Name", text: $label).textInputAutocapitalization(.words)
                }
                Section {
                    if contact.handles.isEmpty {
                        Text("This contact has no phone number or email.").foregroundStyle(.secondary)
                    }
                    Picker("Watch texts from", selection: $handle) {
                        ForEach(contact.handles, id: \.value) { h in
                            VStack(alignment: .leading) {
                                Text(h.value)
                                Text(h.label).font(.footnote).foregroundStyle(.secondary)
                            }
                            .tag(h.value)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Watch Texts From")
                }
                Section {
                    Toggle("This is me", isOn: $isMe)
                } footer: {
                    Text("Turn on for notes you text yourself. Only the conversations you add are read, starting now.")
                }
            }
            .navigationTitle("Add Someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(busy || handle.isEmpty || label.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("add-person-confirm")
                }
            }
        }
        .onAppear {
            label = contact.short
            handle = contact.phones.first?.value ?? contact.emails.first?.value ?? ""
        }
    }

    private func add() async {
        busy = true
        let (name, l, h, photo, me) = (contact.name, label.trimmingCharacters(in: .whitespaces), handle, contact.photo, isMe)
        let ok = await app.run("Watching texts from \(l)") {
            _ = try await $0.addPerson(name: name, label: l, handle: h, photo: photo, isMe: me)
        }
        busy = false
        if ok { dismiss() }
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
