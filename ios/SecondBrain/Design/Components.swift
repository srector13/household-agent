import SecondBrainKit
import SwiftUI

// MARK: - Colors

extension Color {
    /// "#34C759" → Color. Calendar colors come from the Mac.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Dark slate for neutral tiles (no purple anywhere in this app).
    static let slate = Color(red: 0.20, green: 0.24, blue: 0.32)

    static func category(_ item: Item) -> Color {
        if item.kind == "event" { return .red }
        if item.collection != nil { return .orange }
        switch item.category {
        case "promise": return .teal
        case "waiting": return .blue
        default: return .green
        }
    }
}

enum Symbols {
    static func item(_ item: Item) -> String {
        if item.kind == "event" { return "calendar" }
        if item.collection == "gift_ideas" { return "gift" }
        if item.collection == "about_person" { return "person.text.rectangle" }
        if item.collection != nil { return "bookmark" }
        switch item.category {
        case "promise": return "handshake"
        case "waiting": return "hourglass"
        default: return "checklist"
        }
    }

    static func status(_ s: String) -> (String, Color) {
        switch s {
        case "done": return ("checkmark.circle.fill", .green)
        case "needs_review": return ("questionmark.circle.fill", .orange)
        case "failed": return ("exclamationmark.triangle.fill", .red)
        case "skipped", "rejected", "undone": return ("minus.circle", .secondary)
        default: return ("clock", .blue)
        }
    }
}

// MARK: - Avatar

/// A contact photo from the Mac (loaded with the server's password), or initials.
struct AvatarView: View {
    @Environment(AppModel.self) private var app
    var name: String?
    var photo: String?
    var size: CGFloat = 40
    var symbol: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(LinearGradient(colors: [Color(white: 0.72), Color(white: 0.56)], startPoint: .top, endPoint: .bottom))
                if let symbol {
                    Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text(Self.initials(name)).font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: photo) {
            guard let photo, let api = app.api else { image = nil; return }
            image = await ImageCache.shared.image(photo, api: api)
        }
        .accessibilityHidden(true)
    }

    static func initials(_ name: String?) -> String {
        let parts = (name ?? "?").split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

actor ImageCache {
    static let shared = ImageCache()
    private var cache: [String: UIImage] = [:]

    func image(_ path: String, api: BrainAPI) async -> UIImage? {
        if let hit = cache[path] { return hit }
        guard let data = try? await api.imageData(path), let img = UIImage(data: data) else { return nil }
        cache[path] = img
        return img
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let t = app.toast {
            HStack(spacing: 10) {
                Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(t.isError ? .red : .green)
                Text(t.message).font(.subheadline.weight(.medium)).lineLimit(3)
                if let undo = t.undo {
                    Button("Undo") {
                        app.toast = nil
                        Task { await undo() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation { app.toast = nil } }
            .id(t.id)
            .accessibilityIdentifier("toast")
        }
    }
}

// MARK: - Capture

/// Lives above the tab bar: one tap to get a thought out of your head.
struct CaptureBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.showCapture = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.blue)
                Text("Capture a thought…").foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "mic.fill").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("capture-bar")
    }
}

struct CaptureSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var dictation = Dictation()
    @State private var simulated = false   // screenshot mode: show the listening look without a mic
    @FocusState private var focused: Bool

    private var listening: Bool { dictation.listening || simulated }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Pick up the dry cleaning Friday, call Mom about Sunday…", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .font(.body)
                    .focused($focused)
                    .padding(14)
                    .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 18))
                    .accessibilityIdentifier("capture-text")

                HStack {
                    Spacer()
                    MicButton(listening: listening, level: dictation.level) {
                        if listening { stopListening() } else { startListening() }
                    }
                    Spacer()
                }
                .padding(.top, 6)
                Text(listening ? "Listening… tap the text to edit, or Add when you're done."
                               : "Tap the mic to talk, or type. To-dos, events and ideas get sorted out for you.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                if let e = dictation.error {
                    Label(e, systemImage: "mic.slash").font(.footnote).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dictation.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if busy { ProgressView() } else { Text("Add").bold() }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .accessibilityIdentifier("capture-add")
                }
            }
            .onAppear {
                if app.captureDictate {
                    app.captureDictate = false
                    startListening()
                } else {
                    focused = true
                }
            }
            .onDisappear { dictation.stop() }
            .onChange(of: dictation.transcript) { _, t in if dictation.listening { text = t } }
            .onChange(of: focused) { _, f in if f && listening { stopListening() } }
            .sensoryFeedback(.start, trigger: dictation.listening) { _, now in now }
        }
    }

    private func startListening() {
        focused = false
        if AppModel.screenshotMode {
            simulated = true
            text = "Pick up the dry cleaning Friday and call Mom about Sunday lunch"
            return
        }
        let current = text
        Task { await dictation.start(prefix: current) }
    }

    private func stopListening() {
        simulated = false
        dictation.stop()
    }

    private func send() async {
        stopListening()
        busy = true
        defer { busy = false }
        let t = text
        if await app.run("Got it — sorting it out", { try await $0.capture(t) }) {
            dismiss()
        }
    }
}

/// A big glass mic that pulses with your voice while it listens.
private struct MicButton: View {
    var listening: Bool
    var level: Float
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if listening {
                    Circle().fill(Color.red.opacity(0.18))
                        .frame(width: 96 + CGFloat(level) * 40, height: 96 + CGFloat(level) * 40)
                        .animation(.easeOut(duration: 0.12), value: level)
                }
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: listening)
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(listening ? Color.red : Color.blue, in: .circle)
            }
            .frame(width: 140, height: 140)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? "Stop listening" : "Dictate")
        .accessibilityIdentifier("capture-mic")
    }
}

// MARK: - Loading

/// Loads `T`, shows a spinner the first time, an error with Retry, pull to refresh, and reloads when
/// something changes elsewhere in the app.
struct Loader<T, Content: View>: View {
    @Environment(AppModel.self) private var app
    var load: (BrainAPI) async throws -> T
    @ViewBuilder var content: (T) -> Content
    @State private var value: T?
    @State private var error: String?

    init(_ load: @escaping (BrainAPI) async throws -> T, @ViewBuilder content: @escaping (T) -> Content) {
        self.load = load
        self.content = content
    }

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await reload() } }.buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: app.tick) { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        guard let api = app.api else { return }
        do {
            value = try await load(api)
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            if value == nil { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Small pieces

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
    }
}

struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.28))
    }
}

struct CheckCircle: View {
    var on: Bool
    var color: Color = .blue
    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? color : Color.secondary.opacity(0.5), lineWidth: 2)
            if on {
                Circle().fill(color)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .animation(.spring(duration: 0.25), value: on)
    }
}

extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
