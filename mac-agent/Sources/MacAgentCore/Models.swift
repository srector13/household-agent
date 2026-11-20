import Foundation

// Wire types for the brain ↔ mac-agent contract (docs/API.md).
// JSON uses snake_case; encoders/decoders below convert automatically.

public enum Wire {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// POST /api/events body.
public struct InboundEvent: Codable, Equatable, Sendable {
    public var eventId: String
    public var source: String
    public var senderHandle: String
    public var senderLabel: String?
    public var chatId: String?
    public var isFromMe: Bool
    public var receivedAt: String
    public var text: String
    public var recentContext: [String]

    public init(eventId: String, source: String = "imessage", senderHandle: String, senderLabel: String?,
                chatId: String?, isFromMe: Bool, receivedAt: String, text: String, recentContext: [String]) {
        self.eventId = eventId
        self.source = source
        self.senderHandle = senderHandle
        self.senderLabel = senderLabel
        self.chatId = chatId
        self.isFromMe = isFromMe
        self.receivedAt = receivedAt
        self.text = text
        self.recentContext = recentContext
    }
}

/// POST /api/events response.
public struct EventAck: Codable, Sendable {
    public var status: String
    public var eventId: String?
}

public enum ItemKind: String, Codable, Sendable {
    case reminder
    case event
}

public struct ReminderPayload: Codable, Equatable, Sendable {
    public var title: String
    public var list: String?
    public var createListIfMissing: Bool?
    /// YYYY-MM-DD
    public var due: String?
    /// HH:MM local
    public var dueTime: String?
    /// ISO-8601 with offset
    public var alert: String?
    public var notes: String?
    public var tag: String?

    public init(title: String, list: String? = nil, createListIfMissing: Bool? = true, due: String? = nil,
                dueTime: String? = nil, alert: String? = nil, notes: String? = nil, tag: String? = nil) {
        self.title = title
        self.list = list
        self.createListIfMissing = createListIfMissing
        self.due = due
        self.dueTime = dueTime
        self.alert = alert
        self.notes = notes
        self.tag = tag
    }
}

public struct EventPayload: Codable, Equatable, Sendable {
    public var title: String
    public var calendar: String?
    public var start: String
    public var end: String?
    public var allDay: Bool?
    public var location: String?
    public var alertMinutesBefore: Int?
    public var notes: String?
    public var tag: String?

    public init(title: String, calendar: String? = nil, start: String, end: String? = nil, allDay: Bool? = false,
                location: String? = nil, alertMinutesBefore: Int? = nil, notes: String? = nil, tag: String? = nil) {
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.alertMinutesBefore = alertMinutesBefore
        self.notes = notes
        self.tag = tag
    }
}

public struct DeletePayload: Codable, Equatable, Sendable {
    public var appleItemId: String
    public var kind: ItemKind?

    public init(appleItemId: String, kind: ItemKind?) {
        self.appleItemId = appleItemId
        self.kind = kind
    }
}

public enum CommandPayload: Equatable, Sendable {
    case createReminder(ReminderPayload)
    case createEvent(EventPayload)
    case deleteItem(DeletePayload)
    /// Unknown op or a payload that failed to decode; reported back as `failed`.
    case unsupported(op: String, reason: String)
}

/// One command from GET /api/agent/commands.
public struct AgentCommand: Decodable, Equatable, Sendable {
    public var commandId: String
    public var eventId: String?
    public var op: String
    public var payload: CommandPayload

    enum CodingKeys: String, CodingKey {
        case commandId, eventId, op, payload
    }

