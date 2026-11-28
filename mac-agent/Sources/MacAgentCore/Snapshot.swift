import Foundation

// Full-picture calendar snapshot: everything in iCloud Calendar / Reminders for the next few days,
// including items Second Brain did not create, so the app's "Up next" / "Coming up" are complete.
//
//   POST /api/agent/snapshot ← CalendarSnapshot
//
// A kind the agent cannot read (no permission, store not loaded) is sent as `null` so the brain keeps
// its previous data instead of treating it as "nothing scheduled".

public struct SnapshotEvent: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: String
    public var end: String
    public var allDay: Bool
    public var calendar: String
    public var calendarColor: String?
    public var location: String?
    public var ours: Bool

    public init(id: String, title: String, start: String, end: String, allDay: Bool, calendar: String,
                calendarColor: String? = nil, location: String? = nil, ours: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.calendarColor = calendarColor
        self.location = location
        self.ours = ours
    }

    enum CodingKeys: String, CodingKey { case id, title, start, end, allDay, calendar, calendarColor, location, ours }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(allDay, forKey: .allDay)
        try c.encode(calendar, forKey: .calendar)
        try c.encode(calendarColor, forKey: .calendarColor)
        try c.encode(location, forKey: .location)
        try c.encode(ours, forKey: .ours)
    }
}

public struct SnapshotReminder: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var list: String
    public var listColor: String?
    public var due: String?
    public var dueTime: String?
    public var priority: Int
    public var ours: Bool

    public init(id: String, title: String, list: String, listColor: String? = nil, due: String? = nil,
                dueTime: String? = nil, priority: Int = 0, ours: Bool = false) {
        self.id = id
        self.title = title
        self.list = list
        self.listColor = listColor
        self.due = due
        self.dueTime = dueTime
        self.priority = priority
        self.ours = ours
    }

    enum CodingKeys: String, CodingKey { case id, title, list, listColor, due, dueTime, priority, ours }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(list, forKey: .list)
        try c.encode(listColor, forKey: .listColor)
        try c.encode(due, forKey: .due)
        try c.encode(dueTime, forKey: .dueTime)
        try c.encode(priority, forKey: .priority)
        try c.encode(ours, forKey: .ours)
    }
}

/// One calendar or reminder list, listed even when it is empty (the app's "Show on Today" picker).
public struct SnapshotCalendar: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case event, reminder }

    public var title: String
    public var color: String?
    public var kind: Kind
    public var account: String?

    public init(title: String, color: String? = nil, kind: Kind, account: String? = nil) {
        self.title = title
        self.color = color
        self.kind = kind
        self.account = account
    }

    enum CodingKeys: String, CodingKey { case title, color, kind, account }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(color, forKey: .color)
        try c.encode(kind, forKey: .kind)
        try c.encode(account, forKey: .account)
    }
}

/// What a store can see for the snapshot. `nil` = that kind is unreadable right now.
public struct SnapshotParts: Equatable, Sendable {
    public var events: [SnapshotEvent]?
    public var reminders: [SnapshotReminder]?
    public var calendars: [SnapshotCalendar]?

    public init(events: [SnapshotEvent]? = nil, reminders: [SnapshotReminder]? = nil,
                calendars: [SnapshotCalendar]? = nil) {
        self.events = events
        self.reminders = reminders
        self.calendars = calendars
    }

    public var isEmpty: Bool { events == nil && reminders == nil && calendars == nil }
}

/// POST /api/agent/snapshot body. Unreadable kinds are explicit nulls.
public struct CalendarSnapshot: Encodable, Equatable, Sendable {
    public static let maxItems = 400
    /// Open reminders with no due date (sent so the brain can skip duplicates, "milk" is on Groceries).
    public static let maxUndated = 300
    public static let maxCalendars = 100
    public static let defaultRangeDays = 7
    /// Events are sent from this many days back, so the app's week strip has the past days too.
    public static let pastDays = 7

    public var generatedAt: String
    public var rangeDays: Int
    public var events: [SnapshotEvent]?
    public var reminders: [SnapshotReminder]?
    public var calendars: [SnapshotCalendar]?

    /// Sorts each kind (events by start, reminders by due date/time) and caps it at `maxItems`
    /// (undated reminders separately, at `maxUndated`).
    public init(parts: SnapshotParts, generatedAt: String, rangeDays: Int = defaultRangeDays) {
        self.generatedAt = generatedAt
        self.rangeDays = rangeDays
        self.events = parts.events.map { list in
            Array(list.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.prefix(Self.maxItems))
        }
        self.reminders = parts.reminders.map { list in
            let dated = list.filter { $0.due != nil }
                .sorted { ($0.due ?? "", $0.dueTime ?? "", $0.id) < ($1.due ?? "", $1.dueTime ?? "", $1.id) }
            let undated = list.filter { $0.due == nil }.sorted { ($0.list, $0.title, $0.id) < ($1.list, $1.title, $1.id) }
            return Array(dated.prefix(Self.maxItems)) + Array(undated.prefix(Self.maxUndated))
        }
        self.calendars = parts.calendars.map { list in
            Array(list.sorted { ($0.kind.rawValue, $0.title) < ($1.kind.rawValue, $1.title) }.prefix(Self.maxCalendars))
        }
    }

    /// Whether `notes` carry a Second Brain tag (item created by the agent).
    public static func isOurs(notes: String?) -> Bool { (notes ?? "").contains("[ha:") }

    enum CodingKeys: String, CodingKey { case generatedAt, rangeDays, events, reminders, calendars }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(rangeDays, forKey: .rangeDays)
        try c.encode(events, forKey: .events)        // explicit null = "keep what you had"
        try c.encode(reminders, forKey: .reminders)
        try c.encode(calendars, forKey: .calendars)
    }
}

/// "#RRGGBB" from 0…1 RGB components.
public enum HexColor {
    public static func from(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
