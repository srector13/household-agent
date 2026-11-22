import SecondBrainKit
import SwiftUI

// MARK: - Plan my days

struct TodayView: View {
    var body: some View {
        Loader({ try await $0.today() }) { t in TodayList(t: t) }
            .navigationTitle("Plan my days")
    }
}

private struct TodayList: View {
    @Environment(AppModel.self) private var app
    let t: Today
    @State private var chosen: Set<String> = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                if t.picks.isEmpty {
                    Text("Nothing picked yet. Your three arrive at \(BrainDate.clock(t.morningTime) ?? t.morningTime).")
                        .foregroundStyle(.secondary)
                }
                ForEach(t.picks) { p in PickRow(p: p) }
            } header: {
                Text(BrainDate.day(t.date).map(BrainDate.longDay) ?? "Today")
            } footer: {
                if let s = t.summary { Text(s) }
            }

            Section {
                Button { run("repick", "Picked a fresh three") } label: { Label("Pick again", systemImage: "arrow.triangle.2.circlepath") }
                Button { run("morning", "Briefing sent") } label: { Label("Send the morning briefing", systemImage: "sun.max") }
                Button { run("evening", "Wrapped up") } label: { Label("Wrap up the day now", systemImage: "moon") }
            }

            if !t.events.isEmpty {
                Section("On the calendar") {
                    ForEach(t.events) { e in
                        HStack {
                            Text(timeText(e)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(e.title ?? "").font(.body.weight(.medium))
                                if let w = e.where { Text(w).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }

            if !t.done.isEmpty {
                Section("Done today · \(t.done.count)") {
                    ForEach(t.done) { it in ItemLine(item: it) }
                }
            }

            Section {
                ForEach(t.candidates) { c in
                    Button {
                        if chosen.contains(c.id) { chosen.remove(c.id) } else { chosen.insert(c.id) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: chosen.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(chosen.contains(c.id) ? Color.blue : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).foregroundStyle(.primary)
                                if let why = c.why { Text(why).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if !t.candidates.isEmpty {
                    Button {
                        let ids = Array(chosen)
                        Task { await app.run("Tomorrow's three are set") { try await $0.todayAction("tomorrow", itemIds: ids) } }
                    } label: {
                        Text(chosen.isEmpty ? "Let the model pick tomorrow" : "Use these \(chosen.count) tomorrow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            } header: {
                Text("Tomorrow")
            } footer: {
                Text(t.tomorrowLocked ? "You chose these — the morning keeps them." : "Suggestions; tap to choose your own.")
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            if !loaded { chosen = Set(t.tomorrowChosen); loaded = true }
        }
    }

    private func run(_ what: String, _ done: String) {
        Task { await app.run(done) { try await $0.todayAction(what) } }
    }

    private func timeText(_ e: Today.DayEvent) -> String {
        if e.allDay { return "All day" }
        return BrainDate.parse(e.start).map(BrainDate.time) ?? ""
    }
}

// MARK: - Weekly reset

struct WeeklyView: View {
    var body: some View {
        Loader({ try await $0.weekly() }) { w in WeeklyDeck(w: w) }
            .navigationTitle("Weekly reset")
    }
}

private struct WeeklyDeck: View {
    @Environment(AppModel.self) private var app
    let w: Weekly
    @State private var index = 0
    @State private var counts: [String: Int] = ["keep": 0, "schedule": 0, "done": 0, "drop": 0]
    @State private var drag: CGSize = .zero
    @State private var busy = false
    @State private var scheduling: SnoozeOptions?
    @State private var finished = false

    var body: some View {
        VStack(spacing: 18) {
            if w.cards.isEmpty || finished {
                end
            } else {
                Text("\(w.cards.count) thing\(w.cards.count == 1 ? "" : "s") gone stale. Swipe right to keep, left to drop.")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ProgressView(value: Double(index), total: Double(max(w.cards.count, 1)))
                    .tint(.green)
                ZStack {
                    if index + 1 < w.cards.count {
                        card(w.cards[index + 1]).scaleEffect(0.95).offset(y: 14).opacity(0.6)
                    }
                    if index < w.cards.count {
                        card(w.cards[index])
                            .offset(x: drag.width)
                            .rotationEffect(.degrees(Double(drag.width) / 22))
                            .overlay(alignment: .topTrailing) { stamp("KEEP", .blue).opacity(drag.width > 40 ? 1 : 0) }
                            .overlay(alignment: .topLeading) { stamp("DROP", .red).opacity(drag.width < -40 ? 1 : 0) }
                            .gesture(DragGesture()
                                .onChanged { drag = $0.translation }
                                .onEnded { v in
                                    if v.translation.width > 110 { act("keep") }
                                    else if v.translation.width < -110 { act("drop") }
                                    else { withAnimation(.spring) { drag = .zero } }
                                })
                            .id(w.cards[index].id)
                            .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                GlassEffectContainer(spacing: 18) {
                    HStack(spacing: 18) {
                        roundButton("trash", "Drop", .red) { act("drop") }
                        roundButton("clock", "Schedule", .orange) { Task { await schedule() } }
                        roundButton("checkmark", "Done", .green, prominent: true) { act("done") }
                        roundButton("bookmark", "Keep", .blue) { act("keep") }
                    }
                }
                .disabled(busy)
            }
        }
        .padding()
        .confirmationDialog("Schedule it", isPresented: Binding(get: { scheduling != nil }, set: { if !$0 { scheduling = nil } }),
                            titleVisibility: .visible, presenting: scheduling) { o in
            ForEach(o.options) { opt in
                Button("\(opt.label) · \(opt.sub)") { Task { await snooze(opt.key) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func card(_ c: WeeklyCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(c.why.uppercased()).font(.caption.weight(.bold)).foregroundStyle(c.rank == 0 ? Color.red : Color.secondary)
            Text((c.category == "promise" ? "🤝 " : c.category == "waiting" ? "⏳ " : "") + c.title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            if let p = c.person {
                Text((c.category == "promise" ? "You promised " : c.category == "waiting" ? "Waiting on " : "From ") + p)
                    .font(.headline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let q = c.quote {
                Text("\(c.fromMe ? "You" : (c.person ?? "")): “\(q)”")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 14))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 380, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
        .accessibilityIdentifier("weekly-card")
    }

    private func stamp(_ text: String, _ color: Color) -> some View {
        Text(text).font(.title3.weight(.heavy)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(text == "KEEP" ? 10 : -10))
            .padding(22)
    }

    private func roundButton(_ symbol: String, _ label: String, _ color: Color, prominent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol).font(.title2.weight(.semibold))
                    .foregroundStyle(prominent ? .white : color)
                    .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
            .glassEffect(prominent ? .regular.tint(color).interactive() : .regular.interactive(), in: .circle)
            .accessibilityLabel(label)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    private var end: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark").font(.system(size: 48, weight: .bold)).foregroundStyle(.white)
                .frame(width: 104, height: 104).background(Color.green, in: .circle)
            Text(w.cards.isEmpty ? "All clear" : "Reset done").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(summary).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var summary: String {
        if w.cards.isEmpty { return "Nothing's gone stale — your lists are in good shape." }
        let parts = [("done", "done"), ("schedule", "scheduled"), ("keep", "kept"), ("drop", "dropped")]
            .compactMap { pair -> String? in
                let n = counts[pair.0] ?? 0
                return n > 0 ? "\(n) \(pair.1)" : nil
            }
        return parts.joined(separator: " · ") + ". Fresh week, lighter lists."
    }

    private func act(_ kind: String) {
        guard index < w.cards.count, !busy else { return }
        let c = w.cards[index]
        busy = true
        Task {
            guard let api = app.api else { return }
            do {
                switch kind {
                case "keep": try await api.weeklyKeep(c.itemId)
                case "done": try await api.setDone(c.itemId, true)
                case "drop":
                    try await api.delete(c.itemId)
                    let id = c.itemId
                    app.show("Dropped", undo: { await app.run("Restored") { try await $0.restore(id) } })
                default: break
                }
                advance(kind)
            } catch {
                app.show(error.localizedDescription, error: true)
                withAnimation(.spring) { drag = .zero }
            }
            busy = false
        }
    }

    private func schedule() async {
        guard index < w.cards.count, let api = app.api else { return }
        do { scheduling = try await api.snoozeOptions(w.cards[index].itemId) } catch {
            app.show(error.localizedDescription, error: true)
        }
    }

    private func snooze(_ key: String) async {
        guard index < w.cards.count, let api = app.api else { return }
        do {
            let r = try await api.snooze(w.cards[index].itemId, key: key)
            app.show("Moved to \(r.label ?? "later")")
            advance("schedule")
        } catch {
            app.show(error.localizedDescription, error: true)
        }
    }

    private func advance(_ kind: String) {
        counts[kind, default: 0] += 1
        withAnimation(.spring(duration: 0.35)) {
            drag = .zero
            index += 1
        }
        if index >= w.cards.count {
            finished = true
            let c = counts
            Task {
                _ = try? await app.api?.weeklyFinish(c)
                app.changed()
            }
        }
    }
}
