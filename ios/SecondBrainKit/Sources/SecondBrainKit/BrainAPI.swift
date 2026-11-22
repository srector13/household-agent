import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum BrainError: LocalizedError, Equatable, Sendable {
    case badURL
    case unauthorized
    case server(status: Int, message: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: return "That server address doesn't look right."
        case .unauthorized: return "Wrong password for this server."
        case .server(_, let message): return message
        case .transport(let m): return m
        case .decoding(let m): return "Unexpected reply from the server (\(m)). Is the brain up to date?"
        }
    }
}

/// Where the brain lives and how to sign in. The password is the dashboard password, if one is set.
public struct ServerConfig: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var password: String?

    public init(baseURL: URL, password: String? = nil) {
        self.baseURL = baseURL
        self.password = password
    }

    /// Accepts "brain:8080", "100.64.0.1:8080", "https://brain.tail1234.ts.net" …
    public static func parse(_ text: String, password: String? = nil) -> ServerConfig? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        let pw = password?.isEmpty == false ? password : nil
        return ServerConfig(baseURL: url, password: pw)
    }
}

/// Talks to the brain's HTTP API. Every call is async and throws `BrainError`.
public final class BrainAPI: @unchecked Sendable {
    public let config: ServerConfig
    private let session: URLSession
    public static let decoder: JSONDecoder = {
        JSONDecoder()  // keys are mapped explicitly in Models.swift
    }()

