import Foundation

// Shapes of the brain's /api/v1 responses (see brain/app/api_v1.py). Every struct maps its snake_case
// keys explicitly: a key strategy would also rewrite dictionary keys ("needs_review") on some platforms.
// Dates stay strings; use `BrainDate` to read them.

// MARK: - Shared

/// A reminder, event or saved note that Second Brain made.
public struct Item: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: String              // reminder | event
    public var category: String?         // todo | event | collection | promise | waiting
    public var collection: String?
    public var collectionLabel: String?
    public var person: String?
    public var status: String            // proposed | planned | active | completed | cancelled | …
    public var due: String?
    public var dueTime: String?
    public var start: String?
    public var end: String?
    public var allDay: Bool
    public var location: String?
    public var list: String?
    public var section: String?
    public var tags: [String]
    public var url: String?
    public var firstStep: String?
    public var steps: [String]
    public var notes: String?
    public var originEventId: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var completedAt: String?
    public var origin: Origin?
    public var log: [LogEntry]?
    public var why: String?              // candidates only

    public struct Origin: Codable, Hashable, Sendable {
        public var text: String
        public var sender: String?
        public var fromMe: Bool
        public var at: String?

        enum CodingKeys: String, CodingKey {
            case text, sender, fromMe = "from_me", at
        }
    }

    public struct LogEntry: Codable, Hashable, Sendable {
        public var action: String
        public var at: String
        public var eventId: String?
        public var detail: String?

        enum CodingKeys: String, CodingKey {
            case action, at, eventId = "event_id", detail
        }
    }

    public var isOpen: Bool { status == "planned" || status == "active" || status == "proposed" }
    public var isReminder: Bool { kind != "event" }
    public var isDone: Bool { status == "completed" }
    public var isGone: Bool { ["cancelled", "undone", "rejected", "deleted", "failed"].contains(status) }

    public init(id: String, title: String, kind: String = "reminder", category: String? = "todo", collection: String? = nil,
                collectionLabel: String? = nil, person: String? = nil, status: String = "active", due: String? = nil,
                dueTime: String? = nil, start: String? = nil, end: String? = nil, allDay: Bool = false,
                location: String? = nil, list: String? = nil, section: String? = nil, tags: [String] = [],
                url: String? = nil, firstStep: String? = nil, steps: [String] = [], notes: String? = nil,
                originEventId: String? = nil, createdAt: String? = nil, updatedAt: String? = nil,
                completedAt: String? = nil, origin: Origin? = nil, log: [LogEntry]? = nil, why: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.category = category; self.collection = collection
        self.collectionLabel = collectionLabel; self.person = person; self.status = status; self.due = due
        self.dueTime = dueTime; self.start = start; self.end = end; self.allDay = allDay; self.location = location
        self.list = list; self.section = section; self.tags = tags; self.url = url; self.firstStep = firstStep
        self.steps = steps; self.notes = notes; self.originEventId = originEventId; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.completedAt = completedAt; self.origin = origin; self.log = log; self.why = why
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, category, collection, collectionLabel = "collection_label", person
        case status, due, dueTime = "due_time", start, end, allDay = "all_day", location, list, section
        case tags, url, firstStep = "first_step", steps, notes, originEventId = "origin_event_id"
        case createdAt = "created_at", updatedAt = "updated_at", completedAt = "completed_at", origin
        case log, why
    }
}

/// One message (iMessage, mail, quick capture) and what happened to it.
public struct Message: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var source: String
    public var sender: String?
    public var senderHandle: String?
    public var fromMe: Bool
    public var text: String
    public var subject: String?
    public var receivedAt: String
    public var status: String
    public var statusLabel: String
    public var reason: String?
    public var confidence: Double?
    public var actions: [ActionSummary]
    public var photo: String?

    public struct ActionSummary: Codable, Hashable, Sendable {
        public var type: String?
        public var title: String
    }

    enum CodingKeys: String, CodingKey {
        case id, source, sender, senderHandle = "sender_handle", fromMe = "from_me", text, subject
        case receivedAt = "received_at", status, statusLabel = "status_label", reason, confidence
        case actions, photo
    }
}

