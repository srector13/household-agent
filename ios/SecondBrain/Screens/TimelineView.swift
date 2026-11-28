import SecondBrainKit
import SwiftUI

// MARK: - Today: one timeline of calendar events and reminders

/// The Today tab. Events are colored blocks (nothing to tick off); reminders are circles on the
/// line. Past events fade, and anything still open is carried to the red "now" line.
struct TimelineHome: View {
    @Environment(AppModel.self) private var app
    @State private var day: String?
    @State private var showSources = false

    var body: some View {
        Loader({ [day] api in try await api.timeline(day: day) }) { t in
            TimelineScroll(t: t, day: $day)
        }
        .id(day ?? "today")
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSources = true } label: { Image(systemName: "calendar") }
                    .accessibilityLabel("Choose calendars and lists")
                    .accessibilityIdentifier("sources-button")
            }
            if day != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") { withAnimation { day = nil } }
                }
            }
        }
        .sheet(isPresented: $showSources) {
            SourcesSheet()
                .presentationDetents([.large])
        }
    }

    private var title: String {
        guard let day, let d = BrainDate.day(day) else { return "Today" }
        return BrainDate.niceDay(d)
    }
}

private struct TimelineScroll: View {
    @Environment(AppModel.self) private var app
    let t: Timeline
    @Binding var day: String?

    private var isToday: Bool { t.date == t.today }
    private var now: Date { BrainDate.parse(t.now) ?? Date() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(subtitle)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                WeekStrip(week: t.week, selected: t.date, today: t.today) { picked in
                    withAnimation(.snappy) { day = picked == t.today ? nil : picked }
                }
                .padding(.horizontal, 12)

                if let b = t.banner, isToday {
                    ReviewBannerCard(banner: b) { app.showReview = true }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                }

                if !t.allDay.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(t.allDay) { e in AllDayChip(e: e) }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 14)
                }

                rows
                    .padding(.top, 12)
                    .padding(.trailing, 16)

                Color.clear.frame(height: 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("timeline")
    }

    @ViewBuilder
    private var rows: some View {
        let entries = t.entries
        let split = isToday ? (entries.firstIndex { ($0.atDate ?? .distantFuture) >= now && !$0.isPastEvent } ?? entries.count) : -1
        if entries.isEmpty {
            VStack(spacing: 6) {
                if isToday { NowLine(now: now) }
                Text(isToday ? "Nothing else today. Enjoy the quiet." : "Nothing planned.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                    if i == split { NowLine(now: now) }
                    TimelineRow(e: e, day: t.date, now: now, showTime: showTime(at: i))
                }
                if split == entries.count { NowLine(now: now) }
            }
            .background(alignment: .leading) {
                // the line everything hangs on
                Rectangle().fill(Color(.separator)).frame(width: 2).padding(.leading, 77).padding(.vertical, 10)
            }
        }
    }

    /// Only the first item at a given time shows the time label; carried items show none.
    private func showTime(at i: Int) -> Bool {
        let e = t.entries[i]
        if e.carried { return false }
        guard i > 0 else { return true }
        let p = t.entries[i - 1]
        return p.carried || p.timeLabel != e.timeLabel
    }

    private var subtitle: String {
        let d = BrainDate.day(t.date) ?? now
        var s = BrainDate.longDay(d)
        if isToday && t.addedToday > 0 { s += " · \(t.addedToday) added for you" }
        return s
    }
}

// MARK: Week strip

