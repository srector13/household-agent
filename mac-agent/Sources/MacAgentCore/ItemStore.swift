import Foundation

public struct ItemStoreError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Abstraction over EventKit so command handling can be tested without Apple frameworks.
public protocol ItemStore: Sendable {
    /// Identifier of an existing item of `kind` whose notes contain `tag`, if any.
    func findItem(taggedWith tag: String, kind: ItemKind, around date: Date?) async throws -> String?
    func createReminder(_ p: ReminderPayload) async throws -> String
    func createEvent(_ p: EventPayload) async throws -> String
    /// Deletes the item. Returns false if it no longer exists (treated as success).
    func deleteItem(id: String, kind: ItemKind?) async throws -> Bool
    /// Applies `changes` (only `.set` / `.clear` fields) and appends `notesAppend` to the notes,
    /// keeping [ha:] tag lines last. Returns false if no item with that identifier exists.
    func updateItem(id: String, kind: ItemKind, changes: ItemChanges, notesAppend: String?) async throws -> Bool
    /// EKCalendar.calendarIdentifier of the list holding this reminder (needed for sections).
    func listIdentifier(ofReminder id: String) async throws -> String?
    func permissionFlags() async -> (reminders: Bool, calendar: Bool)
    /// Current state of an item, for completion sync. `.notFound` only when the store is loaded and
    /// has full access for `kind`; anything uncertain is `.unknown`.
    func itemStatus(id: String, kind: ItemKind) async -> ItemLookup
    /// Called before a status sync so changes made on other devices (iCloud) are visible.
    func refreshForStatusSync() async
}

extension ItemStore {
    public func itemStatus(id: String, kind: ItemKind) async -> ItemLookup { .unknown("not supported") }
    public func refreshForStatusSync() async {}
}

/// Applies brain commands to an ItemStore, enforcing tag-based idempotency.
public struct CommandExecutor: Sendable {
    public let store: ItemStore
    public let organizer: ReminderOrganizer

    public init(store: ItemStore, organizer: ReminderOrganizer = NoReminderOrganizer()) {
        self.store = store
        self.organizer = organizer
    }

    public func execute(_ cmd: AgentCommand) async -> CommandResult {
        do {
            switch cmd.payload {
            case .createReminder(let p):
                let anchor = p.due.flatMap { AppleDate.dueComponents(date: $0, time: p.dueTime) }
                    .flatMap { Calendar(identifier: .gregorian).date(from: $0) }
                if let tag = nonEmpty(p.tag), let existing = try await store.findItem(taggedWith: tag, kind: .reminder, around: anchor) {
                    Log.info("cmd \(cmd.commandId): reminder already exists for \(tag)")
                    return .done(existing)
                }
                return try await createReminder(p, commandId: cmd.commandId)
            case .createEvent(let p):
                guard let start = AppleDate.parseISO8601(p.start) else {
                    return .failed("invalid start '\(p.start)'")
                }
                if let end = p.end, AppleDate.parseISO8601(end) == nil {
                    return .failed("invalid end '\(end)'")
                }
                if let tag = nonEmpty(p.tag), let existing = try await store.findItem(taggedWith: tag, kind: .event, around: start) {
                    Log.info("cmd \(cmd.commandId): event already exists for \(tag)")
                    return .done(existing)
                }
                let id = try await store.createEvent(p)
                Log.info("cmd \(cmd.commandId): created event '\(p.title)' in \(p.calendar ?? "default")")
                return .done(id)
            case .deleteItem(let p):
                if let id = nonEmpty(p.appleItemId), try await store.deleteItem(id: id, kind: p.kind) {
                    Log.info("cmd \(cmd.commandId): deleted \(id)")
                    return .done(id)
                }
                if let tag = nonEmpty(p.tag) {
                    for kind in p.kind.map({ [$0] }) ?? [.reminder, .event] {
                        let found: String?
                        if p.kind == nil {
                            // Kind unknown: a missing permission for one kind must not stop the search in the other.
                            found = (try? await store.findItem(taggedWith: tag, kind: kind, around: nil)) ?? nil
                        } else {
                            found = try await store.findItem(taggedWith: tag, kind: kind, around: nil)
                        }
                        guard let found else { continue }
                        _ = try await store.deleteItem(id: found, kind: kind)
                        Log.info("cmd \(cmd.commandId): deleted \(found) (found by tag \(tag))")
                        return .done(found)
                    }
                }
                Log.info("cmd \(cmd.commandId): delete \(p.appleItemId ?? p.tag ?? "?") (already gone)")
                return .done(p.appleItemId)
            case .updateItem(let p):
                if let problem = validate(p.changes) { return .failed(problem) }
                if let id = nonEmpty(p.appleItemId),
                   try await store.updateItem(id: id, kind: p.kind, changes: p.changes, notesAppend: p.notesAppend) {
                    Log.info("cmd \(cmd.commandId): updated \(p.kind.rawValue) \(id)")
                    return .done(id)
                }
                if let tag = nonEmpty(p.tag),
                   let found = try await store.findItem(taggedWith: tag, kind: p.kind, around: nil),
                   try await store.updateItem(id: found, kind: p.kind, changes: p.changes, notesAppend: p.notesAppend) {
                    Log.info("cmd \(cmd.commandId): updated \(p.kind.rawValue) \(found) (found by tag \(tag))")
                    return .done(found)
                }
                return .failed("item not found")
            case .unsupported(_, let reason):
                return .failed(reason)
            }
        } catch {
            Log.error("cmd \(cmd.commandId) failed: \(error)")
            return .failed(String(describing: error))
        }
    }

