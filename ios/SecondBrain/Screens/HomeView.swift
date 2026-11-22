import SecondBrainKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Loader({ try await $0.home() }) { h in
            HomeList(h: h)
        }
        .navigationTitle(greeting)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return (4..<12).contains(h) ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }
}

private struct HomeList: View {
    @Environment(AppModel.self) private var app
    let h: Home

    var body: some View {
        List {
            Section {
            } header: {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).textCase(nil)
            }

            if !h.problems.isEmpty {
                Section {
                    ForEach(h.problems, id: \.self) { p in
                        NavigationLink(value: Route.status) {
                            Label { Text(p) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        }
                    }
                }
            }

            if let n = h.next {
                Section { NextUpRow(n: n) }
            }

            TodaySection(h: h)

            if h.weeklyCount > 0 {
                Section {
                    NavigationLink(value: Route.weekly) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Weekly reset")
                                Text("\(h.weeklyCount) thing\(h.weeklyCount == 1 ? "" : "s") gone stale · about 2 minutes")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "sparkles").foregroundStyle(.green) }
                    }
                }
            }

            if h.attention.count > 0 {
                NeedsYouSection(a: h.attention)
            }

            if !h.agenda.isEmpty {
                Section {
                    ForEach(h.agenda) { u in AgendaRow(u: u) }
                } header: {
                    HeaderRow("Coming Up") { Button("Lists") { app.tab = .lists } }
                }
                .headerProminence(.increased)
            }

            if !h.recent.isEmpty {
                Section {
                    ForEach(h.recent) { r in RecentRow(r: r) }
                } header: {
                    HeaderRow("Just Now") { NavigationLink("All Activity", value: Route.activity(status: nil)) }
                }
                .headerProminence(.increased)
            }

            Section {
            } footer: {
                NavigationLink(value: Route.status) {
                    HStack(spacing: 6) {
                        Circle().fill(h.problems.isEmpty ? Color.green : .orange).frame(width: 7, height: 7)
                        Text(h.problems.isEmpty ? "Everything's running" : "Something needs attention")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("home-list")
    }

    private var subtitle: String {
        let d = BrainDate.parse(h.now) ?? Date()
        return BrainDate.longDay(d) + (h.doneToday > 0 ? " · \(h.doneToday) done today" : "")
    }
}

/// The next thing with a time today — like a Calendar widget row: colored bar, title, when.
private struct NextUpRow: View {
    let n: Home.NextUp

    var body: some View {
        let at = BrainDate.parse(n.at)
        let accent = Color(hex: n.color) ?? (n.kind == "event" ? .red : .blue)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2.5).fill(accent).frame(width: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.ongoing ? "Now" : "Up Next · \(n.inLabel)")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                Text(n.title).font(.title3.weight(.semibold)).lineLimit(2)
                if let sub = detail { Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let at {
                Text(BrainDate.time(at))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        if n.kind == "event", let e = BrainDate.parse(n.end) {
            return "Until \(BrainDate.time(e))" + (n.where.map { " · \($0)" } ?? "")
        }
        return n.where
    }
}

private struct TodaySection: View {
    @Environment(AppModel.self) private var app
    let h: Home

    var body: some View {
        Section {
            if h.picks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(h.beforeMorning ? "Your three arrive at \(BrainDate.clock(h.morningTime) ?? h.morningTime)." : "Nothing picked for today yet.")
                        .foregroundStyle(.secondary)
                    Button("Plan My Day", systemImage: "sun.max") {
                        Task { await app.run("Picked your three") { try await $0.todayAction("repick") } }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
                .padding(.vertical, 4)
            }
            ForEach(h.picks) { p in PickRow(p: p) }
            if !h.picks.isEmpty && h.picksLeft == 0 {
                Label("All three done. Anything else is a bonus.", systemImage: "party.popper")
                    .foregroundStyle(.secondary)
            }
            if h.evening {
                NavigationLink(value: Route.today) {
                    Label("Wrap up & pick tomorrow's three", systemImage: "moon")
                }
            }
        } header: {
            HeaderRow("Today", detail: h.picks.isEmpty ? nil : "\(h.picksLeft) of \(h.picks.count) left") {
                HStack(spacing: 14) {
                    if let first = h.picks.first(where: { !$0.isDone && !$0.isGone && $0.kind == "reminder" }) {
                        Button("Focus") { app.focusItem = first.itemId }
                            .accessibilityIdentifier("focus-first")
                    }
                    NavigationLink("Plan", value: Route.today)
                }
            }
        }
        .headerProminence(.increased)
    }
}

/// One of today's picks — a Reminders row; tap to focus on it.
struct PickRow: View {
    @Environment(AppModel.self) private var app
    let p: Pick
    @State private var done: Bool?

    var body: some View {
        let isDone = done ?? p.isDone
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if p.kind == "reminder" && !p.isGone {
                Button { Task { await toggle(!isDone) } } label: {
                    Image(systemName: isDone ? "largecircle.fill.circle" : "circle")
                        .font(.title3)
                        .foregroundStyle(isDone ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
            } else {
                Image(systemName: p.kind == "event" ? "calendar" : "minus.circle").foregroundStyle(.secondary).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if p.category == "promise" { Image(systemName: "handshake").foregroundStyle(.teal) }
                    if p.category == "waiting" { Image(systemName: "hourglass").foregroundStyle(.blue) }
                    Text(p.title).strikethrough(p.isGone)
                        .foregroundStyle(isDone || p.isGone ? .secondary : .primary)
                }
                if let s = p.snoozedTo {
                    Text(s == "someday" ? "Moved to later" : "Moved to \(BrainDate.due(s, nil) ?? s)")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !isDone {
                    if let step = p.firstStep {
                        Text("Start: \(step)").font(.subheadline).foregroundStyle(.secondary)
                    } else if let why = p.why {
                        Text(why.prefix(1).uppercased() + why.dropFirst()).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .onTapGesture { if p.kind == "reminder" && !isDone && !p.isGone { app.focusItem = p.itemId } }
        .itemActions(ItemRef(id: p.itemId, kind: p.kind, title: p.title, isDone: isDone, isOpen: !isDone && !p.isGone))
        .accessibilityIdentifier("pick-\(p.title)")
    }

    private func toggle(_ on: Bool) async {
        done = on
        let id = p.itemId
        let ok = await app.run(on ? "Nice — one down" : nil) { try await $0.setDone(id, on) }
        if !ok { done = nil }
    }
}

private struct NeedsYouSection: View {
    @Environment(AppModel.self) private var app
    let a: Home.Attention

    var body: some View {
        Section {
            ForEach(a.reviews) { r in
                VStack(alignment: .leading, spacing: 10) {
                    NavigationLink(value: Route.event(r.event.id)) {
                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(name: r.event.sender, photo: r.event.photo, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.titles.joined(separator: ", ").nonEmpty ?? "Check this message")
                                Text("\(r.event.sender ?? "?"): “\(r.event.text)”")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        if !r.titles.isEmpty {
                            Button("Add") { Task { await app.run("Added") { try await $0.eventAction("approve", r.event.id) } } }
                                .buttonStyle(.borderedProminent).tint(.green)
                        }
                        Button("Skip") { Task { await app.run("Skipped") { try await $0.eventAction("reject", r.event.id) } } }
                            .buttonStyle(.bordered)
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .padding(.leading, 48)
                }
                .padding(.vertical, 2)
            }
            ForEach(a.followups) { it in ReminderRow(item: it) }
            ForEach(a.late) { it in ReminderRow(item: it) }
            if a.failed > 0 {
                NavigationLink(value: Route.activity(status: "failed")) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(a.failed) message\(a.failed == 1 ? "" : "s") couldn't be processed")
                            Text("Retry usually fixes it").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
        } header: {
            HeaderRow("Needs You", detail: "\(a.count)")
        }
        .headerProminence(.increased)
    }
}

/// A dated thing: calendar-colored bar, title, "Tomorrow, 3:15 PM · Family". Your own iCloud
/// reminders get a check circle.
struct AgendaRow: View {
    @Environment(AppModel.self) private var app
    let u: AgendaEntry
    @State private var ticked = false

    var body: some View {
        let when = BrainDate.parse(u.when) ?? Date()
        let row = HStack(spacing: 12) {
            if u.external && u.kind == "reminder", let apple = u.appleId {
                Button {
                    ticked = true
                    Task { if !(await app.run("Done") { try await $0.externalDone(apple) }) { ticked = false } }
                } label: {
                    Image(systemName: ticked ? "largecircle.fill.circle" : "circle")
                        .font(.title3).foregroundStyle(ticked ? Color.accentColor : (Color(hex: u.color) ?? .secondary))
                }
                .buttonStyle(.borderless)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: u.color) ?? (u.kind == "event" ? .red : .blue))
                    .frame(width: 4, height: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(u.title).strikethrough(ticked).lineLimit(2)
                Text(meta(when)).font(.subheadline).foregroundStyle(u.late ? Color.red : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        if let ev = u.eventId, !u.external {
            NavigationLink(value: Route.event(ev)) { row }
                .itemActions(ItemRef(id: u.itemId ?? "", kind: u.kind, title: u.title, isOpen: u.itemId != nil))
        } else {
            row
        }
    }

    private func meta(_ when: Date) -> String {
        var parts: [String] = []
        let day = u.late ? "Overdue" : BrainDate.niceDay(when)
        parts.append(u.allDay ? day : "\(day), \(BrainDate.time(when))")
        if let w = u.where { parts.append(w) }
        if let l = u.location { parts.append(l) }
        if let who = u.who, who != "Me" { parts.append(who) }
        return parts.joined(separator: " · ")
    }
}

private struct RecentRow: View {
    let r: Home.Recent

    var body: some View {
        let st = style
        NavigationLink(value: Route.event(r.eventId ?? "")) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    (Text(r.verb + " ").foregroundStyle(.secondary) + Text(r.title)).lineLimit(1)
                    Text([r.person, r.via.map { "in \($0)" }, BrainDate.ago(r.at)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: st.0).foregroundStyle(st.1)
            }
        }
        .disabled(r.eventId == nil)
    }

    private var style: (String, Color) {
        switch r.verb {
        case "Done": return ("checkmark.circle.fill", .green)
        case "Cancelled", "Deleted": return ("xmark.circle.fill", .red)
        case "Undid": return ("arrow.uturn.backward.circle.fill", .gray)
        case "Changed": return ("pencil.circle.fill", .orange)
        default:
            if r.collection == "gift_ideas" { return ("gift.fill", .orange) }
            if r.collection != nil { return ("bookmark.fill", .orange) }
            return r.kind == "event" ? ("calendar", .red) : ("plus.circle.fill", .blue)
        }
    }
}
