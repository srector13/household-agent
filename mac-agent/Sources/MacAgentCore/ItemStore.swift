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
                let existed = try await store.deleteItem(id: p.appleItemId, kind: p.kind)
                Log.info("cmd \(cmd.commandId): delete \(p.appleItemId) (\(existed ? "removed" : "already gone"))")
                return .done(p.appleItemId)
            case .unsupported(_, let reason):
                return .failed(reason)
            }
        } catch {
            Log.error("cmd \(cmd.commandId) failed: \(error)")
            return .failed(String(describing: error))
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
