import AppIntents
import SecondBrainKit
import SwiftUI
import WidgetKit

// MARK: - Configuration

struct TodayWidgetConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Today"
    static var description = IntentDescription("What's next on your timeline.")

    @Parameter(title: "Connection code", description: "Copy it in Second Brain → More → Today Widget.")
    var connection: String?
}

/// Ticks a reminder off right from the widget.
struct TickIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark done"
    static var isDiscoverable = false

    @Parameter(title: "Item") var itemId: String?
    @Parameter(title: "Apple reminder") var appleId: String?
    @Parameter(title: "Connection") var connection: String

    init() {}

    init(itemId: String?, appleId: String?, connection: String) {
        self.itemId = itemId
        self.appleId = appleId
        self.connection = connection
    }

    func perform() async throws -> some IntentResult {
        guard let cfg = WidgetConnection.config(from: connection) else { return .result() }
        let api = BrainAPI(config: cfg)
        if let itemId { _ = try await api.setDone(itemId, true) } else if let appleId { _ = try await api.appleDone(appleId, done: true) }
        return .result()
    }
}

// MARK: - Timeline

struct TodayEntry: WidgetKit.TimelineEntry {
    var date: Date
    var items: [TimelineEntry_]
    var connection: String?
    var problem: String?

    typealias TimelineEntry_ = SecondBrainKit.TimelineEntry
}

struct TodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), items: [], connection: nil, problem: nil)
    }

    func snapshot(for configuration: TodayWidgetConfig, in context: Context) async -> TodayEntry {
        await load(configuration)
    }

    func timeline(for configuration: TodayWidgetConfig, in context: Context) async -> WidgetKit.Timeline<TodayEntry> {
        let entry = await load(configuration)
        return WidgetKit.Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func load(_ c: TodayWidgetConfig) async -> TodayEntry {
        guard let cfg = WidgetConnection.config(from: c.connection) else {
            return TodayEntry(date: Date(), items: [], connection: nil, problem: "setup")
        }
        do {
            let t = try await BrainAPI(config: cfg).timeline(day: nil)
            let now = Date()
            let upcoming = t.entries.filter { e in
                if e.done { return false }
                if e.isEvent { return (e.endDate ?? e.startDate ?? now) > now }
                return true
            }
            return TodayEntry(date: now, items: upcoming, connection: c.connection, problem: nil)
        } catch {
            return TodayEntry(date: Date(), items: [], connection: c.connection, problem: "offline")
        }
    }
}

// MARK: - Widget

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PolarReality.SecondBrain.today", intent: TodayWidgetConfig.self,
                               provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "secondbrain:///"))
        }
        .configurationDisplayName("Today")
        .description("Your next events and reminders. Tick reminders off right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 3
        case .systemLarge: return 8
        default: return 2
        }
    }

    var body: some View {
        if entry.problem == "setup" {
            VStack(alignment: .leading, spacing: 4) {
                Label("Today", systemImage: "calendar.day.timeline.left").font(.headline)
                Text("Copy the code in Second Brain → More → Today Widget, then edit this widget and paste it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(entry.items.prefix(limit)) { e in
                    Text((e.timeText.map { $0 + " " } ?? "") + e.title).font(.caption).lineLimit(1)
                }
                if entry.items.isEmpty { Text("Nothing else today").font(.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
                HStack {
                    Text(entry.date.formatted(.dateTime.weekday(.wide)).uppercased())
                        .font(.caption2.weight(.bold)).foregroundStyle(.red)
                    Spacer()
                    if entry.problem == "offline" { Image(systemName: "wifi.slash").font(.caption2).foregroundStyle(.secondary) }
                }
                if entry.items.isEmpty {
                    Text("Nothing else today").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(entry.items.prefix(limit)) { e in row(e) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func row(_ e: SecondBrainKit.TimelineEntry) -> some View {
        let c = Color(widgetHex: e.color) ?? (e.isEvent ? .green : .secondary)
        HStack(spacing: 8) {
            if e.isEvent {
                RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 4, height: 26)
            } else if let code = entry.connection {
                Button(intent: TickIntent(itemId: e.itemId, appleId: e.appleId, connection: code)) {
                    Image(systemName: "circle").font(.body).foregroundStyle(e.late ? Color.red : c)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(e.title).font(.subheadline.weight(e.isEvent ? .semibold : .regular)).lineLimit(1)
                if let t = e.timeText, family != .systemSmall || e.isEvent {
                    Text(t).font(.caption).foregroundStyle(e.late ? Color.red : .secondary).lineLimit(1)
                }
            }
        }
    }
}

private extension SecondBrainKit.TimelineEntry {
    var timeText: String? {
        if late { return "Overdue" }
        if carried { return "Now" }
        if isEvent, let s = startDate { return BrainDate.time(s) }
        guard dueTime != nil, let a = atDate else { return nil }
        return BrainDate.time(a)
    }
}

private extension Color {
    init?(widgetHex hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
