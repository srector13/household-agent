import SecondBrainKit
import SwiftUI

/// One task, full screen: its first step, its steps, an optional timer, and a celebration when it's done.
struct FocusView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let itemId: String
    @State private var d: FocusDetail?
    @State private var error: String?
    @State private var minutes = 10
    @State private var celebrating = false
    @State private var busy = false
    @State private var stepsDone: Set<Int> = []
    @State private var timeUp = false

    var body: some View {
        NavigationStack {
            Group {
                if let d {
                    if celebrating { celebration(d) } else { focus(d) }
                } else if let error {
                    ContentUnavailableView("Couldn't open this", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
                ToolbarItem(placement: .principal) {
                    Text("Focus").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .task { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sensoryFeedback(.success, trigger: celebrating)
        .sensoryFeedback(.warning, trigger: timeUp)
    }

    // MARK: focus

    private func focus(_ d: FocusDetail) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(kicker(d)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text(d.title).font(.system(size: 34, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("focus-title")
                    if let c = d.context { Text(c).foregroundStyle(.secondary) }
                    if let step = d.firstStep {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "shoeprints.fill").foregroundStyle(.green)
                                .frame(width: 34, height: 34).background(Color.green.opacity(0.15), in: .rect(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("START HERE").font(.caption.weight(.bold)).foregroundStyle(.green)
                                Text(step).font(.body)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    } else {
                        Button {
                            Task { await breakdown() }
                        } label: {
                            Label(busy ? "Thinking…" : "Find a tiny first step", systemImage: "shoeprints.fill")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(busy)
                    }
                    if !d.steps.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(d.steps.enumerated()), id: \.offset) { i, s in
                                Button { toggleStep(i) } label: {
                                    HStack(spacing: 12) {
                                        CheckCircle(on: stepsDone.contains(i), color: .green)
                                        Text(s).strikethrough(stepsDone.contains(i))
                                            .foregroundStyle(stepsDone.contains(i) ? .secondary : .primary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 11).padding(.horizontal, 14)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                if i < d.steps.count - 1 { Divider().padding(.leading, 50) }
                            }
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                    }
                    TimerBlock(timer: d.timer, minutes: $minutes, timeUp: $timeUp,
                               start: { m in Task { await startTimer(m) } },
                               add: { Task { await addFive() } },
                               stop: { Task { await stopTimer() } })
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }
            VStack(spacing: 6) {
                if timeUp {
                    Text("Nice work. Done, or keep going?").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                }
                Button { Task { await finish() } } label: {
                    Label("Done", systemImage: "checkmark").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .disabled(busy)
                .accessibilityIdentifier("focus-done")
                Button("Not now") { close() }.padding(.vertical, 6)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
        }
    }

    private func kicker(_ d: FocusDetail) -> String {
        switch d.category {
        case "promise": return "🤝 You promised \(d.person ?? "someone")"
        case "waiting": return "⏳ Follow up with \(d.person ?? "them")"
        default: return d.person.map { "From \($0)" } ?? "Focus on one thing"
        }
    }

    // MARK: celebration

    private func celebration(_ d: FocusDetail) -> some View {
        ZStack {
            Confetti()
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "checkmark").font(.system(size: 54, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 110, height: 110).background(Color.green, in: .circle)
                    .transition(.scale.combined(with: .opacity))
                Text("Done!").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("“\(d.title)” is off your plate.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
                if let n = d.next {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next up · \(n.why)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(n.title).font(.headline)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    Button {
                        Task { await switchTo(n.itemId) }
                    } label: {
                        Text("Focus on it").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent).tint(.green)
                    Button("Take a break") { close() }.padding(.vertical, 6)
                } else {
                    Button { close() } label: {
                        Text("Back to my day").font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent).tint(.green)
                }
            }
            .padding(22)
        }
    }

    // MARK: actions

    private func load(_ id: String? = nil) async {
        guard let api = app.api else { return }
        do {
            let detail = try await api.focus(id ?? itemId)
            d = detail
            stepsDone = Set((UserDefaults.standard.array(forKey: "focusSteps:\(detail.itemId)") as? [Int]) ?? [])
            if let t = detail.timer { minutes = t.minutes }
            timeUp = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func switchTo(_ id: String) async {
        celebrating = false
        d = nil
        app.focusItem = id
        await load(id)
    }

    private func toggleStep(_ i: Int) {
        if stepsDone.contains(i) { stepsDone.remove(i) } else { stepsDone.insert(i) }
        if let id = d?.itemId { UserDefaults.standard.set(Array(stepsDone), forKey: "focusSteps:\(id)") }
    }

    private func breakdown() async {
        guard let id = d?.itemId, let api = app.api else { return }
        busy = true
        defer { busy = false }
        do {
            let b = try await api.breakdown(id)
            d?.firstStep = b.firstStep
            d?.steps = b.steps
        } catch {
            app.show(error.localizedDescription, error: true)
        }
    }

    private func startTimer(_ m: Int) async {
        guard let cur = d, let api = app.api else { return }
        do {
            let r = try await api.startTimer(cur.itemId, minutes: m)
            d?.timer = r.timer
            timeUp = false
            if let t = r.timer, let end = BrainDate.parse(t.endsAt), !AppModel.screenshotMode {
                if await Notifier.shared.status() == .notDetermined { _ = await Notifier.shared.requestPermission() }
                Notifier.shared.scheduleFocus(itemId: cur.itemId, title: cur.title, minutes: t.minutes, endsAt: end)
            }
        } catch {
            app.show(error.localizedDescription, error: true)
        }
    }

    private func addFive() async {
        guard let t = d?.timer, let end = BrainDate.parse(t.endsAt) else { return }
        let left = max(0, end.timeIntervalSinceNow / 60)
        await startTimer(Int(left.rounded()) + 5)
    }

    private func stopTimer() async {
        _ = try? await app.api?.stopTimer()
        Notifier.shared.cancelFocus()
        d?.timer = nil
        timeUp = false
    }

    private func finish() async {
        guard let cur = d, let api = app.api else { return }
        busy = true
        defer { busy = false }
        do {
            try await api.setDone(cur.itemId, true)
            if cur.timer != nil { _ = try? await api.stopTimer() }
            Notifier.shared.cancelFocus()
            UserDefaults.standard.removeObject(forKey: "focusSteps:\(cur.itemId)")
            withAnimation(.spring(duration: 0.5)) { celebrating = true }
            app.changed()
        } catch {
            app.show(error.localizedDescription, error: true)
        }
    }

    private func close() {
        app.focusItem = nil
        dismiss()
    }
}

/// The ring: pick 5/10/25 minutes, then it counts down.
private struct TimerBlock: View {
    var timer: FocusTimer?
    @Binding var minutes: Int
    @Binding var timeUp: Bool
    var start: (Int) -> Void
    var add: () -> Void
    var stop: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let end = timer.flatMap { BrainDate.parse($0.endsAt) }
                let total = Double((timer?.minutes ?? minutes) * 60)
                let left = end.map { max(0, $0.timeIntervalSince(ctx.date)) } ?? total
                ZStack {
                    Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 10)
                    if timer != nil {
                        Circle().trim(from: 0, to: total > 0 ? left / total : 0)
                            .stroke(left <= 0 ? Color.green : .blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.5), value: left)
                    }
                    VStack(spacing: 2) {
                        Text(clock(left)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(timer == nil ? "MINUTES" : left <= 0 ? "TIME'S UP" : "FOCUS")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 160)
                .onChange(of: left <= 0 && timer != nil) { _, up in if up { timeUp = true } }
            }
            if timer != nil {
                HStack {
                    Button("+5 min", action: add).buttonStyle(.bordered)
                    Button("Stop timer", action: stop).buttonStyle(.bordered)
                }
            } else {
                HStack {
                    ForEach([5, 10, 25], id: \.self) { m in
                        Button("\(m) min") { minutes = m }
                            .buttonStyle(.bordered)
                            .tint(minutes == m ? .blue : .secondary)
                            .fontWeight(minutes == m ? .bold : .regular)
                    }
                    Button("Start") { start(minutes) }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("focus-start")
                }
            }
        }
    }

    private func clock(_ s: Double) -> String {
        let n = Int(s.rounded(.up))
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }
}

/// A burst of confetti in friendly colors (no purple).
struct Confetti: View {
    @State private var start = Date()
    private let pieces: [(x: Double, vx: Double, vy: Double, spin: Double, color: Color, w: Double, h: Double)] = (0..<90).map { _ in
        let colors: [Color] = [.green, .blue, .orange, .yellow, .red, .teal, .cyan]
        return (Double.random(in: 0.3...0.7), Double.random(in: -260...260), Double.random(in: -900 ... -420),
                Double.random(in: -8...8), colors.randomElement()!, Double.random(in: 6...12), Double.random(in: 4...8))
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSince(start)
                guard t < 3 else { return }
                for p in pieces {
                    let x = p.x * size.width + p.vx * t
                    let y = size.height * 0.42 + p.vy * t + 900 * t * t
                    var c = g
                    c.opacity = max(0, 1 - t / 3)
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * t))
                    c.fill(Path(CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)), with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
