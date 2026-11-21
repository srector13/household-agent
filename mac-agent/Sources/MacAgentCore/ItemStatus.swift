import Foundation

// Completion sync: the brain asks which of "its" items still exist / were ticked off / were edited
// on the iPhone, so its registry matches what is really in Reminders and Calendar.
//
//   GET  /api/agent/tracked      → TrackedList
//   POST /api/agent/item-status  ← {"items": [ItemStatusReport]}

/// One item the brain wants status for.
public struct TrackedItem: Codable, Equatable, Sendable {
    public var appleItemId: String
    public var kind: ItemKind
    public var tag: String?

    public init(appleItemId: String, kind: ItemKind, tag: String? = nil) {
        self.appleItemId = appleItemId
        self.kind = kind
        self.tag = tag
    }
}

/// Response of GET /api/agent/tracked.
public struct TrackedList: Codable, Equatable, Sendable {
    public var items: [TrackedItem]
    public var intervalS: Int?

    public init(items: [TrackedItem], intervalS: Int? = nil) {
        self.items = items
        self.intervalS = intervalS
    }
}

/// What the store knows about an item it found. Strings are already in wire format
/// (due "YYYY-MM-DD", due_time "HH:MM", start/end/completed_at ISO-8601 with offset).
public struct ItemSnapshot: Equatable, Sendable {
    public var completed: Bool?
    public var completedAt: String?
    public var title: String?
    public var due: String?
    public var dueTime: String?
    public var start: String?
    public var end: String?

    public init(completed: Bool? = nil, completedAt: String? = nil, title: String? = nil, due: String? = nil,
                dueTime: String? = nil, start: String? = nil, end: String? = nil) {
        self.completed = completed
        self.completedAt = completedAt
        self.title = title
        self.due = due
        self.dueTime = dueTime
        self.start = start
        self.end = end
    }
}

/// Result of looking an item up by identifier.
public enum ItemLookup: Equatable, Sendable {
    case found(ItemSnapshot)
    /// Definitely not there: the store is loaded and has full access for this kind.
    case notFound
    /// Can't tell (no permission, store error, wrong kind…). Never reported to the brain.
    case unknown(String)
}

/// One entry of POST /api/agent/item-status. Optional fields are encoded as explicit nulls.
public struct ItemStatusReport: Codable, Equatable, Sendable {
    public var appleItemId: String
    public var kind: ItemKind
    public var exists: Bool
    public var completed: Bool?
    public var completedAt: String?
    public var title: String?
    public var due: String?
    public var dueTime: String?
    public var start: String?
    public var end: String?
    /// Set when the item was found by its [ha:] tag under a different identifier.
    public var foundId: String?

    public init(appleItemId: String, kind: ItemKind, exists: Bool, snapshot: ItemSnapshot? = nil,
                foundId: String? = nil) {
        self.appleItemId = appleItemId
        self.kind = kind
        self.exists = exists
        self.completed = kind == .reminder ? snapshot?.completed : nil
        self.completedAt = kind == .reminder ? snapshot?.completedAt : nil
        self.title = snapshot?.title
        self.due = kind == .reminder ? snapshot?.due : nil
        self.dueTime = kind == .reminder ? snapshot?.dueTime : nil
        self.start = kind == .event ? snapshot?.start : nil
        self.end = kind == .event ? snapshot?.end : nil
        self.foundId = foundId
    }

    enum CodingKeys: String, CodingKey {
        case appleItemId, kind, exists, completed, completedAt, title, due, dueTime, start, end, foundId
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appleItemId, forKey: .appleItemId)
        try c.encode(kind, forKey: .kind)
        try c.encode(exists, forKey: .exists)
        try c.encode(completed, forKey: .completed)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encode(title, forKey: .title)
        try c.encode(due, forKey: .due)
        try c.encode(dueTime, forKey: .dueTime)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(foundId, forKey: .foundId)
    }
}

struct ItemStatusBatch: Codable, Sendable {
    var items: [ItemStatusReport]
}

public struct ItemStatusAck: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var updated: Int?
}

/// Builds status reports from an ItemStore. Errs on the side of silence: an item is only
/// reported missing when the store could definitely have seen it.
public struct ItemStatusChecker: Sendable {
    public let store: ItemStore

    public init(store: ItemStore) { self.store = store }

    public func reports(for tracked: [TrackedItem]) async -> [ItemStatusReport] {
        let perms = await store.permissionFlags()
        var out: [ItemStatusReport] = []
        for t in tracked where !t.appleItemId.isEmpty {
            let permitted = t.kind == .reminder ? perms.reminders : perms.calendar
            guard permitted else { continue }
            switch await store.itemStatus(id: t.appleItemId, kind: t.kind) {
            case .found(let snap):
                out.append(ItemStatusReport(appleItemId: t.appleItemId, kind: t.kind, exists: true, snapshot: snap))
            case .unknown:
                continue
            case .notFound:
                guard let tag = t.tag, !tag.isEmpty else {
                    out.append(ItemStatusReport(appleItemId: t.appleItemId, kind: t.kind, exists: false))
                    continue
                }
                let found: String?
                do {
                    found = try await store.findItem(taggedWith: tag, kind: t.kind, around: nil)
                } catch {
                    continue  // search failed — can't tell
                }
                guard let found else {
                    out.append(ItemStatusReport(appleItemId: t.appleItemId, kind: t.kind, exists: false))
                    continue
                }
                if case .found(let snap) = await store.itemStatus(id: found, kind: t.kind) {
                    out.append(ItemStatusReport(appleItemId: t.appleItemId, kind: t.kind, exists: true,
                                                snapshot: snap, foundId: found))
                }
                // Found by tag but unreadable by id: inconsistent, stay silent.
            }
        }
        return out
    }
}

/// When the next status sync is due. Pure value type so the timing rules can be unit tested.
public struct StatusSyncSchedule: Sendable {
    public static let initialDelay: TimeInterval = 30
    public static let debounce: TimeInterval = 5
    /// A stream of commands can't postpone the sync forever.
    public static let maxCommandDelay: TimeInterval = 30
    public static let defaultInterval = 300

    public private(set) var interval: TimeInterval = TimeInterval(defaultInterval)
    public private(set) var disabled = false
    private var nextPeriodic: Date
    private var commandDue: Date?
    private var firstPendingCommand: Date?

    public init(start: Date = Date()) {
        nextPeriodic = start.addingTimeInterval(Self.initialDelay)
    }

    public static func clamp(_ seconds: Int?) -> Int {
        min(max(seconds ?? defaultInterval, 60), 3600)
    }

    public mutating func setInterval(_ seconds: Int?) {
        interval = TimeInterval(Self.clamp(seconds))
    }

    /// A command was executed: sync `debounce` seconds after the last one of a burst.
    public mutating func noteCommand(at t: Date = Date()) {
        let first = firstPendingCommand ?? t
        firstPendingCommand = first
        commandDue = min(t.addingTimeInterval(Self.debounce), first.addingTimeInterval(Self.maxCommandDelay))
    }

    /// A sync ran (successfully or not): the next periodic one is an interval later.
    public mutating func noteSynced(at t: Date = Date()) {
        nextPeriodic = t.addingTimeInterval(interval)
        commandDue = nil
        firstPendingCommand = nil
    }

    public mutating func disable() { disabled = true }

    public var nextRun: Date? {
        guard !disabled else { return nil }
        if let c = commandDue { return min(c, nextPeriodic) }
        return nextPeriodic
    }
}
