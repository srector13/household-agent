import SecondBrainKit
import SwiftUI

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