    public init(config: ServerConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 20
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: c)
        }
    }

    // MARK: plumbing

    public func url(_ path: String, query: [String: String?] = [:]) throws -> URL {
        guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { throw BrainError.badURL }
        let base = comps.percentEncodedPath.hasSuffix("/") ? String(comps.percentEncodedPath.dropLast()) : comps.percentEncodedPath
        // `path` may carry its own query ("/avatars/x.jpg?v=1")
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        comps.percentEncodedPath = base + parts[0]
        var items = parts.count > 1 ? (URLComponents(string: "?" + parts[1])?.queryItems ?? []) : []
        items += query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        comps.queryItems = items.isEmpty ? nil : items
        guard let u = comps.url else { throw BrainError.badURL }
        return u
    }

    /// Encodes one path segment (event ids contain ":" and maybe "/").
    public static func seg(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil,
                        contentType: String = "application/json") throws -> URLRequest {
        var r = URLRequest(url: try url(path, query: query))
        r.httpMethod = method
        r.setValue("fetch", forHTTPHeaderField: "X-Requested-With")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let pw = config.password {
            let token = Data("app:\(pw)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    public func raw(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw BrainError.transport(Self.describe(error))
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw BrainError.unauthorized }
        guard (200..<300).contains(status) else {
            throw BrainError.server(status: status, message: Self.message(from: data) ?? "The server said \(status).")
        }
        // Action endpoints answer 200 with {"ok": false, "error": …} in a few places.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["ok"] as? Bool == false {
            throw BrainError.server(status: status, message: (obj["error"] as? String) ?? "That didn't work.")
        }
        return data
    }

    static func message(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let e = obj["error"] as? String { return e }
        if let d = obj["detail"] as? String { return d }
        if let d = obj["detail"] as? [[String: Any]], let m = d.first?["msg"] as? String { return m }
        return nil
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "You're offline."
            case NSURLErrorTimedOut: return "The brain didn't answer in time. Is Tailscale connected?"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "Can't reach the brain. Is Tailscale connected?"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: return "This address needs https://."
            default: break
            }
        }
        return error.localizedDescription
    }

    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:], as: T.Type = T.self) async throws -> T {
        try decode(try await raw(try request("GET", path, query: query)))
    }

    @discardableResult
    public func send<T: Decodable>(_ method: String, _ path: String, json: JSONValue? = nil, as: T.Type = T.self) async throws -> T {
        let body = try json.map { try JSONEncoder().encode($0) }
        return try decode(try await raw(try request(method, path, body: body ?? (method == "GET" ? nil : Data("{}".utf8)))))
    }

    public func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw BrainError.decoding("missing \(key.stringValue) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw BrainError.decoding("wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw BrainError.decoding("null at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw BrainError.decoding(String(describing: error))
        }
    }

    // MARK: screens

    public func info() async throws -> Info { try await get("/api/v1/info") }
    public func home() async throws -> Home { try await get("/api/v1/home") }
    public func today() async throws -> Today { try await get("/api/v1/today") }
    public func weekly() async throws -> Weekly { try await get("/api/v1/weekly") }
    public func people() async throws -> [Person] { try await get("/api/v1/people", as: PeopleList.self).people }
    public func person(_ key: String) async throws -> PersonDetail { try await get("/api/v1/people/" + Self.seg(key)) }
    public func items(tab: String) async throws -> ItemsPage { try await get("/api/v1/items", query: ["tab": tab]) }
    public func review() async throws -> [ReviewEntry] { try await get("/api/v1/review", as: ReviewList.self).items }
    public func activity(query: String? = nil, status: String? = nil, source: String? = nil) async throws -> Activity {
        try await get("/api/v1/activity", query: ["q": query?.isEmpty == true ? nil : query, "status": status, "source": source])
    }
    public func event(_ id: String) async throws -> EventDetail { try await get("/api/v1/events/" + Self.seg(id)) }
    public func system() async throws -> SystemStatus { try await get("/api/v1/system") }
    public func notifications(after: Int) async throws -> NotificationFeed {
        try await get("/api/v1/notifications", query: ["after": String(after)])
    }
    public func settings() async throws -> SettingsSnapshot { try await get("/api/settings") }

    @discardableResult
    public func patchSettings(_ patch: JSONValue) async throws -> SettingsSnapshot { try await send("PATCH", "/api/settings", json: patch) }

    /// Raw bytes of an image path the server gave us (e.g. "/avatars/abc.jpg?v=12").
    public func imageData(_ path: String) async throws -> Data { try await raw(try request("GET", path)) }

    // MARK: actions

    @discardableResult
    public func capture(_ text: String) async throws -> ActionReply { try await send("POST", "/api/capture", json: ["text": .string(text)]) }

    @discardableResult
    public func setDone(_ itemId: String, _ done: Bool = true) async throws -> ActionReply {
        try await send("POST", "/api/items/\(Self.seg(itemId))/done", json: ["done": .bool(done)])
    }

    public func snoozeOptions(_ itemId: String) async throws -> SnoozeOptions {
        try await get("/api/items/\(Self.seg(itemId))/snooze-options")
    }

    @discardableResult
    public func snooze(_ itemId: String, key: String) async throws -> ActionReply {
        try await send("POST", "/api/items/\(Self.seg(itemId))/snooze", json: ["key": .string(key)])
    }

    /// Reminders: `due` (YYYY-MM-DD) + optional `dueTime` (HH:MM); nil due removes the date.
    /// Events: `start` (local ISO "YYYY-MM-DDTHH:MM").
    @discardableResult
    public func reschedule(_ itemId: String, due: String?, dueTime: String? = nil, start: String? = nil) async throws -> ActionReply {
        try await send("POST", "/api/items/\(Self.seg(itemId))/reschedule",
                       json: ["due": .from(due), "due_time": .from(dueTime), "start": .from(start)])
    }

    @discardableResult
    public func delete(_ itemId: String) async throws -> ActionReply { try await send("POST", "/api/items/\(Self.seg(itemId))/delete") }

    @discardableResult
    public func restore(_ itemId: String) async throws -> ActionReply { try await send("POST", "/api/items/\(Self.seg(itemId))/restore") }

    public func breakdown(_ itemId: String) async throws -> Breakdown { try await send("POST", "/api/items/\(Self.seg(itemId))/breakdown") }

    public func focus(_ itemId: String) async throws -> FocusDetail { try await get("/api/focus/" + Self.seg(itemId)) }

    @discardableResult
    public func startTimer(_ itemId: String, minutes: Int) async throws -> ActionReply {
        try await send("POST", "/api/focus/timer", json: ["item_id": .string(itemId), "minutes": .from(minutes)])
    }

    @discardableResult
    public func stopTimer() async throws -> ActionReply { try await send("POST", "/api/focus/timer", json: ["stop": true]) }

    @discardableResult
    public func weeklyKeep(_ itemId: String) async throws -> ActionReply { try await send("POST", "/api/weekly/\(Self.seg(itemId))/keep") }

    @discardableResult
    public func weeklyFinish(_ counts: [String: Int]) async throws -> ActionReply {
        try await send("POST", "/api/weekly/finish", json: ["counts": .object(counts.mapValues { .from($0) })])
    }

    /// Tick off one of your own iCloud reminders (not made by Second Brain).
    @discardableResult
    public func externalDone(_ appleId: String) async throws -> ActionReply { try await send("POST", "/api/external/\(Self.seg(appleId))/done") }

    /// approve | reject | undo | retry on a message.
    @discardableResult
    public func eventAction(_ action: String, _ eventId: String) async throws -> ActionReply {
        try await send("POST", "/actions/\(action)/\(Self.seg(eventId))")
    }

    /// Reprocess a message with an edited extraction (JSON text).
    @discardableResult
    public func reprocess(_ eventId: String, extraction: String) async throws -> ActionReply {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "extraction=" + (extraction.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        let req = try request("POST", "/actions/reprocess/\(Self.seg(eventId))", body: Data(body.utf8),
                              contentType: "application/x-www-form-urlencoded")
        return try decode(try await raw(req))
    }

    /// repick | morning | evening | tomorrow (with item ids).
    @discardableResult
    public func todayAction(_ what: String, itemIds: [String]? = nil) async throws -> ActionReply {
        try await send("POST", "/api/today/\(what)", json: itemIds.map { ["item_ids": .array($0.map { .string($0) })] } ?? [:])
    }

    @discardableResult
    public func post(_ path: String, json: JSONValue? = nil) async throws -> ActionReply { try await send("POST", path, json: json) }
}
