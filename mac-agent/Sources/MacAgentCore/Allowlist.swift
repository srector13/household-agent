import Foundation

/// Normalizes handles exactly like the brain's `normalize_handle` (brain/app/gate.py):
/// emails → lowercase address; phone numbers → "+" + digits, a 10-digit US number gets a leading 1.
public enum HandleNormalizer {
    public static func normalize(_ handle: String?) -> String {
        guard let raw = handle else { return "" }
        let h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return "" }
        if h.contains("@") {
            // "Name <addr@host>" → addr@host
            if let lt = h.lastIndex(of: "<"), let gt = h.lastIndex(of: ">"), lt < gt {
                let addr = h[h.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
                if !addr.isEmpty { return addr.lowercased() }
            }
            return h.lowercased()
        }
        var digits = h.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }
            .map(String.init).joined()
        if digits.count == 10 { digits = "1" + digits }
        return digits.isEmpty ? h : "+" + digits
    }
}

/// The iMessage allowlist synced from the brain (GET /api/agent/config). The brain is the source of
/// truth; this cached copy lets the agent keep filtering while the brain is unreachable.
public struct SyncedAllowlist: Codable, Equatable, Sendable {
    public var settingsVersion: Int
    public var handles: [String]
    public var chatIds: [String]
    public var allowSelfNotes: Bool
    public var syncedAt: String?

    enum CodingKeys: String, CodingKey {
        case settingsVersion = "settings_version"
        case handles
        case chatIds = "chat_ids"
        case allowSelfNotes = "allow_self_notes"
        case syncedAt = "synced_at"
    }

    public init(settingsVersion: Int, handles: [String], chatIds: [String], allowSelfNotes: Bool = false,
                syncedAt: String? = nil) {
        self.settingsVersion = settingsVersion
        self.handles = handles.map(HandleNormalizer.normalize).filter { !$0.isEmpty }
        self.chatIds = chatIds.filter { !$0.isEmpty }
        self.allowSelfNotes = allowSelfNotes
        self.syncedAt = syncedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(settingsVersion: try c.decode(Int.self, forKey: .settingsVersion),
                  handles: try c.decodeIfPresent([String].self, forKey: .handles) ?? [],
                  chatIds: try c.decodeIfPresent([String].self, forKey: .chatIds) ?? [],
                  allowSelfNotes: try c.decodeIfPresent(Bool.self, forKey: .allowSelfNotes) ?? false,
                  syncedAt: try c.decodeIfPresent(String.self, forKey: .syncedAt))
    }

    public init(remote: RemoteAgentConfig, syncedAt: String? = nil) {
        self.init(settingsVersion: remote.settingsVersion, handles: remote.allow.handles,
                  chatIds: remote.allow.chatIds, allowSelfNotes: remote.allowSelfNotes ?? false,
                  syncedAt: syncedAt)
    }

    public var size: Int { handles.count + chatIds.count }

    /// True when a message with this handle / chat may leave the Mac.
    public func allows(handle: String?, chatIdentifier: String?, chatGUID: String?) -> Bool {
        let n = HandleNormalizer.normalize(handle)
        if !n.isEmpty, handles.contains(n) { return true }
        for c in [chatGUID, chatIdentifier] {
            if let c, !c.isEmpty, chatIds.contains(c) { return true }
        }
        return false
    }

    // MARK: Persistence (synced_config.json)

    public static func load(from url: URL) -> SyncedAllowlist? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncedAllowlist.self, from: data)
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writeAtomically(try enc.encode(self), to: url)
    }
}

/// GET /api/agent/config response.
public struct RemoteAgentConfig: Codable, Equatable, Sendable {
    public struct Allow: Codable, Equatable, Sendable {
        public var handles: [String]
        public var chatIds: [String]

        public init(handles: [String], chatIds: [String]) {
            self.handles = handles
            self.chatIds = chatIds
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            handles = try c.decodeIfPresent([String].self, forKey: .handles) ?? []
            chatIds = try c.decodeIfPresent([String].self, forKey: .chatIds) ?? []
        }

        enum CodingKeys: String, CodingKey { case handles, chatIds }
    }

    public var settingsVersion: Int
    public var allow: Allow
    public var allowSelfNotes: Bool?

    public init(settingsVersion: Int, allow: Allow, allowSelfNotes: Bool? = nil) {
        self.settingsVersion = settingsVersion
        self.allow = allow
        self.allowSelfNotes = allowSelfNotes
    }
}

/// POST /api/agent/heartbeat response.
public struct HeartbeatAck: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var settingsVersion: Int?
}
