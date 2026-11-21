import XCTest
@testable import MacAgentCore

final class UpdateItemTests: XCTestCase {
    func decode(_ json: String) throws -> AgentCommand {
        try Wire.decoder().decode(AgentCommand.self, from: Data(json.utf8))
    }

    // MARK: decoding

    func testDecodeUpdatePresentNullMissing() throws {
        let cmd = try decode("""
        {"command_id":"c1","event_id":"imessage:2","op":"update_item","payload":{
          "apple_item_id":"x-apple-1","tag":"[ha:imessage:1]","kind":"reminder",
          "changes":{"title":"Pick up eggs","due":"2026-11-22","due_time":null,"alert":null,"completed":true},
          "notes_append":"Updated from Me: \\"I'll do it tomorrow\\""}}
        """)
        guard case .updateItem(let p) = cmd.payload else { return XCTFail("\(cmd.payload)") }
        XCTAssertEqual(p.appleItemId, "x-apple-1")
        XCTAssertEqual(p.kind, .reminder)
        XCTAssertEqual(p.changes.title, .set("Pick up eggs"))
        XCTAssertEqual(p.changes.due, .set("2026-11-22"))
        XCTAssertEqual(p.changes.dueTime, .clear)
        XCTAssertEqual(p.changes.alert, .clear)
        XCTAssertEqual(p.changes.completed, .set(true))
        XCTAssertEqual(p.changes.start, .keep)
        XCTAssertEqual(p.changes.location, .keep)
        XCTAssertEqual(p.changes.url, .keep)
        XCTAssertEqual(p.notesAppend, "Updated from Me: \"I'll do it tomorrow\"")
    }

    func testDecodeUpdateWithNullIdAndNoChanges() throws {
        let cmd = try decode("""
        {"command_id":"c1","op":"update_item","payload":{"apple_item_id":null,"tag":"[ha:x]","kind":"event"}}
        """)
        guard case .updateItem(let p) = cmd.payload else { return XCTFail("\(cmd.payload)") }
        XCTAssertNil(p.appleItemId)
        XCTAssertEqual(p.changes, ItemChanges())
        XCTAssertNil(p.notesAppend)
    }

