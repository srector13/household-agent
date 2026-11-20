#if canImport(EventKit)
import EventKit
import Foundation

/// Reminders + Calendar access via EventKit. An actor so the (non-Sendable) EKEventStore is only
/// touched from one place at a time.
public actor EventKitService: ItemStore {
    private let store = EKEventStore()
    private let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    // MARK: Permissions

    public static func hasRemindersAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    public static func hasCalendarAccess() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Prompts for full access where the status is not yet determined. Returns the resulting flags.
    @discardableResult
    public func requestAccess() async -> (reminders: Bool, calendar: Bool) {
        var reminders = Self.hasRemindersAccess()
        var calendar = Self.hasCalendarAccess()
        if !reminders {
            do { reminders = try await store.requestFullAccessToReminders() } catch {
                Log.error("Reminders access request failed: \(error)")
            }
        }
        if !calendar {
            do { calendar = try await store.requestFullAccessToEvents() } catch {
                Log.error("Calendar access request failed: \(error)")
            }
        }
        if reminders || calendar {
            // Pick up calendars that appeared once access was granted.
            store.refreshSourcesIfNecessary()
        }
        return (reminders, calendar)
    }

    public func permissionFlags() async -> (reminders: Bool, calendar: Bool) {
        (Self.hasRemindersAccess(), Self.hasCalendarAccess())
    }

    // MARK: Lookup

    public func findItem(taggedWith tag: String, kind: ItemKind, around date: Date?) async throws -> String? {
        switch kind {
        case .reminder:
            guard Self.hasRemindersAccess() else { throw ItemStoreError("no Reminders access") }
            let store = self.store
            let predicate = store.predicateForReminders(in: nil)
            return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                _ = store.fetchReminders(matching: predicate) { reminders in
                    let id = reminders?.first { ($0.notes ?? "").contains(tag) }?.calendarItemIdentifier
                    c.resume(returning: id)
                }
            }
        case .event:
            guard Self.hasCalendarAccess() else { throw ItemStoreError("no Calendar access") }
            let center = date ?? Date()
            let year: TimeInterval = 365 * 24 * 3600
            let predicate = store.predicateForEvents(withStart: center.addingTimeInterval(-year),
                                                     end: center.addingTimeInterval(year), calendars: nil)
            return store.events(matching: predicate).first { ($0.notes ?? "").contains(tag) }?.calendarItemIdentifier
        }
    }

    // MARK: Reminders

    private func reminderList(named name: String?, createIfMissing: Bool) throws -> EKCalendar {
        guard let name, !name.isEmpty else {
            guard let def = store.defaultCalendarForNewReminders() else {
                throw ItemStoreError("no default Reminders list")
            }
            return def
        }
        let lists = store.calendars(for: .reminder)
        if let match = lists.first(where: { $0.title == name })
            ?? lists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        guard createIfMissing else { throw ItemStoreError("Reminders list '\(name)' not found") }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = name
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw ItemStoreError("no source available to create list '\(name)'")
        }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        Log.info("created Reminders list '\(name)' in source '\(source.title)'")
        return cal
    }

    public func createReminder(_ p: ReminderPayload) async throws -> String {
        guard Self.hasRemindersAccess() else { throw ItemStoreError("no Reminders access") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = p.title
        reminder.notes = p.notes
        reminder.calendar = try reminderList(named: p.list, createIfMissing: p.createListIfMissing ?? true)
        if let due = p.due {
            guard let comps = AppleDate.dueComponents(date: due, time: p.dueTime, timeZone: timeZone) else {
                throw ItemStoreError("invalid due '\(due)' / '\(p.dueTime ?? "")'")
            }
            reminder.dueDateComponents = comps
        }
        if let alert = p.alert {
            guard let when = AppleDate.parseISO8601(alert) else { throw ItemStoreError("invalid alert '\(alert)'") }
            reminder.addAlarm(EKAlarm(absoluteDate: when))
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    // MARK: Calendar

    private func eventCalendar(named name: String?) throws -> EKCalendar {
        let calendars = store.calendars(for: .event).filter { $0.allowsContentModifications }
        if let name, !name.isEmpty {
            if let match = calendars.first(where: { $0.title == name })
                ?? calendars.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                return match
            }
            Log.warn("calendar '\(name)' not found; using default calendar")
        }
        guard let def = store.defaultCalendarForNewEvents else { throw ItemStoreError("no default calendar") }
        return def
    }

    public func createEvent(_ p: EventPayload) async throws -> String {
        guard Self.hasCalendarAccess() else { throw ItemStoreError("no Calendar access") }
        guard let start = AppleDate.parseISO8601(p.start) else { throw ItemStoreError("invalid start '\(p.start)'") }
        let parsedEnd = p.end.flatMap(AppleDate.parseISO8601)
        let event = EKEvent(eventStore: store)
        event.title = p.title
        event.notes = p.notes
        event.location = p.location
        event.calendar = try eventCalendar(named: p.calendar)
        if p.allDay == true {
            // All-day: local date parts only; `end` is inclusive.
            let startDay = AppleDate.startOfDay(start, timeZone: timeZone)
            let endDay = parsedEnd.map { AppleDate.startOfDay($0, timeZone: timeZone) } ?? startDay
            event.isAllDay = true
            event.startDate = startDay
            event.endDate = max(endDay, startDay)
        } else {
            event.timeZone = timeZone
            event.startDate = start
            var end = parsedEnd ?? start.addingTimeInterval(3600)
            if end <= start { end = start.addingTimeInterval(3600) }
            event.endDate = end
        }
        if let minutes = p.alertMinutesBefore, minutes >= 0 {
            event.addAlarm(EKAlarm(relativeOffset: -TimeInterval(minutes) * 60))
        }
        try store.save(event, span: .thisEvent, commit: true)
        return event.calendarItemIdentifier
    }

    // MARK: Delete

    public func deleteItem(id: String, kind: ItemKind?) async throws -> Bool {
        guard let item = store.calendarItem(withIdentifier: id) else { return false }
        if let reminder = item as? EKReminder {
            try store.remove(reminder, commit: true)
            return true
        }
        if let event = item as? EKEvent {
            try store.remove(event, span: .thisEvent, commit: true)
            return true
        }
        throw ItemStoreError("item \(id) has unexpected type")
    }
}
#endif