struct WeekStrip: View {
    let week: [WeekDay]
    let selected: String
    let today: String
    var pick: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(week) { w in
                let d = BrainDate.day(w.date) ?? Date()
                let on = w.date == selected
                Button { pick(w.date) } label: {
                    VStack(spacing: 4) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(on ? Color(.systemBackground).opacity(0.8) : .secondary)
                        Text(d.formatted(.dateTime.day()))
                            .font(.body.weight(on || w.date == today ? .bold : .medium))
                            .foregroundStyle(on ? Color(.systemBackground) : w.date == today ? Color.red : .primary)
                        Circle()
                            .fill(w.count > 0 ? (on ? Color(.systemBackground) : Color.secondary.opacity(0.5)) : .clear)
                            .frame(width: 5, height: 5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(on ? Color.primary : .clear, in: .rect(cornerRadius: 14))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(BrainDate.longDay(d) + (w.count > 0 ? ", \(w.count) things" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}

// MARK: Review banner + sheet

struct ReviewBannerCard: View {
    let banner: ReviewBanner
    var open: () -> Void

    var body: some View {
        let e = banner.entry
        Button(action: open) {
            HStack(spacing: 12) {
                AvatarView(name: e.event.sender, photo: e.event.photo, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text("\(e.event.sender ?? "Someone"): “\(e.event.text)”")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if banner.count > 1 {
                    Text("\(banner.count)").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(.orange, in: .capsule)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.orange.opacity(0.8), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review-banner")
    }

    private var headline: String {
        if let p = banner.entry.proposals.first { return "Add “\(p.title)”?" }
        return "Check a message"
    }
}

/// The rare "is this right?" question, as a sheet over Today: their words, what it would add, Add or Skip.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ReviewEntry]?
    @State private var index = 0
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    if index < entries.count {
                        ReviewPage(e: entries[index], busy: busy) { action in await act(action, entries[index]) }
                    } else {
                        ContentUnavailableView("All Caught Up", systemImage: "checkmark.circle")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(counter)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var counter: String {
        guard let entries, entries.count > 1, index < entries.count else { return "" }
        return "\(index + 1) of \(entries.count)"
    }

    private func load() async {
        guard let api = app.api else { return }
        entries = (try? await api.review()) ?? []
        if entries?.isEmpty == true { dismiss() }
    }

    private func act(_ action: String, _ e: ReviewEntry) async {
        busy = true
        let ok = await app.run(action == "approve" ? "Added" : "Skipped") { try await $0.eventAction(action, e.event.id) }
        busy = false
        guard ok else { return }
        if index + 1 < (entries?.count ?? 0) { withAnimation { index += 1 } } else { dismiss() }
    }
}

private struct ReviewPage: View {
    let e: ReviewEntry
    let busy: Bool
    var act: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom, spacing: 8) {
                        AvatarView(name: e.event.sender, photo: e.event.photo, size: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text([e.event.sender, BrainDate.parse(e.event.receivedAt).map(BrainDate.time)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
                            Text(e.event.text)
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(Color(.systemGray5), in: UnevenRoundedRectangle(
                                    topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18))
                        }
                        Spacer(minLength: 40)
                    }

                    if !e.proposals.isEmpty {
                        Text("Add this?").font(.title3.bold()).padding(.top, 24).padding(.bottom, 8).padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(e.proposals.enumerated()), id: \.element.id) { i, p in
                                if i > 0 { Divider().padding(.leading, 52) }
                                HStack(spacing: 12) {
                                    Image(systemName: p.op == "create_event" ? "calendar" : p.collection != nil ? "bookmark" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(p.op == "create_event" ? Color.green : p.collection != nil ? Color.orange : Color.secondary)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.title).font(.body.weight(.medium))
                                        if let d = describe(p) { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                    }
                    if !e.reasons.isEmpty {
                        Text("Asking because " + e.reasons.joined(separator: "; ").lowercasedFirst + ".")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.top, 10)
                    }
                }
                .padding(16)
            }
            VStack(spacing: 10) {
                if !e.proposals.isEmpty {
                    Button { Task { await act("approve") } } label: {
                        Text(e.proposals.count == 1 && e.proposals[0].op == "create_event" ? "Add Event" : "Add")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("review-add")
                }
                Button { Task { await act("reject") } } label: {
                    Text("Skip").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(busy)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func describe(_ p: Proposal) -> String? {
        var parts: [String] = []
        if let s = BrainDate.parse(p.start) {
            parts.append(p.allDay ? BrainDate.niceDay(s) : "\(BrainDate.niceDay(s)), \(BrainDate.time(s))")
        } else if let d = BrainDate.due(p.due, p.dueTime) {
            parts.append(d)
        }
        if let c = p.collection { parts.append(c) } else if let l = p.list { parts.append(l) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: Rows

private struct NowLine: View {
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            Text(BrainDate.time(now))
                .font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.red, in: .rect(cornerRadius: 8))
                .lineLimit(1).fixedSize()
                .frame(width: 60, alignment: .trailing)
                .padding(.trailing, 0)
            Circle().fill(Color.red).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.red.opacity(0.2), lineWidth: 4))
                .frame(width: 36)
            Rectangle().fill(Color.red).frame(height: 2)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(BrainDate.time(now))")
    }
}

private struct AllDayChip: View {
    let e: TimelineEntry

    var body: some View {
        let c = Color(hex: e.color) ?? .orange
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("All day · " + e.title).lineLimit(1)
            if e.ours { Sparkle(color: c) }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(c.opacity(0.16), in: .rect(cornerRadius: 10))
        .opacity(e.past ? 0.5 : 1)
    }
}

/// Marks what Second Brain added for you.
struct Sparkle: View {
    var color: Color = .accentColor

    var body: some View {
        Image(systemName: "sparkle").font(.caption2.weight(.bold)).foregroundStyle(color)
            .accessibilityLabel("Added by Second Brain")
    }
}

private struct TimelineRow: View {
    @Environment(AppModel.self) private var app
    let e: TimelineEntry
    let day: String
    let now: Date
    let showTime: Bool

    var body: some View {
        if e.isEvent {
            EventBlock(e: e, showTime: showTime)
        } else {
            ReminderLine(e: e, day: day, now: now, showTime: showTime)
        }
    }
}

private struct TimeLabel: View {
    let text: String?

    var body: some View {
        Text(text ?? "")
            .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: 54, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

private struct EventBlock: View {
    @Environment(AppModel.self) private var app
    let e: TimelineEntry
    let showTime: Bool

    var body: some View {
        let c = Color(hex: e.color) ?? .green
        HStack(alignment: .top, spacing: 0) {
            TimeLabel(text: showTime ? e.timeLabel : nil).padding(.top, 4)
            Capsule().fill(c).frame(width: 26).frame(maxHeight: .infinity).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).font(.body.weight(.semibold)).lineLimit(2)
                    if e.ours { Sparkle(color: c) }
                }
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(c.opacity(0.16), in: .rect(cornerRadius: 14))
            .padding(.leading, 6)
        }
        .frame(minHeight: height)
        .padding(.vertical, 4)
        .opacity(e.past ? 0.45 : 1)
        .contentShape(.rect)
        .onTapGesture { if let ev = e.originEventId { app.paths[.home, default: []].append(.event(ev)) } }
        .accessibilityElement(children: .combine)
        .accessibilityHint(e.originEventId == nil ? "" : "Shows the message it came from")
    }

    /// Longer events get taller blocks, within reason.
    private var height: CGFloat {
        guard let s = e.startDate, let en = e.endDate else { return 60 }
        return min(max(CGFloat(en.timeIntervalSince(s) / 60) * 0.9, 60), 140)
    }

    private var detail: String {
        var parts: [String] = []
        if let s = e.startDate {
            parts.append(e.endDate.map { "\(BrainDate.time(s))–\(BrainDate.time($0))" } ?? BrainDate.time(s))
        }
        if let l = e.location { parts.append(l) } else if let c = e.calendar { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}

/// A reminder on the line: tick it off (yours or Second Brain's), long-press and drag to move it.
private struct ReminderLine: View {
    @Environment(AppModel.self) private var app
    let e: TimelineEntry
    let day: String
    let now: Date
    let showTime: Bool

    @State private var done: Bool?
    @State private var dragMinutes: Int?
    @State private var dragging = false
    @State private var showActions = false

    private static let pointsPerStep: CGFloat = 22   // one 15-minute step per 22 pt of drag

    var body: some View {
        let isDone = done ?? e.done
        let ring = ringColor
        HStack(alignment: .center, spacing: 0) {
            TimeLabel(text: showTime && !e.carried ? e.timeLabel : nil)
            Button { Task { await toggle(!isDone) } } label: {
                ZStack {
                    Circle().fill(isDone ? ring : Color(.systemGroupedBackground))
                    Circle().strokeBorder(ring, lineWidth: 2)
                    if isDone { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) }
                }
                .frame(width: 24, height: 24)
                .frame(width: 36, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
            .accessibilityIdentifier("tick-\(e.title)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(e.title).font(.body.weight(isDone ? .regular : .medium)).lineLimit(2)
                        .strikethrough(isDone).foregroundStyle(isDone ? .secondary : .primary)
                    if e.ours { Sparkle() }
                }
                meta
            }
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { showActions = true }

            if let m = dragMinutes, dragging {
                Text("→ " + BrainDate.time(target(m)))
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.tint, in: .capsule).foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minHeight: 54)
        .background(dragging ? Color(.secondarySystemGroupedBackground) : .clear, in: .rect(cornerRadius: 14))
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: .black.opacity(dragging ? 0.15 : 0), radius: 10, y: 4)
        .offset(y: dragging ? CGFloat(dragMinutes ?? 0) / 15 * Self.pointsPerStep : 0)
        .zIndex(dragging ? 1 : 0)
        .gesture(drag, isEnabled: !isDone)
        .sensoryFeedback(.selection, trigger: dragMinutes)
        .sensoryFeedback(.success, trigger: done == true)
        .animation(.snappy, value: dragging)
        .confirmationDialog(e.title, isPresented: $showActions, titleVisibility: .visible) { actions }
        .accessibilityAction(named: "Move later by an hour") { Task { await move(by: 60) } }
        .accessibilityAction(named: "Move earlier by an hour") { Task { await move(by: -60) } }
    }

    @ViewBuilder
    private var meta: some View {
        HStack(spacing: 5) {
            if let p = e.person {
                AvatarView(name: p.label, photo: p.photo, size: 18)
                    .onTapGesture { app.paths[.home, default: []].append(.person(p.key)) }
                    .accessibilityHidden(false)
                    .accessibilityLabel(p.label)
            }
            Text(metaText).font(.subheadline).foregroundStyle(metaColor).lineLimit(1)
        }
    }

    private var ringColor: Color {
        if e.category == "promise" { return .teal }
        if e.late { return .red }
        return Color(hex: e.color) ?? Color.secondary.opacity(0.7)
    }

    private var metaColor: Color {
        if e.late && !(done ?? e.done) { return .red }
        if e.category == "promise" { return .teal }
        return .secondary
    }

    private var metaText: String {
        var parts: [String] = []
        if e.late, let d = BrainDate.day(e.due) { parts.append("Overdue · " + BrainDate.niceDay(d)) }
        if e.category == "promise" { parts.append("You promised") }
        else if e.category == "waiting" { parts.append("Waiting on") }
        if let p = e.person { parts.append(p.label) }
        if let s = BrainDate.parse(e.sourceAt), !e.late { parts.append(BrainDate.time(s)) }
        if parts.isEmpty || (e.person == nil && !e.ours), let c = e.calendar { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        if let ev = e.originEventId {
            Button("Show Message") { app.paths[.home, default: []].append(.event(ev)) }
        }
        if let id = e.itemId {
            Button("Focus on This") { app.focusItem = id }
        }
        Button("Move to Later Today") { Task { await move(by: 120) } }
        Button("Move to Tomorrow") { Task { await moveTomorrow() } }
        if let id = e.itemId, e.ours {
            Button("Delete", role: .destructive) {
                Task { await app.run("Deleted") { try await $0.delete(id) } }
            }
        }
    }

    // MARK: drag to reschedule

    private var drag: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { v in
                if case .second(true, let d) = v {
                    if !dragging { dragging = true; dragMinutes = 0 }
                    let steps = Int(((d?.translation.height ?? 0) / Self.pointsPerStep).rounded())
                    dragMinutes = steps * 15
                }
            }
            .onEnded { _ in
                let m = dragMinutes ?? 0
                dragging = false
                dragMinutes = nil
                if m != 0 { Task { await move(to: target(m)) } }
            }
    }

    /// Where it starts from: its time on this day, or now (rounded) for carried and untimed things.
    private var base: Date {
        if !e.carried, let a = e.atDate { return a }
        let cal = Calendar.current
        let m = cal.component(.minute, from: now)
        return cal.date(byAdding: .minute, value: (15 - m % 15) % 15, to: now)?.addingTimeInterval(
            -Double(cal.component(.second, from: now))) ?? now
    }

    private func target(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }

    private func move(by minutes: Int) async { await move(to: target(minutes)) }

    private func moveTomorrow() async {
        let cal = Calendar.current
        let t = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: base)) ?? base
        let hm = cal.dateComponents([.hour, .minute], from: e.carried ? now : base)
        await move(to: cal.date(bySettingHour: hm.hour ?? 9, minute: hm.minute ?? 0, second: 0, of: t) ?? t)
    }

    private func move(to date: Date) async {
        let dueDay = BrainDate.dayString(date)
        let dueTime = String(BrainDate.timeString(date).prefix(5))
        let label = "Moved to \(BrainDate.niceDay(date)), \(BrainDate.time(date))"
        if let id = e.itemId {
            await app.run(label) { try await $0.reschedule(id, due: dueDay, dueTime: dueTime) }
        } else if let apple = e.appleId {
            await app.run(label) { try await $0.appleMove(apple, due: dueDay, dueTime: dueTime) }
        }
    }

    // MARK: tick

    private func toggle(_ on: Bool) async {
        done = on
        let ok: Bool
        if let id = e.itemId {
            ok = await app.run(on ? "Nice — one down" : nil) { try await $0.setDone(id, on) }
        } else if let apple = e.appleId {
            ok = await app.run(on ? "Done" : nil) { try await $0.appleDone(apple, done: on) }
        } else {
            ok = false
        }
        if !ok { done = nil }
    }
}

// MARK: - Calendars & lists picker

struct SourcesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var sources: Sources?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let s = sources {
                    Section {
                        ForEach(s.calendars) { c in SourceRow(entry: c) { await set("calendar", c, $0) } }
                    } header: {
                        Text("Calendars")
                    }
                    Section {
                        ForEach(s.lists) { l in SourceRow(entry: l) { await set("list", l, $0) } }
                    } header: {
                        Text("Reminder Lists")
                    } footer: {
                        Text("Turned-on lists put their dated reminders on Today, and you can tick them off there. Second Brain's own lists are always shown.")
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark", description: Text(error))
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Show on Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss(); app.changed() }.accessibilityIdentifier("sources-done")
                }
            }
        }
        .task {
            guard let api = app.api else { return }
            do { sources = try await api.sources() } catch { self.error = error.localizedDescription }
        }
    }

    private func set(_ kind: String, _ entry: SourceEntry, _ shown: Bool) async {
        guard let api = app.api else { return }
        do { sources = try await api.setSource(kind: kind, name: entry.name, shown: shown) }
        catch { app.show(error.localizedDescription, error: true) }
    }
}

private struct SourceRow: View {
    let entry: SourceEntry
    var toggle: (Bool) async -> Void
    @State private var shown: Bool?

    var body: some View {
        let on = shown ?? entry.shown
        let c = Color(hex: entry.color) ?? .gray
        Button {
            guard !entry.ours else { return }
            shown = !on
            Task { await toggle(!on); shown = nil }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(on ? c : .clear)
                    Circle().strokeBorder(c, lineWidth: 2)
                    if on { Image(systemName: "checkmark").font(.caption2.weight(.heavy)).foregroundStyle(.white) }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).foregroundStyle(.primary)
                    if entry.ours {
                        Text("Always shown").font(.footnote).foregroundStyle(.secondary)
                    } else if let a = entry.account {
                        Text(a).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if entry.ours { Sparkle() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - helpers

extension TimelineEntry {
    var isPastEvent: Bool { isEvent && past }

    /// "9:00", "1:00 PM"-style label for the time column (nil for untimed reminders).
    var timeLabel: String? {
        if isEvent { return startDate.map(BrainDate.time) }
        guard dueTime != nil, let a = atDate else { return nil }
        return BrainDate.time(a)
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
