#if canImport(EventKit)
import CoreGraphics
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
            // A nil array means the fetch failed — throw rather than claim "not found".
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String?, Error>) in
                _ = store.fetchReminders(matching: predicate) { reminders in
                    guard let reminders else {
                        c.resume(throwing: ItemStoreError("fetching reminders failed"))
                        return
                    }
                    c.resume(returning: reminders.first { ($0.notes ?? "").contains(tag) }?.calendarItemIdentifier)
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

    // MARK: Status (completion sync)

    public func refreshForStatusSync() async {
        store.refreshSourcesIfNecessary()
    }

    public func itemStatus(id: String, kind: ItemKind) async -> ItemLookup {
        let permitted = kind == .reminder ? Self.hasRemindersAccess() : Self.hasCalendarAccess()
        guard permitted else { return .unknown("no \(kind == .reminder ? "Reminders" : "Calendar") access") }
        guard let item = store.calendarItem(withIdentifier: id) else {
            // calendarItem(withIdentifier:) is also nil when the store hasn't loaded its sources yet.
            let loaded = !store.sources.isEmpty
                && !store.calendars(for: kind == .reminder ? .reminder : .event).isEmpty
            return loaded ? .notFound : .unknown("event store not loaded")
        }
        switch kind {
        case .reminder:
            guard let r = item as? EKReminder else { return .unknown("not a reminder") }
            var snap = ItemSnapshot(completed: r.isCompleted, title: r.title)
            if let d = r.completionDate { snap.completedAt = AppleDate.iso8601(d, timeZone: timeZone) }
            if let c = r.dueDateComponents, let y = c.year, let m = c.month, let day = c.day {
                snap.due = String(format: "%04d-%02d-%02d", y, m, day)
                if let h = c.hour { snap.dueTime = String(format: "%02d:%02d", h, c.minute ?? 0) }
            }
            return .found(snap)
        case .event:
            guard let e = item as? EKEvent else { return .unknown("not an event") }
            return .found(ItemSnapshot(title: e.title,
                                       start: e.startDate.map { AppleDate.iso8601($0, timeZone: timeZone) },
                                       end: e.endDate.map { AppleDate.iso8601($0, timeZone: timeZone) }))
        }
    }

    // MARK: Calendar snapshot (full picture, not just our items)

    public func calendarSnapshot(rangeDays: Int, now: Date) async -> SnapshotParts {
        store.refreshSourcesIfNecessary()
        let horizon = now.addingTimeInterval(TimeInterval(max(rangeDays, 1)) * 86_400)
        let past = now.addingTimeInterval(-TimeInterval(CalendarSnapshot.pastDays) * 86_400)
        var reminders = await snapshotReminders(from: now.addingTimeInterval(-30 * 86_400), to: horizon)
        if reminders != nil, let undated = await undatedReminders() {
            reminders?.append(contentsOf: undated)
        }
        return SnapshotParts(events: snapshotEvents(from: past, to: horizon), reminders: reminders,
                             calendars: snapshotCalendars())
    }

    /// Every calendar and reminder list (even empty ones). nil when neither kind is readable.
    private func snapshotCalendars() -> [SnapshotCalendar]? {
        guard !store.sources.isEmpty else { return nil }
        var out: [SnapshotCalendar] = []
        if Self.hasCalendarAccess() {
            for c in store.calendars(for: .event) {
                out.append(SnapshotCalendar(title: c.title, color: Self.hex(c.cgColor), kind: .event,
                                            account: Self.nonEmpty(c.source?.title)))
            }
        }
        if Self.hasRemindersAccess() {
            for c in store.calendars(for: .reminder) {
                out.append(SnapshotCalendar(title: c.title, color: Self.hex(c.cgColor), kind: .reminder,
                                            account: Self.nonEmpty(c.source?.title)))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Incomplete reminders with no due date (for duplicate checks). nil when unreadable.
    private func undatedReminders() async -> [SnapshotReminder]? {
        guard Self.hasRemindersAccess() else { return nil }
        let store = self.store
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { (c: CheckedContinuation<[SnapshotReminder]?, Never>) in
            _ = store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else { c.resume(returning: nil); return }
                c.resume(returning: reminders.compactMap { r -> SnapshotReminder? in
                    guard r.dueDateComponents == nil else { return nil }
                    return SnapshotReminder(
                        id: r.calendarItemIdentifier, title: r.title ?? "", list: r.calendar?.title ?? "",
                        listColor: Self.hex(r.calendar?.cgColor), due: nil, dueTime: nil, priority: r.priority,
                        ours: CalendarSnapshot.isOurs(notes: r.notes))
                })
            }
        }
    }

    /// nil when Calendar is unreadable (no access or store not loaded yet).
    private func snapshotEvents(from start: Date, to end: Date) -> [SnapshotEvent]? {
        guard Self.hasCalendarAccess() else { return nil }
        let calendars = store.calendars(for: .event)
        guard !store.sources.isEmpty, !calendars.isEmpty else { return nil }
        // predicateForEvents expands recurring events into their occurrences.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var out: [SnapshotEvent] = []
        var seen = Set<String>()
        for e in store.events(matching: predicate) where e.status != .canceled {
            guard let s = e.startDate, let en = e.endDate else { continue }
            let base = e.calendarItemIdentifier
            let startISO = AppleDate.iso8601(s, timeZone: timeZone)
            // Occurrences of a recurring event share one identifier; make each entry unique.
            let id = e.hasRecurrenceRules ? "\(base)/\(startISO)" : base
            guard seen.insert(id).inserted else { continue }
            out.append(SnapshotEvent(
                id: id, title: e.title ?? "", start: startISO, end: AppleDate.iso8601(en, timeZone: timeZone),
                allDay: e.isAllDay, calendar: e.calendar?.title ?? "",
                calendarColor: Self.hex(e.calendar?.cgColor), location: Self.nonEmpty(e.location),
                ours: CalendarSnapshot.isOurs(notes: e.notes)))
        }
        return out
    }

    /// Incomplete reminders due in the window (no-due reminders excluded). nil when unreadable.
    private func snapshotReminders(from start: Date, to end: Date) async -> [SnapshotReminder]? {
        guard Self.hasRemindersAccess() else { return nil }
        guard !store.sources.isEmpty, !store.calendars(for: .reminder).isEmpty else { return nil }
        let store = self.store
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
        // Convert inside the callback: EKReminder isn't Sendable.
        let rows: [SnapshotReminder]? = await withCheckedContinuation { (c: CheckedContinuation<[SnapshotReminder]?, Never>) in
            _ = store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else { c.resume(returning: nil); return }
                c.resume(returning: reminders.compactMap { r -> SnapshotReminder? in
                    guard let comps = r.dueDateComponents, let y = comps.year, let m = comps.month, let d = comps.day
                    else { return nil }
                    var dueTime: String?
                    if let h = comps.hour { dueTime = String(format: "%02d:%02d", h, comps.minute ?? 0) }
                    return SnapshotReminder(
                        id: r.calendarItemIdentifier, title: r.title ?? "", list: r.calendar?.title ?? "",
                        listColor: Self.hex(r.calendar?.cgColor), due: String(format: "%04d-%02d-%02d", y, m, d),
                        dueTime: dueTime, priority: r.priority, ours: CalendarSnapshot.isOurs(notes: r.notes))
                })
            }
        }
        return rows
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// "#RRGGBB" from a calendar color, best effort (nil if it can't be converted to sRGB).
    private static func hex(_ color: CGColor?) -> String? {
        guard let color, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else { return nil }
        return HexColor.from(red: Double(comps[0]), green: Double(comps[1]), blue: Double(comps[2]))
    }

    // MARK: Reminders

    private func reminderList(named name: String?, createIfMissing: Bool) throws -> EKCalendar {
        guard let name, !name.isEmpty else {
            guard let def = store.defaultCalendarForNewReminders() else {
                throw ItemStoreError("no default Reminders list")
            }
            return def
        }
        // Names may contain emoji and people's names ("🎁 Gifts for Sarah"): compare in canonical
        // Unicode form, ignoring surrounding whitespace, then case-insensitively.
        let wanted = Self.canonical(name)
        let lists = store.calendars(for: .reminder)
        if let match = lists.first(where: { Self.canonical($0.title) == wanted })
            ?? lists.first(where: { Self.canonical($0.title).caseInsensitiveCompare(wanted) == .orderedSame }) {
            return match
        }
        guard createIfMissing else { throw ItemStoreError("Reminders list '\(name)' not found") }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = wanted
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw ItemStoreError("no source available to create list '\(name)'")
        }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        Log.info("created Reminders list '\(wanted)' in source '\(source.title)'")
        return cal
    }

    static func canonical(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func link(_ s: String?) -> URL? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    public func createReminder(_ p: ReminderPayload) async throws -> String {
        guard Self.hasRemindersAccess() else { throw ItemStoreError("no Reminders access") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = p.title
        reminder.notes = p.notes
        reminder.calendar = try reminderList(named: p.list, createIfMissing: p.createListIfMissing ?? true)
        if let url = Self.link(p.url) { reminder.url = url }
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
        if let url = Self.link(p.url) { event.url = url }
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

    // MARK: Update

    public func listIdentifier(ofReminder id: String) async throws -> String? {
        guard Self.hasRemindersAccess() else { throw ItemStoreError("no Reminders access") }
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return r.calendar?.calendarIdentifier
    }

    // MARK: Probe helpers (mac-agent --probe-reminderkit --write)

    /// Identifier of the reminder list with this exact name, if it exists.
    public func reminderListIdentifier(named name: String) -> String? {
        let wanted = Self.canonical(name)
        return store.calendars(for: .reminder).first { Self.canonical($0.title) == wanted }?.calendarIdentifier
    }

    /// Deletes a reminder list (used only to clean up the probe's own test list).
    public func deleteReminderList(identifier: String) throws {
        guard let cal = store.calendar(withIdentifier: identifier) else { return }
        try store.removeCalendar(cal, commit: true)
    }

    public func updateItem(id: String, kind: ItemKind, changes ch: ItemChanges, notesAppend: String?) async throws -> Bool {
        guard let item = store.calendarItem(withIdentifier: id) else { return false }
        if let title = ch.title.value { item.title = title }
        switch ch.location {
        case .set(let v): item.location = v
        case .clear: item.location = nil
        case .keep: break
        }
        switch ch.url {
        case .set(let v): item.url = Self.link(v)
        case .clear: item.url = nil
        case .keep: break
        }
        if let note = notesAppend { item.notes = NotesEditor.append(note, to: item.notes) }

        if let reminder = item as? EKReminder {
            try applyReminderChanges(reminder, ch)
            try store.save(reminder, commit: true)
            return true
        }
        if let event = item as? EKEvent {
            try applyEventChanges(event, ch)
            try store.save(event, span: .thisEvent, commit: true)
            return true
        }
        throw ItemStoreError("item \(id) has unexpected type")
    }

    private func applyReminderChanges(_ r: EKReminder, _ ch: ItemChanges) throws {
        switch ch.due {
        case .clear:
            r.dueDateComponents = nil
        case .set(let due):
            guard let comps = AppleDate.dueComponents(date: due, time: ch.dueTime.value, timeZone: timeZone) else {
                throw ItemStoreError("invalid due '\(due)'")
            }
            r.dueDateComponents = comps
        case .keep:
            // Only the time changed: keep the existing day.
            if !ch.dueTime.isKeep, let existing = r.dueDateComponents,
               let y = existing.year, let m = existing.month, let d = existing.day {
                let day = String(format: "%04d-%02d-%02d", y, m, d)
                guard let comps = AppleDate.dueComponents(date: day, time: ch.dueTime.value, timeZone: timeZone) else {
                    throw ItemStoreError("invalid due_time '\(ch.dueTime.value ?? "")'")
                }
                r.dueDateComponents = comps
            }
        }
        switch ch.alert {
        case .clear:
            r.alarms?.forEach { r.removeAlarm($0) }
        case .set(let iso):
            guard let when = AppleDate.parseISO8601(iso) else { throw ItemStoreError("invalid alert '\(iso)'") }
            r.alarms?.forEach { r.removeAlarm($0) }
            r.addAlarm(EKAlarm(absoluteDate: when))
        case .keep:
            break
        }
        if let done = ch.completed.value { r.isCompleted = done }
    }

    private func applyEventChanges(_ e: EKEvent, _ ch: ItemChanges) throws {
        guard !(ch.start.isKeep && ch.end.isKeep && ch.allDay.isKeep) else { return }
        let oldStart = e.startDate ?? Date()
        let oldEnd = e.endDate ?? oldStart.addingTimeInterval(3600)
        var start = oldStart
        if let s = ch.start.value {
            guard let d = AppleDate.parseISO8601(s) else { throw ItemStoreError("invalid start '\(s)'") }
            start = d
        }
        var end: Date
        if let s = ch.end.value {
            guard let d = AppleDate.parseISO8601(s) else { throw ItemStoreError("invalid end '\(s)'") }
            end = d
        } else {
            // Moving the start without a new end keeps the event's length.
            end = start.addingTimeInterval(max(oldEnd.timeIntervalSince(oldStart), 0))
        }
        let allDay = ch.allDay.value ?? e.isAllDay
        if allDay {
            let startDay = AppleDate.startOfDay(start, timeZone: timeZone)
            let endDay = AppleDate.startOfDay(end, timeZone: timeZone)
            e.isAllDay = true
            e.startDate = startDay
            e.endDate = max(endDay, startDay)
        } else {
            e.isAllDay = false
            e.timeZone = timeZone
            if end <= start { end = start.addingTimeInterval(3600) }
            e.startDate = start
            e.endDate = end
        }
    }
}
#endif
