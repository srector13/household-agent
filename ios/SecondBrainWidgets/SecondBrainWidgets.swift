import AppIntents
import SwiftUI
import WidgetKit

@main
struct SecondBrainWidgets: WidgetBundle {
    var body: some Widget {
        CaptureControl()
        CaptureLockWidget()
    }
}

/// Control Center, the Lock Screen's bottom corners and the Action button:
/// one tap opens Second Brain already listening.
struct CaptureControl: ControlWidget {
    static let kind = "PolarReality.SecondBrain.capture"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label("Capture a thought", systemImage: "brain")
            }
        }
        .displayName("Capture a thought")
        .description("Opens Second Brain, already listening.")
    }
}

/// A Lock Screen widget that does the same (for the widget row under the clock).
struct CaptureLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PolarReality.SecondBrain.capture-widget", provider: StaticProvider()) { _ in
            CaptureLockView()
        }
        .configurationDisplayName("Capture a thought")
        .description("Tap to talk a thought into Second Brain.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

struct StaticEntry: TimelineEntry {
    let date: Date
}

struct StaticProvider: TimelineProvider {
    func placeholder(in context: Context) -> StaticEntry { StaticEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (StaticEntry) -> Void) { completion(StaticEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StaticEntry>) -> Void) {
        completion(Timeline(entries: [StaticEntry(date: .now)], policy: .never))
    }
}

struct CaptureLockView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "brain").font(.system(size: 22, weight: .semibold))
                }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.title2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Capture").font(.headline)
                        Text("a thought").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "brain").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Text("Capture a thought").font(.headline).foregroundStyle(.white)
                    Label("Tap and talk", systemImage: "mic.fill").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .widgetURL(URL(string: "secondbrain://capture?dictate=1"))
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.53, blue: 1.0), Color(red: 0.07, green: 0.71, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
