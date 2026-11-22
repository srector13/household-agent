import SecondBrainKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Loader({ try await $0.home() }) { h in
            HomeList(h: h)
        }
        .navigationTitle(app.info.map { _ in greeting } ?? "Home")
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
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
            }
            .listSectionSpacing(4)

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
                Section { NextUpCard(n: n) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if h.weeklyCount > 0 {
                Section {
                    NavigationLink(value: Route.weekly) {
                        HStack(spacing: 12) {
                            IconTile(symbol: "sparkles", color: .green)
                            VStack(alignment: .leading) {
                                Text("Weekly reset").font(.headline)
                                Text("\(h.weeklyCount) thing\(h.weeklyCount == 1 ? "" : "s") gone stale · takes 2 minutes")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            TodaySection(h: h)

            if h.attention.count > 0 {
                NeedsYouSection(a: h.attention)
            }

            if !h.agenda.isEmpty {
                Section {
                    ForEach(h.agenda) { u in AgendaRow(u: u) }
                } header: {
                    HStack { Text("Coming up"); Spacer(); Button("Lists") { app.tab = .lists }.font(.subheadline) }
                }
            }

            if !h.recent.isEmpty {
                Section {
                    ForEach(h.recent) { r in RecentRow(r: r) }
                } header: {
                    HStack {
                        Text("Just now"); Spacer()
                        NavigationLink("All activity", value: Route.activity(status: nil)).font(.subheadline)
                    }
                }
            }

            Section {
                NavigationLink(value: Route.status) {
                    HStack(spacing: 8) {
                        Circle().fill(h.problems.isEmpty ? Color.green : .orange).frame(width: 8, height: 8)
                        Text(h.problems.isEmpty ? "Everything's running" : "Something needs attention")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
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

/// The next thing with a time today, big at the top.
private struct NextUpCard: View {
    let n: Home.NextUp

    var body: some View {
        let at = BrainDate.parse(n.at)
        let accent = Color(hex: n.color) ?? (n.kind == "event" ? .red : .blue)
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(at.map { BrainDate.time($0).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") } ?? "")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(at.map { BrainDate.time($0).hasSuffix("PM") ? "PM" : "AM" } ?? "")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(width: 72)
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(n.ongoing ? "Happening now" : "Up next") · \(n.inLabel)")
                    .font(.caption.weight(.semibold)).foregroundStyle(accent).textCase(.uppercase)
                Text(n.title).font(.title3.weight(.semibold)).lineLimit(2)
                if let sub = detail { Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassEffect(.regular.tint(accent.opacity(0.10)), in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        if n.kind == "event", let e = BrainDate.parse(n.end) {
            return "until \(BrainDate.time(e))" + (n.where.map { " · \($0)" } ?? "")
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
                VStack(spacing: 10) {
                    Text(h.beforeMorning ? "Your three arrive at \(BrainDate.clock(h.morningTime) ?? h.morningTime)." : "Nothing picked for today yet.")
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await app.run("Picked your three") { try await $0.todayAction("repick") } }
                    } label: {
                        Label("Plan my day", systemImage: "sun.max")
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            ForEach(h.picks) { p in PickRow(p: p) }
            if !h.picks.isEmpty && h.picksLeft == 0 {
                Text("🎉 All three done. Anything else today is a bonus.").font(.subheadline).foregroundStyle(.secondary)
            }
            if h.evening {
                NavigationLink(value: Route.today) {
                    Label("Wrap up & pick tomorrow's three", systemImage: "moon")
                }
            }
        } header: {
            HStack {
                Text("Today")
                if !h.picks.isEmpty {
                    Text("\(h.picksLeft) of \(h.picks.count) left").foregroundStyle(.secondary).textCase(nil)
                }
                Spacer()
                if let first = h.picks.first(where: { !$0.isDone && !$0.isGone && $0.kind == "reminder" }) {
                    Button { app.focusItem = first.itemId } label: { Label("Focus", systemImage: "scope") }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("focus-first")
                }
                NavigationLink("Plan", value: Route.today).font(.subheadline)
            }
        }
    }
}

struct PickRow: View {
    @Environment(AppModel.self) private var app
    let p: Pick
    @State private var done: Bool?

    var body: some View {
        let isDone = done ?? p.isDone
        HStack(alignment: .top, spacing: 12) {
            if p.kind == "reminder" && !p.isGone {
                Button { Task { await toggle(!isDone) } } label: { CheckCircle(on: isDone) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
            } else {
                Image(systemName: p.kind == "event" ? "calendar" : "xmark").foregroundStyle(.secondary).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if p.category == "promise" { Image(systemName: "handshake").foregroundStyle(.teal) }
                    if p.category == "waiting" { Image(systemName: "hourglass").foregroundStyle(.blue) }
                    Text(p.title).strikethrough(isDone || p.isGone).foregroundStyle(isDone || p.isGone ? .secondary : .primary)
                }
                .font(.body.weight(.medium))
                if let s = p.snoozedTo {
                    Text(s == "someday" ? "Moved to later" : "Moved to \(BrainDate.due(s, nil) ?? s)").font(.caption).foregroundStyle(.secondary)
                } else if let why = p.why, !isDone {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
                if let step = p.firstStep, !isDone, !p.isGone {
                    Label { Text("**Start:** \(step)") } icon: { Image(systemName: "shoeprints.fill") }
                        .font(.caption).foregroundStyle(.green)
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
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink(value: Route.event(r.event.id)) {
                        HStack(alignment: .top, spacing: 12) {
                            AvatarView(name: r.event.sender, photo: r.event.photo, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.titles.joined(separator: ", ").nonEmpty ?? "Check this message").font(.body.weight(.medium))
                                Text("\(r.event.sender ?? "?"): “\(r.event.text)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    HStack {
                        if !r.titles.isEmpty {
                            Button("Add") { Task { await app.run("Added") { try await $0.eventAction("approve", r.event.id) } } }
                                .buttonStyle(.glassProminent).tint(.green)
                        }
                        Button("Skip") { Task { await app.run("Skipped") { try await $0.eventAction("reject", r.event.id) } } }
                            .buttonStyle(.glass)
                    }
                    .padding(.leading, 46)
                }
            }
            ForEach(a.followups) { it in
                AttentionItemRow(item: it, symbol: "hourglass", title: "Follow up with \(it.person ?? "them")",
                                 subtitle: it.title + (BrainDate.due(it.due, nil).map { " · expected \($0)" } ?? ""))
            }
            ForEach(a.late) { it in
                AttentionItemRow(item: it, symbol: "handshake", title: it.title,
                                 subtitle: "You promised \(it.person ?? "someone")" + (BrainDate.due(it.due, nil).map { " · was due \($0)" } ?? ""))
            }
            if a.failed > 0 {
                NavigationLink(value: Route.activity(status: "failed")) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("\(a.failed) message\(a.failed == 1 ? "" : "s") couldn't be processed")
                            Text("Tap to look — Retry usually fixes it").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
        } header: {
            HStack { Text("Needs you"); Spacer(); Text("\(a.count)").foregroundStyle(.secondary) }
        }
    }
}

private struct AttentionItemRow: View {
    @Environment(AppModel.self) private var app
    let item: Item
    let symbol: String
    let title: String
    let subtitle: String
    @State private var done = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                done = true
                let id = item.id
                Task { if !(await app.run("Done") { try await $0.setDone(id, true) }) { done = false } }
            } label: { CheckCircle(on: done) }
            .buttonStyle(.plain)
            NavigationLink(value: Route.event(item.originEventId ?? "")) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: symbol).font(.body.weight(.medium))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .itemActions(ItemRef(item))
    }
}

struct AgendaRow: View {
    @Environment(AppModel.self) private var app
    let u: AgendaEntry
    @State private var ticked = false

    var body: some View {
        let when = BrainDate.parse(u.when) ?? Date()
        let tile = BrainDate.tile(when)
        let row = HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(u.late ? "Late" : tile.top).font(.caption2.weight(.semibold)).foregroundStyle(Color.red.opacity(u.late ? 1 : 0.85))
                    .textCase(.uppercase)
                Text(tile.day).font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if u.external { Circle().fill(Color(hex: u.color) ?? .gray).frame(width: 8, height: 8) }
                    Text(u.title).font(.body.weight(.medium)).strikethrough(ticked).lineLimit(2)
                }
                Text(meta(when)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if u.external && u.kind == "reminder", let apple = u.appleId {
                Button {
                    ticked = true
                    Task { if !(await app.run("Done") { try await $0.externalDone(apple) }) { ticked = false } }
                } label: { CheckCircle(on: ticked) }
                .buttonStyle(.plain)
            }
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
        if !u.allDay { parts.append(BrainDate.time(when)) }
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
            HStack(spacing: 12) {
                IconTile(symbol: st.0, color: st.1, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(r.verb + " ").foregroundStyle(.secondary) + Text(r.title)).lineLimit(1)
                    Text([r.person, r.via.map { "in \($0)" }, BrainDate.ago(r.at)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(r.eventId == nil)
    }

    private var style: (String, Color) {
        switch r.verb {
        case "Done": return ("checkmark", .green)
        case "Cancelled", "Deleted": return ("xmark", .red)
        case "Undid": return ("arrow.uturn.backward", .gray)
        case "Changed": return ("pencil", .brown)
        default:
            if r.collection == "gift_ideas" { return ("gift", .orange) }
            if r.collection != nil { return ("bookmark", .orange) }
            return r.kind == "event" ? ("calendar", .red) : ("checklist", .blue)
        }
    }
}
