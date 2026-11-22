import Foundation
import Security
import Observation
import SecondBrainKit
import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case home, people, lists, review, more
}

/// Screens pushed onto a tab's navigation stack.
enum Route: Hashable {
    case event(String)
    case person(String)
    case today
    case weekly
    case activity(status: String?)
    case status
    case settings
    case server
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError = false
    var undo: (@MainActor () async -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// App-wide state: the server, navigation, the shared toast, and a tick that tells screens to reload.
@MainActor
@Observable
final class AppModel {
    // connection
    private(set) var config: ServerConfig?
    private(set) var api: BrainAPI?
    var info: Info?
    var connectionError: String?

    // navigation
    var tab: AppTab = .home
    var paths: [AppTab: [Route]] = [:]
    var focusItem: String?
    var showCapture = false
    /// The next capture sheet opens listening (from the Control Center / Lock Screen control).
    var captureDictate = false

    // feedback
    var toast: Toast?
    /// Bumped after anything changes; screens reload when it moves.
    private(set) var tick = 0

    private var streamTask: Task<Void, Never>?
    private var tickDebounce: Task<Void, Never>?

    static let screenshotMode = ProcessInfo.processInfo.arguments.contains("-SecondBrainScreenshots")

    init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-SecondBrainReset") { Store.clear() }
        if let i = args.firstIndex(of: "-SecondBrainServer"), i + 1 < args.count, let cfg = ServerConfig.parse(args[i + 1]) {
            Store.save(cfg)
        }
        if let cfg = Store.load() { use(cfg) }
    }

    var isConnected: Bool { api != nil }

    func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    // MARK: connection

    func use(_ cfg: ServerConfig) {
        config = cfg
        api = BrainAPI(config: cfg)
        Store.save(cfg)
        Task { await refreshInfo() }
    }

    /// Checks a server before saving it. Returns an error message, or nil when it works.
    func connect(address: String, password: String) async -> String? {
        guard let cfg = ServerConfig.parse(address, password: password) else {
            return "Enter the brain's address, like 100.101.102.103:8080 or https://brain.your-tailnet.ts.net"
        }
        do {
            let i = try await BrainAPI(config: cfg).info()
            use(cfg)
            info = i
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func disconnect() {
        streamTask?.cancel()
        Store.clear()
        config = nil
        api = nil
        info = nil
        paths = [:]
    }

    func refreshInfo() async {
        guard let api else { return }
        do {
            info = try await api.info()
            connectionError = nil
            Notifier.shared.setBadge(info?.badge ?? 0)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    // MARK: change + live updates

    /// Something changed (an action, a notification, the live stream): reload what's on screen.
    func changed() {
        tick += 1
        Task { await refreshInfo() }
    }

    private func changedSoon() {
        tickDebounce?.cancel()
        tickDebounce = Task {
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { changed() }
        }
    }

    /// Listens to the brain's live stream while the app is open.
    func startLive() {
        guard streamTask == nil, let api else { return }
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let req = try api.request("GET", "/api/stream")
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let body = line.dropFirst(5)
                        if body.contains("\"type\"") || body.contains("\"status\"") {
                            await MainActor.run { self?.changedSoon() }
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopLive() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: feedback

    func show(_ message: String, error: Bool = false, undo: (@MainActor () async -> Void)? = nil) {
        toast = Toast(message: message, isError: error, undo: undo)
        let id = toast?.id
        Task {
            try? await Task.sleep(for: .seconds(undo == nil ? (error ? 4.5 : 2.4) : 6))
            if toast?.id == id { withAnimation { toast = nil } }
        }
    }

    /// Runs an API call, shows its error if it fails, and reloads screens when it succeeds.
    @discardableResult
    func run(_ success: String? = nil, undo: (@MainActor () async -> Void)? = nil,
             _ body: (BrainAPI) async throws -> Void) async -> Bool {
        guard let api else { return false }
        do {
            try await body(api)
            if let success { show(success, undo: undo) }
            changed()
            return true
        } catch {
            show(error.localizedDescription, error: true)
            return false
        }
    }

    // MARK: deep links ("/review", "/?focus=itm_…", "/events/imessage:1", "/people/h-…")

    /// Opens the capture sheet, optionally already listening.
    func startCapture(dictate: Bool) {
        captureDictate = dictate
        if showCapture {  // already open: reopen so it starts listening
            showCapture = false
            Task { try? await Task.sleep(for: .milliseconds(350)); showCapture = true }
        } else {
            showCapture = true
        }
    }

    func open(link: String) {
        let s = link.replacingOccurrences(of: "secondbrain://", with: "/")
        if let r = s.range(of: "focus=") {
            let id = String(s[r.upperBound...].prefix { $0 != "&" })
            tab = .home
            focusItem = id.removingPercentEncoding ?? id
            return
        }
        let path = s.split(separator: "?").first.map(String.init) ?? s
        if path.hasPrefix("/capture") {
            startCapture(dictate: s.contains("dictate=1"))
            return
        }
        func push(_ t: AppTab, _ route: Route) { tab = t; paths[t] = [route] }
        if path == "/" || path.isEmpty { tab = .home; paths[.home] = [] }
        else if path.hasPrefix("/review") { tab = .review; paths[.review] = [] }
        else if path.hasPrefix("/items") { tab = .lists; paths[.lists] = [] }
        else if path.hasPrefix("/people/") { push(.people, .person(String(path.dropFirst("/people/".count)))) }
        else if path.hasPrefix("/people") { tab = .people; paths[.people] = [] }
        else if path.hasPrefix("/events/") {
            let id = String(path.dropFirst("/events/".count))
            push(.home, .event(id.removingPercentEncoding ?? id))
        }
        else if path.hasPrefix("/today") { push(.more, .today) }
        else if path.hasPrefix("/weekly") { push(.more, .weekly) }
        else if path.hasPrefix("/system") { push(.more, .status) }
        else if path.hasPrefix("/settings") { push(.more, .settings) }
        else if path.hasPrefix("/activity") { push(.more, .activity(status: nil)) }
        else { tab = .home }
    }
}

/// Server address in UserDefaults, password in the Keychain (falls back to UserDefaults where the
/// Keychain isn't available, e.g. some re-signed builds).
enum Store {
    private static let urlKey = "server.url"
    private static let pwKey = "server.password"

    static func load() -> ServerConfig? {
        guard let s = UserDefaults.standard.string(forKey: urlKey), let url = URL(string: s) else { return nil }
        return ServerConfig(baseURL: url, password: Keychain.get(pwKey) ?? UserDefaults.standard.string(forKey: pwKey))
    }

    static func save(_ cfg: ServerConfig) {
        UserDefaults.standard.set(cfg.baseURL.absoluteString, forKey: urlKey)
        if let pw = cfg.password {
            if !Keychain.set(pw, for: pwKey) { UserDefaults.standard.set(pw, forKey: pwKey) }
        } else {
            Keychain.delete(pwKey)
            UserDefaults.standard.removeObject(forKey: pwKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: urlKey)
        UserDefaults.standard.removeObject(forKey: pwKey)
        Keychain.delete(pwKey)
    }
}

enum Keychain {
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
