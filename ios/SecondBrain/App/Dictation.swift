import AVFoundation
import Foundation
import Observation
import Speech

/// Live speech-to-text for the capture sheet. Starts listening the moment you open it from the
/// Control Center / Lock Screen control, and stops when you send, cancel or tap the mic.
/// Recognition stays on the phone when the device supports it.
@MainActor
@Observable
final class Dictation {
    var transcript = ""
    var listening = false
    var level: Float = 0          // 0…1, for the pulsing mic
    var error: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var base = ""

    /// Starts listening; anything already typed (`prefix`) is kept in front of what you say.
    func start(prefix: String = "") async {
        guard !listening else { return }
        error = nil
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            error = "Speech recognition is off for Second Brain — turn it on in Settings, or type instead."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "The microphone is off for Second Brain — turn it on in Settings, or type instead."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Dictation isn't available right now — type instead."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            base = prefix.isEmpty ? "" : prefix.trimmingCharacters(in: .whitespaces) + " "

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                req.append(buffer)
                let lvl = Self.rms(buffer)
                Task { @MainActor in self?.level = lvl }
            }
            engine.prepare()
            try engine.start()
            listening = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = self.base + text }
                    if err != nil || final { self.stop() }
                }
            }
        } catch {
            self.error = "Couldn't start listening: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        guard listening || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        listening = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 12)
    }
}
