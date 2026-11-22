import AppIntents
import Foundation
import SecondBrainKit

/// "Hey Siri, brain dump in Second Brain" → Siri asks what's on your mind, you say it, it's sent.
/// Runs without opening the app, so it also works from the Action button and the Lock Screen.
struct CaptureThoughtIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture a thought by voice"
    static let description = IntentDescription("Sends a thought to your brain to be sorted into to-dos, events and notes.")
    static let openAppWhenRun = false

    @Parameter(title: "Thought", requestValueDialog: IntentDialog("What's on your mind?"))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let thought = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thought.isEmpty else { return .result(dialog: "Nothing to capture.") }
        guard let cfg = Store.load() else {
            return .result(dialog: "Open Second Brain once to connect it to your brain first.")
        }
        do {
            try await BrainAPI(config: cfg).capture(thought)
            return .result(dialog: "Got it — sorting it out.")
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: "Couldn't reach your brain: \(error.localizedDescription)"))
        }
    }
}

struct SecondBrainShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureThoughtIntent(),
            phrases: [
                "Brain dump in \(.applicationName)",
                "Capture a thought in \(.applicationName)",
                "Tell \(.applicationName) something",
                "Remember something in \(.applicationName)",
            ],
            shortTitle: "Brain dump",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: OpenCaptureIntent(),
            phrases: ["Open capture in \(.applicationName)", "Start a capture in \(.applicationName)"],
            shortTitle: "Capture (open the app)",
            systemImageName: "mic.fill"
        )
    }
}