    func testDecodeUpdateMissingKindIsUnsupported() throws {
        let cmd = try decode(#"{"command_id":"c1","op":"update_item","payload":{"tag":"[ha:x]"}}"#)
        guard case .unsupported = cmd.payload else { return XCTFail("\(cmd.payload)") }
    }

    func testDecodeDeleteWithTagAndNullId() throws {
        let cmd = try decode("""
        {"command_id":"d","op":"delete_item","payload":{"apple_item_id":null,"kind":"reminder","tag":"[ha:imessage:1]"}}
        """)
        XCTAssertEqual(cmd.payload, .deleteItem(DeletePayload(appleItemId: nil, kind: .reminder, tag: "[ha:imessage:1]")))
    }

    func testDecodeURLOnCreates() throws {
        let r = try decode("""
        {"command_id":"c","op":"create_reminder","payload":{"title":"Kindle Paperwhite","list":"🎁 Gifts for Sarah",
         "url":"https://example.com/kindle","notes":"x","tag":"[ha:imessage:9]"}}
        """)
        guard case .createReminder(let p) = r.payload else { return XCTFail() }
        XCTAssertEqual(p.url, "https://example.com/kindle")
        XCTAssertEqual(p.list, "🎁 Gifts for Sarah")
        let e = try decode("""
        {"command_id":"c","op":"create_event","payload":{"title":"Concert","start":"2026-12-01T19:00:00-06:00","url":null}}
        """)
        guard case .createEvent(let ep) = e.payload else { return XCTFail() }
        XCTAssertNil(ep.url)
    }

    // MARK: executor

    func create(_ ex: CommandExecutor, tag: String = "[ha:imessage:1]", url: String? = nil) async -> CommandResult {
        await ex.execute(AgentCommand(commandId: "c", eventId: "imessage:1", op: "create_reminder", payload: .createReminder(
            ReminderPayload(title: "Pick up eggs", list: "Household", notes: "From Sarah: \"grab eggs\"\n\(tag)",
                            tag: tag, url: url))))
    }

    func update(_ id: String?, tag: String? = "[ha:imessage:1]", kind: ItemKind = .reminder,
                _ changes: ItemChanges, note: String? = nil) -> AgentCommand {
        AgentCommand(commandId: "u", eventId: "imessage:2", op: "update_item",
                     payload: .updateItem(UpdatePayload(appleItemId: id, tag: tag, kind: kind, changes: changes, notesAppend: note)))
    }

    func testURLOnCreate() async {
        let store = FakeItemStore()
        let r = await create(CommandExecutor(store: store), url: "https://example.com/x")
        let item = await store.items[r.appleItemId!]
        XCTAssertEqual(item?.url, "https://example.com/x")
    }

    func testUpdateById() async {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let id = await create(ex).appleItemId!
        let r = await ex.execute(update(id, ItemChanges(due: .set("2026-11-22"), alert: .set("2026-11-22T16:00:00-06:00"))))
        XCTAssertEqual(r, .done(id))
        let item = await store.items[id]!
        XCTAssertEqual(item.due, "2026-11-22")
        XCTAssertNil(item.dueTime)
        XCTAssertEqual(item.alert, "2026-11-22T16:00:00-06:00")
        XCTAssertEqual(item.title, "Pick up eggs")  // untouched
    }

    func testUpdateFallsBackToTag() async {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let id = await create(ex).appleItemId!
        // Unknown id (e.g. item re-synced) and a null id both resolve through the tag.
        for given in ["x-apple-stale", nil] as [String?] {
            let r = await ex.execute(update(given, ItemChanges(title: .set("Pick up 2 dozen eggs"))))
            XCTAssertEqual(r, .done(id))
        }
        let title = await store.items[id]?.title
        XCTAssertEqual(title, "Pick up 2 dozen eggs")
    }

    func testUpdateNotFoundFails() async {
        let ex = CommandExecutor(store: FakeItemStore())
        let r = await ex.execute(update("nope", tag: "[ha:missing]", ItemChanges(title: .set("x"))))
        XCTAssertEqual(r, .failed("item not found"))
        let r2 = await ex.execute(update(nil, tag: nil, ItemChanges(title: .set("x"))))
        XCTAssertEqual(r2, .failed("item not found"))
    }

    func testCompleteAndClear() async {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let id = await create(ex).appleItemId!
        _ = await ex.execute(update(id, ItemChanges(due: .set("2026-11-22"), dueTime: .set("09:30"))))
        let r = await ex.execute(update(id, ItemChanges(due: .clear, alert: .clear, completed: .set(true))))
        XCTAssertEqual(r.status, .done)
        let item = await store.items[id]!
        XCTAssertTrue(item.completed)
        XCTAssertNil(item.due)
        XCTAssertNil(item.dueTime)
        XCTAssertNil(item.alert)
    }

    func testInvalidDatesFailBeforeTouchingStore() async {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let id = await create(ex).appleItemId!
        for ch in [ItemChanges(due: .set("Tuesday")), ItemChanges(alert: .set("4pm")),
                   ItemChanges(dueTime: .set("25:99")), ItemChanges(start: .set("soon"))] {
            let r = await ex.execute(update(id, ch))
            XCTAssertEqual(r.status, .failed, "\(ch)")
        }
        let n = await store.updateCount
        XCTAssertEqual(n, 0)
    }

    func testNotesAppendKeepsTagLast() async {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let id = await create(ex).appleItemId!
        _ = await ex.execute(update(id, ItemChanges(), note: "Updated from Me: \"I'll do it tomorrow\""))
        let notes = await store.items[id]?.notes
        XCTAssertEqual(notes, "From Sarah: \"grab eggs\"\nUpdated from Me: \"I'll do it tomorrow\"\n[ha:imessage:1]")
        // The tag still finds it.
        let found = try? await store.findItem(taggedWith: "[ha:imessage:1]", kind: .reminder, around: nil)
        XCTAssertEqual(found, id)
    }

    func testNotesEditor() {
        XCTAssertEqual(NotesEditor.append("b", to: nil), "b")
        XCTAssertEqual(NotesEditor.append("b", to: "a"), "a\nb")
        XCTAssertEqual(NotesEditor.append("b", to: "a\n\n"), "a\nb")
        XCTAssertEqual(NotesEditor.append("c", to: "a\n[ha:x]\n[ha:x#1]\n"), "a\nc\n[ha:x]\n[ha:x#1]")
        XCTAssertEqual(NotesEditor.append("  ", to: "a"), "a")
        XCTAssertEqual(NotesEditor.append("b", to: "[ha:x]"), "b\n[ha:x]")
    }

    func testDeleteFallsBackToTag() async {
        let store = FakeItemStore()
        let ex = CommandExecutor(store: store)
        let id = await create(ex).appleItemId!
        // Queued before the create reported back: no id, only the tag.
        let del = AgentCommand(commandId: "d", eventId: nil, op: "delete_item",
                               payload: .deleteItem(DeletePayload(appleItemId: nil, kind: .reminder, tag: "[ha:imessage:1]")))
        let r = await ex.execute(del)
        XCTAssertEqual(r, .done(id))
        let empty = await store.items.isEmpty
        XCTAssertTrue(empty)
        // Again: nothing left → still done (already gone).
        let again = await ex.execute(del)
        XCTAssertEqual(again.status, .done)
        // Stale id + tag, kind unknown → searches both kinds.
        let id2 = await create(ex, tag: "[ha:imessage:5]").appleItemId!
        let r2 = await ex.execute(AgentCommand(commandId: "d2", eventId: nil, op: "delete_item",
            payload: .deleteItem(DeletePayload(appleItemId: "x-stale", kind: nil, tag: "[ha:imessage:5]"))))
        XCTAssertEqual(r2, .done(id2))
    }
}