    public init(commandId: String, eventId: String?, op: String, payload: CommandPayload) {
        self.commandId = commandId
        self.eventId = eventId
        self.op = op
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commandId = try c.decode(String.self, forKey: .commandId)
        eventId = try c.decodeIfPresent(String.self, forKey: .eventId)
        op = try c.decode(String.self, forKey: .op)
        do {
            switch op {
            case "create_reminder":
                payload = .createReminder(try c.decode(ReminderPayload.self, forKey: .payload))
            case "create_event":
                payload = .createEvent(try c.decode(EventPayload.self, forKey: .payload))
            case "delete_item":
                payload = .deleteItem(try c.decode(DeletePayload.self, forKey: .payload))
            default:
                payload = .unsupported(op: op, reason: "unsupported op '\(op)'")
            }
        } catch {
            payload = .unsupported(op: op, reason: "invalid payload: \(error)")
        }
    }
}

public struct CommandBatch: Decodable, Sendable {
    public var commands: [AgentCommand]
}

/// POST /api/agent/commands/{id}/result body.
public struct CommandResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case done
        case failed
    }

    public var status: Status
    public var appleItemId: String?
    public var error: String?

    public init(status: Status, appleItemId: String? = nil, error: String? = nil) {
        self.status = status
        self.appleItemId = appleItemId
        self.error = error
    }

    public static func done(_ id: String?) -> CommandResult { CommandResult(status: .done, appleItemId: id) }
    public static func failed(_ message: String) -> CommandResult { CommandResult(status: .failed, error: message) }

    // Always emit every key (including nulls) so the brain sees an explicit `apple_item_id: null`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(appleItemId, forKey: .appleItemId)
        try c.encode(error, forKey: .error)
    }

    enum CodingKeys: String, CodingKey { case status, appleItemId, error }
}

/// POST /api/agent/heartbeat body.
public struct Heartbeat: Codable, Equatable, Sendable {
    public var agentVersion: String
    public var lastRowid: Int64
    public var fdaOk: Bool
    public var remindersOk: Bool
    public var calendarOk: Bool
    public var uptimeS: Int
    public var bufferedEvents: Int
    /// settings_version of the synced allowlist (null when never synced or sync is off).
    public var allowlistVersion: Int?
    /// Number of handles + chat ids in the active prefilter.
    public var allowlistSize: Int

    public init(agentVersion: String = AgentInfo.version, lastRowid: Int64, fdaOk: Bool, remindersOk: Bool,
                calendarOk: Bool, uptimeS: Int, bufferedEvents: Int, allowlistVersion: Int? = nil,
                allowlistSize: Int = 0) {
        self.agentVersion = agentVersion
        self.lastRowid = lastRowid
        self.fdaOk = fdaOk
        self.remindersOk = remindersOk
        self.calendarOk = calendarOk
        self.uptimeS = uptimeS
        self.bufferedEvents = bufferedEvents
        self.allowlistVersion = allowlistVersion
        self.allowlistSize = allowlistSize
    }

    enum CodingKeys: String, CodingKey {
        case agentVersion, lastRowid, fdaOk, remindersOk, calendarOk, uptimeS, bufferedEvents
        case allowlistVersion, allowlistSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentVersion = try c.decode(String.self, forKey: .agentVersion)
        lastRowid = try c.decode(Int64.self, forKey: .lastRowid)
        fdaOk = try c.decode(Bool.self, forKey: .fdaOk)
        remindersOk = try c.decode(Bool.self, forKey: .remindersOk)
        calendarOk = try c.decode(Bool.self, forKey: .calendarOk)
        uptimeS = try c.decode(Int.self, forKey: .uptimeS)
        bufferedEvents = try c.decode(Int.self, forKey: .bufferedEvents)
        allowlistVersion = try c.decodeIfPresent(Int.self, forKey: .allowlistVersion)
        allowlistSize = try c.decodeIfPresent(Int.self, forKey: .allowlistSize) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentVersion, forKey: .agentVersion)
        try c.encode(lastRowid, forKey: .lastRowid)
        try c.encode(fdaOk, forKey: .fdaOk)
        try c.encode(remindersOk, forKey: .remindersOk)
        try c.encode(calendarOk, forKey: .calendarOk)
        try c.encode(uptimeS, forKey: .uptimeS)
        try c.encode(bufferedEvents, forKey: .bufferedEvents)
        try c.encode(allowlistVersion, forKey: .allowlistVersion)  // explicit null when unsynced
        try c.encode(allowlistSize, forKey: .allowlistSize)
    }
}