/// Something dated: ours, or one of your own iCloud events / reminders (`external`).
public struct AgendaEntry: Codable, Hashable, Identifiable, Sendable {
    public var title: String
    public var when: String
    public var allDay: Bool
    public var kind: String
    public var `where`: String?
    public var who: String?
    public var location: String?
    public var itemId: String?
    public var eventId: String?
    public var external: Bool
    public var appleId: String?
    public var color: String?
    public var late: Bool

    public var id: String { [itemId, appleId, title, when].compactMap { $0 }.joined(separator: "|") }

    enum CodingKeys: String, CodingKey {
        case title, when, allDay = "all_day", kind, `where`, who, location, itemId = "item_id"
        case eventId = "event_id", external, appleId = "apple_id", color, late
    }
}

public struct Pick: Codable, Hashable, Identifiable, Sendable {
    public var itemId: String
    public var title: String
    public var why: String?
    public var firstStep: String?
    public var status: String
    public var kind: String
    public var category: String?
    public var snoozedTo: String?

    public var id: String { itemId }
    public var isDone: Bool { status == "completed" }
    public var isGone: Bool { !["planned", "active", "completed"].contains(status) || snoozedTo != nil }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", title, why, firstStep = "first_step", status, kind, category
        case snoozedTo = "snoozed_to"
    }
}

// MARK: - Screens

public struct Info: Codable, Hashable, Sendable {
    public var appName: String
    public var version: String
    public var timezone: String
    public var now: String
    public var badge: Int
    public var reviewCount: Int
    public var agentOnline: Bool
    public var llmOk: Bool
    public var publicUrl: String?
    public var morningTime: String
    public var eveningTime: String

    enum CodingKeys: String, CodingKey {
        case appName = "app_name", version, timezone, now, badge, reviewCount = "review_count"
        case agentOnline = "agent_online", llmOk = "llm_ok", publicUrl = "public_url"
        case morningTime = "morning_time", eveningTime = "evening_time"
    }
}

public struct Home: Codable, Hashable, Sendable {
    public var greeting: String
    public var now: String
    public var doneToday: Int
    public var problems: [String]
    public var next: NextUp?
    public var picks: [Pick]
    public var picksLeft: Int
    public var beforeMorning: Bool
    public var evening: Bool
    public var morningTime: String
    public var attention: Attention
    public var agenda: [AgendaEntry]
    public var recent: [Recent]
    public var weeklyCount: Int

    public struct NextUp: Codable, Hashable, Sendable {
        public var kind: String
        public var title: String
        public var at: String
        public var end: String?
        public var ongoing: Bool
        public var inLabel: String
        public var `where`: String?
        public var eventId: String?
        public var itemId: String?
        public var color: String?

        enum CodingKeys: String, CodingKey {
            case kind, title, at, end, ongoing, `where`, color
            case eventId = "event_id", itemId = "item_id", inLabel = "in"
        }
    }

    public struct Attention: Codable, Hashable, Sendable {
        public var reviews: [ReviewSummary]
        public var followups: [Item]
        public var late: [Item]
        public var failed: Int
        public var count: Int
    }

    public struct ReviewSummary: Codable, Hashable, Identifiable, Sendable {
        public var event: Message
        public var titles: [String]
        public var id: String { event.id }
    }

    public struct Recent: Codable, Hashable, Identifiable, Sendable {
        public var verb: String
        public var title: String
        public var person: String?
        public var kind: String
        public var category: String?
        public var collection: String?
        public var at: String
        public var via: String?
        public var eventId: String?
        public var id: String { "\(verb)|\(title)|\(at)" }

