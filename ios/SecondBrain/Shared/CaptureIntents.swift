import AppIntents
import Foundation

// Compiled into both the app and the widget extension (Control Center control, Lock Screen widget).
// The control's intent opens the app; the system runs `perform()` in the app's process, which then
// shows the capture sheet already listening.

enum CaptureTarget: String, AppEnum {
    case capture

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [CaptureTarget: DisplayRepresentation] = [.capture: "Capture a thought"]
}

/// "Capture a thought": opens Second Brain with the capture sheet listening.
struct OpenCaptureIntent: OpenIntent {
    static let title: LocalizedStringResource = "Capture a thought"
    static let description = IntentDescription("Opens Second Brain, already listening — just start talking.")

    @Parameter(title: "Screen", default: .capture)
    var target: CaptureTarget

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRouter.request(dictate: true)
        return .result()
    }
}

/// Hands a capture request from an intent to the running app.
enum CaptureRouter {
    static let requested = Notification.Name("SecondBrainCaptureRequested")
    @MainActor private(set) static var pending: Bool?

    @MainActor
    static func request(dictate: Bool) {
        pending = dictate
        NotificationCenter.default.post(name: requested, object: nil)
    }

    /// The pending request (nil if none), cleared once read.
    @MainActor
    static func take() -> Bool? {
        defer { pending = nil }
        return pending
    }
}