    /// Creates the reminder, then (if asked) puts it in a section and tags it via the organizer.
    /// Whenever that can't be done the reminder still gets created, titled with `title_fallback`,
    /// and the result carries a `warning` — status stays `done`.
    private func createReminder(_ p: ReminderPayload, commandId: String) async throws -> CommandResult {
        let tags = (p.tags ?? []).filter { !$0.isEmpty }
        let section = nonEmpty(p.section?.trimmingCharacters(in: .whitespaces))
        guard p.wantsOrganization else {
            let id = try await store.createReminder(p)
            Log.info("cmd \(commandId): created reminder '\(p.title)' in \(p.list ?? "default")")
            return .done(id)
        }
        // Decide BEFORE creating, so an unavailable ReminderKit never leaves a mis-titled reminder.
        guard await organizer.isAvailable() else {
            var fallback = p
            if let t = nonEmpty(p.titleFallback) { fallback.title = t }
            let id = try await store.createReminder(fallback)
            Log.info("cmd \(commandId): created reminder '\(fallback.title)' (ReminderKit unavailable, title fallback)")
            return CommandResult(status: .done, appleItemId: id, warning: "ReminderKit unavailable — used title fallback")
        }
        let id = try await store.createReminder(p)
        do {
            guard let listId = try await store.listIdentifier(ofReminder: id) else {
                throw OrganizerError("could not find the reminder's list")
            }
            try await organizer.apply(listIdentifier: listId, reminderIdentifier: id, section: section, tags: tags)
            Log.info("cmd \(commandId): created reminder '\(p.title)' in \(p.list ?? "default")"
                     + (section.map { " / section '\($0)'" } ?? "") + (tags.isEmpty ? "" : " tags \(tags)"))
            return .done(id)
        } catch {
            Log.warn("cmd \(commandId): section/tags failed for \(id): \(error) — using title fallback")
            if let t = nonEmpty(p.titleFallback), t != p.title {
                _ = try? await store.updateItem(id: id, kind: .reminder, changes: ItemChanges(title: .set(t)),
                                                notesAppend: nil)
            }
            return CommandResult(status: .done, appleItemId: id,
                                 warning: "section/tags not applied (\(error)) — used title fallback")
        }
    }

    /// Rejects malformed dates before touching the store.
    private func validate(_ ch: ItemChanges) -> String? {
        if let due = ch.due.value {
            let time = ch.dueTime.value
            if AppleDate.dueComponents(date: due, time: time) == nil { return "invalid due '\(due)' / '\(time ?? "")'" }
        } else if let time = ch.dueTime.value, AppleDate.dueComponents(date: "2000-01-01", time: time) == nil {
            return "invalid due_time '\(time)'"
        }
        for (name, v) in [("alert", ch.alert.value), ("start", ch.start.value), ("end", ch.end.value)] {
            if let v, AppleDate.parseISO8601(v) == nil { return "invalid \(name) '\(v)'" }
        }
        return nil
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