        enum CodingKeys: String, CodingKey {
            case verb, title, person, kind, category, collection, at, via, eventId = "event_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case greeting, now, doneToday = "done_today", problems, next, picks, picksLeft = "picks_left"
        case beforeMorning = "before_morning", evening, morningTime = "morning_time", attention, agenda
        case recent, weeklyCount = "weekly_count"
    }
}

public struct Today: Codable, Hashable, Sendable {
    public var date: String
    public var summary: String?
    public var picks: [Pick]
    public var done: [Item]
    public var events: [DayEvent]
    public var candidates: [Item]
    public var tomorrowChosen: [String]
    public var tomorrowLocked: Bool
    public var morningTime: String
    public var eveningTime: String
    public var eveningDone: Bool

    public struct DayEvent: Codable, Hashable, Identifiable, Sendable {
        public var title: String?
        public var start: String?
        public var end: String?
        public var allDay: Bool
        public var `where`: String?
        public var external: Bool
        public var id: String { "\(title ?? "")|\(start ?? "")" }

        enum CodingKeys: String, CodingKey {
            case title, start, end, allDay = "all_day", `where`, external
        }
    }

    enum CodingKeys: String, CodingKey {
        case date, summary, picks, done, events, candidates, tomorrowChosen = "tomorrow_chosen"
        case tomorrowLocked = "tomorrow_locked", morningTime = "morning_time"
        case eveningTime = "evening_time", eveningDone = "evening_done"
    }
}

public struct WeeklyCard: Codable, Hashable, Identifiable, Sendable {
    public var itemId: String
    public var title: String
    public var kind: String
    public var category: String?
    public var person: String?
    public var why: String
    public var rank: Int
    public var due: String?
    public var age: Int
    public var quote: String?
    public var fromMe: Bool
    public var id: String { itemId }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", title, kind, category, person, why, rank, due, age, quote
        case fromMe = "from_me"
    }
}

public struct Weekly: Codable, Hashable, Sendable {
    public var cards: [WeeklyCard]
    public var last: Last?
    public var due: Bool

    public struct Last: Codable, Hashable, Sendable {
        public var at: String
        public var counts: [String: Int]
    }
}

public struct Person: Codable, Hashable, Identifiable, Sendable {
    public var key: String
    public var label: String
    public var handle: String?
    public var group: Bool
    public var photo: String?
    public var contactName: String?
    public var mentioned: Bool
    public var last: String?
    public var promises: Int
    public var waiting: Int
    public var gifts: Int
    public var facts: Int
    public var todos: Int
    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, handle, group, photo, contactName = "contact_name", mentioned, last, promises
        case waiting, gifts, facts, todos
    }
}

public struct PeopleList: Codable, Hashable, Sendable {
    public var people: [Person]
}

public struct PersonDetail: Codable, Hashable, Sendable {
    public var person: Person
    public var promises: [Item]
    public var waiting: [Item]
    public var todos: [Item]
    public var gifts: [Item]
    public var facts: [Item]
    public var other: [Item]
    public var done: [Item]
    public var messages: [ChatMessage]

    public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
        public var eventId: String
        public var text: String
        public var fromMe: Bool
        public var at: String
        public var status: String
        public var id: String { eventId }

        enum CodingKeys: String, CodingKey {
            case eventId = "event_id", text, fromMe = "from_me", at, status
        }
    }
}

public struct ItemsPage: Codable, Hashable, Sendable {
    public var tab: String
    public var counts: [String: Int]
    public var items: [Item]
    public var groups: [Group]
    public var upcoming: [AgendaEntry]

    public struct Group: Codable, Hashable, Identifiable, Sendable {
        public var key: String
        public var label: String?
        public var people: [PersonItems]
        public var id: String { key }
    }

    public struct PersonItems: Codable, Hashable, Identifiable, Sendable {
        public var person: String
        public var items: [Item]
        public var id: String { person }
    }
}

public struct Proposal: Codable, Hashable, Identifiable, Sendable {
    public var commandId: String
    public var op: String
    public var title: String
    public var due: String?
    public var dueTime: String?
    public var start: String?
    public var allDay: Bool
    public var list: String?
    public var collection: String?
    public var person: String?
    public var summary: String?
    public var id: String { commandId }

