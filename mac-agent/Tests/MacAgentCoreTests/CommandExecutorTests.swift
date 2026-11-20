import XCTest
@testable import MacAgentCore

final class CommandExecutorTests: XCTestCase {
    func reminderCommand(id: String = "cmd_1", tag: String = "[ha:imessage:1]") -> AgentCommand {
        AgentCommand(commandId: id, eventId: "imessage:1", op: "create_reminder", payload: .createReminder(
            ReminderPayload(title: "Pick up eggs", list: "Groceries", due: "2026-11-20",
                            alert: "2026-11-20T16:00:00-06:00", notes: "From Wife\n\(tag)", tag: tag)))
    }

    func testCreateReminderIsIdempotentByTag() async throws {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let first = await ex.execute(reminderCommand())
        XCTAssertEqual(first.status, .done)
        XCTAssertNotNil(first.appleItemId)
        let again = await ex.execute(reminderCommand(id: "cmd_1_redelivered"))
        XCTAssertEqual(again, first)
        let count = await store.createCount
        XCTAssertEqual(count, 1)
        // A different tag (second action of the same message) creates a new item.
        let second = await ex.execute(reminderCommand(id: "cmd_2", tag: "[ha:imessage:1#1]"))
        XCTAssertNotEqual(second.appleItemId, first.appleItemId)
    }

    func testCreateEventValidatesDates() async {
        let ex = CommandExecutor(store: FakeItemStore())
        let bad = AgentCommand(commandId: "c", eventId: nil, op: "create_event",
                               payload: .createEvent(EventPayload(title: "Dentist", start: "Tuesday 3:30")))
        let r = await ex.execute(bad)
        XCTAssertEqual(r.status, .failed)
        let good = AgentCommand(commandId: "c2", eventId: nil, op: "create_event", payload: .createEvent(
            EventPayload(title: "Dentist", calendar: "Family", start: "2026-11-24T15:30:00-06:00",
                         end: "2026-11-24T16:30:00-06:00", alertMinutesBefore: 30, tag: "[ha:imessage:2]")))
        let ok = await ex.execute(good)
        XCTAssertEqual(ok.status, .done)
    }

    func testDeleteIsDoneEvenIfMissing() async {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let created = await ex.execute(reminderCommand())
        let del = AgentCommand(commandId: "d", eventId: nil, op: "delete_item",
                               payload: .deleteItem(DeletePayload(appleItemId: created.appleItemId!, kind: .reminder)))
        let r1 = await ex.execute(del)
        XCTAssertEqual(r1.status, .done)
        let r2 = await ex.execute(del)
        XCTAssertEqual(r2.status, .done)
        let items = await store.items
        XCTAssertTrue(items.isEmpty)
    }

    func testUnsupportedFails() async {
        let r = await CommandExecutor(store: FakeItemStore()).execute(
            AgentCommand(commandId: "u", eventId: nil, op: "nope", payload: .unsupported(op: "nope", reason: "unsupported op 'nope'")))
        XCTAssertEqual(r, .failed("unsupported op 'nope'"))
    }
}
