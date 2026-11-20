import Foundation

/// Agent configuration, read from ~/Library/Application Support/HouseholdAgent/config.json.
/// Every field except `brain_url` is optional.
public struct AgentConfig: Codable, Equatable, Sendable {
    /// Base URL of the brain, e.g. "http://brain.tailnet-name.ts.net:8080".
    public var brainURL: String
    /// Keychain generic-password item holding the bearer token.
    public var keychainService: String
    public var keychainAccount: String
    /// When true (default), the iMessage allowlist is synced from the brain (GET /api/agent/config)
    /// and used as the prefilter; `allowHandles` is then ignored.
    public var syncAllowlist: Bool
    /// Local prefilter, used only when `syncAllowlist` is false (handles, chat identifiers or chat
    /// GUIDs). The brain enforces the real allowlist; an empty list means "send everything".
    public var allowHandles: [String]
    /// Handle → display label (used for `sender_label` and recent_context prefixes).
    public var labels: [String: String]
    /// Number of previous messages in the same chat to include as recent_context.
    public var contextCount: Int
    public var logLevel: String
    /// Override for chat.db (useful for testing against a copy).
    public var chatDBPath: String?
    public var pollIntervalS: Double
    public var heartbeatIntervalS: Double
    public var longPollWaitS: Int
    /// NSUnarchiver can raise an uncatchable Objective-C exception on malformed data, which under
    /// KeepAlive would turn into a crash loop on the same row. Off by default; the pure-Swift parser
    /// handles the common case.
    public var useNSUnarchiverFallback: Bool

    enum CodingKeys: String, CodingKey {
        case brainURL = "brain_url"
        case keychainService = "keychain_service"
        case keychainAccount = "keychain_account"
        case syncAllowlist = "sync_allowlist"
        case allowHandles = "allow_handles"
        case labels
        case contextCount = "context_count"
        case logLevel = "log_level"
        case chatDBPath = "chat_db_path"
        case pollIntervalS = "poll_interval_s"
        case heartbeatIntervalS = "heartbeat_interval_s"
        case longPollWaitS = "long_poll_wait_s"
        case useNSUnarchiverFallback = "use_nsunarchiver_fallback"
    }

    public init(
        brainURL: String,
        keychainService: String = AgentInfo.bundleIdentifier,
        keychainAccount: String = "agent_token",
        syncAllowlist: Bool = true,
        allowHandles: [String] = [],
        labels: [String: String] = [:],
        contextCount: Int = 5,
        logLevel: String = "info",
        chatDBPath: String? = nil,
        pollIntervalS: Double = 60,
        heartbeatIntervalS: Double = 60,
        longPollWaitS: Int = 30,
        useNSUnarchiverFallback: Bool = false
    ) {
        self.brainURL = brainURL
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.syncAllowlist = syncAllowlist
        self.allowHandles = allowHandles
        self.labels = labels
        self.contextCount = contextCount
        self.logLevel = logLevel
        self.chatDBPath = chatDBPath
        self.pollIntervalS = pollIntervalS
        self.heartbeatIntervalS = heartbeatIntervalS
        self.longPollWaitS = longPollWaitS
        self.useNSUnarchiverFallback = useNSUnarchiverFallback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentConfig(brainURL: try c.decode(String.self, forKey: .brainURL))
        self = d
        keychainService = try c.decodeIfPresent(String.self, forKey: .keychainService) ?? d.keychainService
        keychainAccount = try c.decodeIfPresent(String.self, forKey: .keychainAccount) ?? d.keychainAccount
        syncAllowlist = try c.decodeIfPresent(Bool.self, forKey: .syncAllowlist) ?? d.syncAllowlist
        allowHandles = try c.decodeIfPresent([String].self, forKey: .allowHandles) ?? d.allowHandles
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? d.labels
        contextCount = try c.decodeIfPresent(Int.self, forKey: .contextCount) ?? d.contextCount
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel
        chatDBPath = try c.decodeIfPresent(String.self, forKey: .chatDBPath)
        pollIntervalS = try c.decodeIfPresent(Double.self, forKey: .pollIntervalS) ?? d.pollIntervalS
        heartbeatIntervalS = try c.decodeIfPresent(Double.self, forKey: .heartbeatIntervalS) ?? d.heartbeatIntervalS
        longPollWaitS = try c.decodeIfPresent(Int.self, forKey: .longPollWaitS) ?? d.longPollWaitS
        useNSUnarchiverFallback = try c.decodeIfPresent(Bool.self, forKey: .useNSUnarchiverFallback) ?? d.useNSUnarchiverFallback
    }

    public static func load(from url: URL) throws -> AgentConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AgentConfig.self, from: data)
    }

    public var chatDBURL: URL {
        if let p = chatDBPath, !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return AgentPaths.chatDB
    }

    /// Local prefilter (`allow_handles`), used when allowlist sync is off. Exact-match, as before.
    public func isAllowed(handle: String?, chatIdentifier: String?, chatGUID: String?) -> Bool {
        if allowHandles.isEmpty { return true }
        let set = Set(allowHandles)
        for candidate in [handle, chatIdentifier, chatGUID] {
            if let c = candidate, set.contains(c) { return true }
        }
        return false
    }
}