    enum CodingKeys: String, CodingKey {
        case commandId = "command_id", op, title, due, dueTime = "due_time", start, allDay = "all_day"
        case list, collection, person, summary
    }
}

public struct ReviewEntry: Codable, Hashable, Identifiable, Sendable {
    public var event: Message
    public var proposals: [Proposal]
    public var reasons: [String]
    public var id: String { event.id }
}

public struct ReviewList: Codable, Hashable, Sendable {
    public var items: [ReviewEntry]
}

public struct Activity: Codable, Hashable, Sendable {
    public var events: [Message]
    public var counts: [String: Int]
    public var statuses: [StatusOption]

    public struct StatusOption: Codable, Hashable, Identifiable, Sendable {
        public var key: String
        public var label: String
        public var id: String { key }
    }
}

public struct EventDetail: Codable, Hashable, Sendable {
    public var event: Message
    public var context: [String]
    public var can: Can
    public var trace: [TraceStep]
    public var commands: [Command]
    public var items: [Item]
    public var proposals: [Proposal]
    public var reasons: [String]
    public var reasoning: String?
    public var promptVersion: String?
    public var extraction: String
    public var lastError: String?

    public struct Can: Codable, Hashable, Sendable {
        public var approve: Bool
        public var reject: Bool
        public var undo: Bool
        public var retry: Bool
    }

    public struct TraceStep: Codable, Hashable, Identifiable, Sendable {
        public var step: String
        public var label: String
        public var summary: String?
        public var durationMs: Int?
        public var at: String
        public var id: String { "\(step)|\(at)" }

        enum CodingKeys: String, CodingKey {
            case step, label, summary, durationMs = "duration_ms", at
        }
    }

    public struct Command: Codable, Hashable, Identifiable, Sendable {
        public var commandId: String
        public var op: String
        public var status: String
        public var purpose: String?
        public var title: String?
        public var error: String?
        public var undo: Bool
        public var generation: Int
        public var itemId: String?
        public var id: String { commandId }

        enum CodingKeys: String, CodingKey {
            case commandId = "command_id", op, status, purpose, title, error, undo, generation
            case itemId = "item_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case event, context, can, trace, commands, items, proposals, reasons, reasoning
        case promptVersion = "prompt_version", extraction, lastError = "last_error"
    }
}

public struct SystemStatus: Codable, Hashable, Sendable {
    public var version: String
    public var health: Health
    public var today: [String: Int]
    public var review: Int
    public var failed24h: Int
    public var funnel: [String: Int]
    public var latency: Latency
    public var daily: [Day]
    public var alerts: [Alert]
    public var commands: [OpenCommand]
    public var lastBackup: JSONValue?
    public var db: DBInfo
    public var settingsVersion: Int
    public var pushDevices: Int

    public struct Health: Codable, Hashable, Sendable {
        public var agent: [String: JSONValue]
        public var llm: LLM
        public var mail: [String: JSONValue]?
        public var queueDepth: Int
        public var brainUptimeS: Int

        public var agentOnline: Bool { agent["online"]?.bool ?? false }
        public var agentVersion: String? { agent["agent_version"]?.string }
        public func agentFlag(_ key: String) -> Bool? { agent[key]?.bool }

        enum CodingKeys: String, CodingKey {
            case agent, llm, mail, queueDepth = "queue_depth", brainUptimeS = "brain_uptime_s"
        }
    }

    public struct LLM: Codable, Hashable, Sendable {
        public var baseUrl: String
        public var model: String
        public var reachable: Bool
        public var latencyMs: Int?
        public var failStreak: Int
        public var lastError: String?

        enum CodingKeys: String, CodingKey {
            case baseUrl = "base_url", model, reachable, latencyMs = "latency_ms"
            case failStreak = "fail_streak", lastError = "last_error"
        }
    }

    public struct Latency: Codable, Hashable, Sendable {
        public var avg: Int?
        public var p50: Int?
        public var p90: Int?
        public var n: Int?
    }

    public struct Day: Codable, Hashable, Identifiable, Sendable {
        public var date: String
        public var messages: Int
        public var actionable: Int
        public var created: Int
        public var id: String { date }
    }

