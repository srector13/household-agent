import Foundation

/// Puts a reminder into a list *section* (a column in Reminders' column view) and adds #tags.
///
/// EventKit has no API for either, so the macOS implementation (`ReminderKitOrganizer`) uses Apple's
/// private ReminderKit framework. It is abstracted here so the executor can fall back to a plain
/// title when it is unavailable, and so tests can use a fake.
public protocol ReminderOrganizer: Sendable {
    /// Cheap check (framework loads, classes and selectors exist). Cached by implementations.
    func isAvailable() async -> Bool
    /// Last known availability for the heartbeat: nil = not probed yet.
    func lastKnownAvailability() async -> Bool?
    /// Applies `section` (created in the list if missing) and `tags` to an existing reminder.
    /// `listIdentifier` is EKCalendar.calendarIdentifier, `reminderIdentifier` EKReminder.calendarItemIdentifier.
    func apply(listIdentifier: String, reminderIdentifier: String, section: String?, tags: [String]) async throws
}

public struct OrganizerError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Used where ReminderKit can't exist (Linux) or is disabled: always unavailable.
public struct NoReminderOrganizer: ReminderOrganizer {
    public init() {}
    public func isAvailable() async -> Bool { false }
    public func lastKnownAvailability() async -> Bool? { false }
    public func apply(listIdentifier: String, reminderIdentifier: String, section: String?, tags: [String]) async throws {
        throw OrganizerError("ReminderKit is not available on this platform")
    }
}
