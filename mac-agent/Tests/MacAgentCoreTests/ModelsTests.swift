import XCTest
@testable import MacAgentCore

final class ModelsTests: XCTestCase {
    func decodeCommand(_ json: String) throws -> AgentCommand {
        try Wire.decoder().decode(AgentCommand.self, from: Data(json.utf8))
    }

    func testCreateReminderPayload() throws {
        let cmd = try decodeCommand("""
        {"command_id":"cmd_01","event_id":"imessage:48213","op":"create_reminder","payload":{
          "title":"Pick up eggs","list":"Groceries","create_list_if_missing":true,"due":"2026-11-20",
          "due_time":null,"alert":"2026-11-20T16:00:00-06:00",
          "notes":"From Wife: \\"Can you grab eggs tomorrow? We're out\\"\\n[ha:imessage:48213]",
          "tag":"[ha:imessage:48213]","some_future_field":1}}
        """)
        XCTAssertEqual(cmd.commandId, "cmd_01")
        XCTAssertEqual(cmd.eventId, "imessage:48213")
        guard case .createReminder(let p) = cmd.payload else { return XCTFail("wrong payload \(cmd.payload)") }
        XCTAssertEqual(p.title, "Pick up eggs")
        XCTAssertEqual(p.list, "Groceries")
        XCTAssertEqual(p.createListIfMissing, true)
        XCTAssertEqual(p.due, "2026-11-20")
        XCTAssertNil(p.dueTime)
        XCTAssertEqual(p.alert, "2026-11-20T16:00:00-06:00")
        XCTAssertEqual(p.tag, "[ha:imessage:48213]")
        XCTAssertTrue(p.notes!.hasSuffix("[ha:imessage:48213]"))
    }

    func testCreateEventPayload() throws {
        let cmd = try decodeCommand("""
        {"command_id":"cmd_02","event_id":"imessage:48300","op":"create_event","payload":{
          "title":"Dentist","calendar":"Family","start":"2026-11-24T15:30:00-06:00",
          "end":"2026-11-24T16:30:00-06:00","all_day":false,"location":null,
          "alert_minutes_before":30,"notes":"x\\n[ha:imessage:48300]","tag":"[ha:imessage:48300]"}}
        """)
        guard case .createEvent(let p) = cmd.payload else { return XCTFail("wrong payload") }
        XCTAssertEqual(p.title, "Dentist")
        XCTAssertEqual(p.calendar, "Family")
        XCTAssertEqual(p.allDay, false)
        XCTAssertEqual(p.alertMinutesBefore, 30)
        XCTAssertNil(p.location)
        XCTAssertEqual(p.end, "2026-11-24T16:30:00-06:00")
    }

    func testDeletePayload() throws {
        let cmd = try decodeCommand("""
        {"command_id":"cmd_03","event_id":"imessage:48213","op":"delete_item",
         "payload":{"apple_item_id":"x-apple-reminder://ABC","kind":"reminder"}}
        """)
        XCTAssertEqual(cmd.payload, .deleteItem(DeletePayload(appleItemId: "x-apple-reminder://ABC", kind: .reminder)))
    }

    func testUnknownOpAndBadPayloadDoNotThrow() throws {
        let unknown = try decodeCommand(#"{"command_id":"c","op":"send_imessage","payload":{}}"#)
        guard case .unsupported(let op, _) = unknown.payload else { return XCTFail() }
        XCTAssertEqual(op, "send_imessage")
        let bad = try decodeCommand(#"{"command_id":"c","op":"create_event","payload":{"title":"x"}}"#)
        guard case .unsupported = bad.payload else { return XCTFail() }
    }

    func testCommandBatch() throws {
        let batch = try Wire.decoder().decode(CommandBatch.self, from: Data(#"{"commands":[]}"#.utf8))
        XCTAssertTrue(batch.commands.isEmpty)
    }

    func jsonObject<T: Encodable>(_ v: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Wire.encoder().encode(v)) as! [String: Any]
    }

    func testEventEncodingUsesSnakeCase() throws {
        let e = InboundEvent(eventId: "imessage:1", senderHandle: "+1", senderLabel: "Wife", chatId: "iMessage;-;+1",
                             isFromMe: false, receivedAt: "2026-11-19T16:52:00-06:00", text: "hi", recentContext: ["Me: yo"])
        let o = try jsonObject(e)
        XCTAssertEqual(Set(o.keys), ["event_id", "source", "sender_handle", "sender_label", "chat_id", "is_from_me",
                                     "received_at", "text", "recent_context"])
        XCTAssertEqual(o["source"] as? String, "imessage")
        XCTAssertEqual(o["is_from_me"] as? Bool, false)
    }

    func testResultEncodingAlwaysHasAllKeys() throws {
        let o = try jsonObject(CommandResult.done("x-apple-1"))
        XCTAssertEqual(o["status"] as? String, "done")
        XCTAssertEqual(o["apple_item_id"] as? String, "x-apple-1")
        XCTAssertTrue(o.keys.contains("error"))
        XCTAssertTrue(o["error"] is NSNull)
        let f = try jsonObject(CommandResult.failed("boom"))
        XCTAssertEqual(f["status"] as? String, "failed")
        XCTAssertTrue(f["apple_item_id"] is NSNull)
    }

    func testHeartbeatKeys() throws {
        let o = try jsonObject(Heartbeat(lastRowid: 48213, fdaOk: true, remindersOk: true, calendarOk: false,
                                         uptimeS: 3600, bufferedEvents: 2))
        XCTAssertEqual(Set(o.keys), ["agent_version", "last_rowid", "fda_ok", "reminders_ok", "calendar_ok",
                                     "uptime_s", "buffered_events"])
        XCTAssertEqual(o["last_rowid"] as? Int, 48213)
    }

    func testConfigDefaults() throws {
        let c = try JSONDecoder().decode(AgentConfig.self, from: Data(#"{"brain_url":"http://brain:8080"}"#.utf8))
        XCTAssertEqual(c.contextCount, 5)
        XCTAssertEqual(c.keychainService, "com.household.mac-agent")
        XCTAssertTrue(c.allowHandles.isEmpty)
        XCTAssertTrue(c.isAllowed(handle: "+1", chatIdentifier: nil, chatGUID: nil))
        let full = try JSONDecoder().decode(AgentConfig.self, from: Data("""
        {"brain_url":"http://b","allow_handles":["+17855550000"],"labels":{"+17855550000":"Wife"},"context_count":3}
        """.utf8))
        XCTAssertTrue(full.isAllowed(handle: "+17855550000", chatIdentifier: nil, chatGUID: nil))
        XCTAssertFalse(full.isAllowed(handle: "+19999999999", chatIdentifier: "+19999999999", chatGUID: nil))
        XCTAssertEqual(full.labels["+17855550000"], "Wife")
        XCTAssertEqual(full.contextCount, 3)
    }
}