    public struct Alert: Codable, Hashable, Identifiable, Sendable {
        public var kind: String
        public var message: String
        public var delivered: Int
        public var createdAt: String
        public var id: String { "\(kind)|\(createdAt)|\(message.prefix(20))" }

        enum CodingKeys: String, CodingKey {
            case kind, message, delivered, createdAt = "created_at"
        }
    }

    public struct OpenCommand: Codable, Hashable, Identifiable, Sendable {
        public var commandId: String
        public var op: String
        public var status: String
        public var title: String?
        public var sender: String?
        public var createdAt: String
        public var id: String { commandId }

        enum CodingKeys: String, CodingKey {
            case commandId = "command_id", op, status, title, sender, createdAt = "created_at"
        }
    }

    public struct DBInfo: Codable, Hashable, Sendable {
        public var sizeBytes: Int?
        public var counts: [String: Int]?

        enum CodingKeys: String, CodingKey {
            case sizeBytes = "size_bytes", counts
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, health, today, review, failed24h = "failed_24h", funnel, latency, daily, alerts
        case commands, lastBackup = "last_backup", db, settingsVersion = "settings_version"
        case pushDevices = "push_devices"
    }
}

public struct NotificationFeed: Codable, Hashable, Sendable {
    public var items: [Entry]
    public var lastId: Int
    public var badge: Int

    public struct Entry: Codable, Hashable, Identifiable, Sendable {
        public var id: Int
        public var kind: String
        public var title: String?
        public var body: String?
        public var url: String?
        public var at: String
    }

    enum CodingKeys: String, CodingKey {
        case items, lastId = "last_id", badge
    }
}

/// /api/settings: every editable setting by dotted path ("daily.morning_time"), secrets masked.
public struct SettingsSnapshot: Codable, Hashable, Sendable {
    public var values: [String: JSONValue]
    public var sources: [String: String]
    public var version: Int
}

// MARK: - Actions

public struct SnoozeOptions: Codable, Hashable, Sendable {
    public var kind: String
    public var title: String
    public var options: [Option]
    public var due: String?
    public var dueTime: String?
    public var start: String?

    public struct Option: Codable, Hashable, Identifiable, Sendable {
        public var key: String
        public var label: String
        public var sub: String
        public var due: String
        public var dueTime: String
        public var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, label, sub, due, dueTime = "due_time"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, options, due, dueTime = "due_time", start
    }
}

public struct FocusDetail: Codable, Hashable, Sendable {
    public var itemId: String
    public var title: String
    public var kind: String
    public var status: String
    public var category: String?
    public var person: String?
    public var firstStep: String?
    public var steps: [String]
    public var context: String?
    public var due: String?
    public var url: String?
    public var timer: FocusTimer?
    public var next: NextSuggestion?

    public struct NextSuggestion: Codable, Hashable, Sendable {
        public var itemId: String
        public var title: String
        public var why: String

        enum CodingKeys: String, CodingKey {
            case itemId = "item_id", title, why
        }
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", title, kind, status, category, person, firstStep = "first_step", steps
        case context, due, url, timer, next
    }
}

public struct FocusTimer: Codable, Hashable, Sendable {
    public var itemId: String
    public var title: String
    public var minutes: Int
    public var endsAt: String
    public var startedAt: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id", title, minutes, endsAt = "ends_at", startedAt = "started_at"
    }
}

public struct Breakdown: Codable, Hashable, Sendable {
    public var firstStep: String
    public var steps: [String]

    enum CodingKeys: String, CodingKey {
        case firstStep = "first_step", steps
    }
}

/// Generic reply of the action endpoints: {"ok": true, ...}. Extra fields are kept loosely.
public struct ActionReply: Codable, Hashable, Sendable {
    public var ok: Bool?
    public var error: String?
    public var status: String?
    public var label: String?
    public var due: String?
    public var dueTime: String?
    public var timer: FocusTimer?
    public var result: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, status, label, due, dueTime = "due_time", timer, result
    }
}
