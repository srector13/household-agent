import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PostEventOutcome: Equatable, Sendable {
    /// Any 2xx — the brain consumed the event (accepted / duplicate / ignored).
    case consumed(String)
    /// 422 — malformed; log and skip so we never retry forever.
    case rejected(String)
    /// 401/403 — token problem; keep buffered.
    case unauthorized
    /// 5xx / 429 / network — retry later.
    case retryLater(String)
}

public enum PostResultOutcome: Equatable, Sendable {
    case ok
    /// 404 — the brain does not know this command; drop it.
    case unknownCommand
}

public struct BrainError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public let status: Int?
    init(_ d: String, status: Int? = nil) {
        description = d
        self.status = status
    }
}

/// HTTP client for the brain. Outbound-only: POST events/results/heartbeats and long-poll commands.
public final class BrainClient: Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 120
        cfg.httpAdditionalHeaders = ["User-Agent": "household-mac-agent/\(AgentInfo.version)"]
        session = URLSession(configuration: cfg)
    }

    private func request(_ path: String, method: String, query: [URLQueryItem] = [], body: Data? = nil,
                         timeout: TimeInterval = 20) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// Portable async wrapper (URLSession's async API is not available everywhere on Linux).
    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, Int), Error>) in
            let task = session.dataTask(with: req) { data, response, error in
                if let error {
                    c.resume(throwing: error)
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                c.resume(returning: (data ?? Data(), status))
            }
            task.resume()
        }
    }

    private static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(300), as: UTF8.self)
    }

    public func postEvent(_ event: InboundEvent) async -> PostEventOutcome {
        let body: Data
        do { body = try Wire.encoder().encode(event) } catch { return .rejected("encode: \(error)") }
        do {
            let (data, status) = try await send(request("api/events", method: "POST", body: body))
            switch status {
            case 200..<300:
                let ack = try? Wire.decoder().decode(EventAck.self, from: data)
                return .consumed(ack?.status ?? "ok")
            case 401, 403:
                return .unauthorized
            case 400, 404, 409, 413, 415, 422:
                return .rejected("HTTP \(status): \(Self.snippet(data))")
            default:
                return .retryLater("HTTP \(status): \(Self.snippet(data))")
            }
        } catch {
            return .retryLater(String(describing: error))
        }
    }

    /// GET /api/agent/commands?wait=N. Returns [] on timeout.
    public func fetchCommands(wait: Int) async throws -> [AgentCommand] {
        let w = max(0, min(wait, 55))
        let req = request("api/agent/commands", method: "GET",
                          query: [URLQueryItem(name: "wait", value: String(w))],
                          timeout: TimeInterval(w) + 20)
        let (data, status) = try await send(req)
        guard (200..<300).contains(status) else {
            throw BrainError("commands: HTTP \(status): \(Self.snippet(data))", status: status)
        }
        return try Wire.decoder().decode(CommandBatch.self, from: data).commands
    }

    public func postResult(commandId: String, result: CommandResult) async throws -> PostResultOutcome {
        let escaped = commandId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? commandId
        let body = try Wire.encoder().encode(result)
        let (data, status) = try await send(request("api/agent/commands/\(escaped)/result", method: "POST", body: body))
        switch status {
        case 200..<300: return .ok
        case 404: return .unknownCommand
        default: throw BrainError("result: HTTP \(status): \(Self.snippet(data))", status: status)
        }
    }

    /// POST /api/agent/heartbeat. Returns the brain's settings_version, if it reports one.
    @discardableResult
    public func heartbeat(_ hb: Heartbeat) async throws -> HeartbeatAck {
        let body = try Wire.encoder().encode(hb)
        let (data, status) = try await send(request("api/agent/heartbeat", method: "POST", body: body))
        guard (200..<300).contains(status) else {
            throw BrainError("heartbeat: HTTP \(status): \(Self.snippet(data))", status: status)
        }
        return (try? Wire.decoder().decode(HeartbeatAck.self, from: data)) ?? HeartbeatAck(ok: true, settingsVersion: nil)
    }

    /// GET /api/agent/tracked — items the brain wants status for. Throws BrainError(status: 404) on a
    /// brain that predates completion sync.
    public func fetchTracked() async throws -> TrackedList {
        let (data, status) = try await send(request("api/agent/tracked", method: "GET"))
        guard (200..<300).contains(status) else {
            throw BrainError("tracked: HTTP \(status): \(Self.snippet(data))", status: status)
        }
        return try Wire.decoder().decode(TrackedList.self, from: data)
    }

    /// POST /api/agent/item-status.
    @discardableResult
    public func postItemStatus(_ items: [ItemStatusReport]) async throws -> ItemStatusAck {
        let body = try Wire.encoder().encode(ItemStatusBatch(items: items))
        let (data, status) = try await send(request("api/agent/item-status", method: "POST", body: body, timeout: 30))
        guard (200..<300).contains(status) else {
            throw BrainError("item-status: HTTP \(status): \(Self.snippet(data))", status: status)
        }
        return (try? Wire.decoder().decode(ItemStatusAck.self, from: data)) ?? ItemStatusAck(ok: true, updated: nil)
    }

    /// GET /api/agent/config — the brain-managed allowlist. Throws BrainError(status: 404) on a
    /// brain that predates the endpoint.
    public func fetchAgentConfig() async throws -> RemoteAgentConfig {
        let (data, status) = try await send(request("api/agent/config", method: "GET"))
        guard (200..<300).contains(status) else {
            throw BrainError("config: HTTP \(status): \(Self.snippet(data))", status: status)
        }
        return try Wire.decoder().decode(RemoteAgentConfig.self, from: data)
    }
}
