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
    func permissionFlags() async -> (reminders: Bool, calendar: Bool)
}

/// Applies brain commands to an ItemStore, enforcing tag-based idempotency.
public struct CommandExecutor: Sendable {
    public let store: ItemStore

    public init(store: ItemStore) {
        self.store = store
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
                let id = try await store.createReminder(p)
                Log.info("cmd \(cmd.commandId): created reminder '\(p.title)' in \(p.list ?? "default")")
                return .done(id)
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
