import Foundation
import XCTest
@testable import MacAgentCore

final class SnapshotTests: XCTestCase {
    func makeAgent(_ server: StubBrainServer, store: FakeItemStore, dir: URL) -> Agent {
        var cfg = AgentConfig(brainURL: server.baseURL.absoluteString, syncAllowlist: false)
        cfg.chatDBPath = dir.appendingPathComponent("missing-chat.db").path
        return Agent(config: cfg, client: BrainClient(baseURL: server.baseURL, token: "t"), store: store,
                     stateURL: dir.appendingPathComponent("state.json"),
                     bufferURL: dir.appendingPathComponent("outbox.jsonl"),
                     syncedConfigURL: dir.appendingPathComponent("synced.json"))
    }

    func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testWireShapeExplicitNullsSortAndCap() throws {
        var events = (0..<450).map { i in
            SnapshotEvent(id: "E\(i)", title: "Event \(i)", start: String(format: "2026-11-%02dT09:00:00-05:00", 1 + i % 28),
                          end: "2026-11-30T10:00:00-05:00", allDay: false, calendar: "Home")
        }
        events[0].calendarColor = "#FF2D55"
        let snap = CalendarSnapshot(parts: SnapshotParts(events: events, reminders: nil),
                                    generatedAt: "2026-11-22T08:00:00-05:00")
        XCTAssertEqual(snap.events?.count, CalendarSnapshot.maxItems)
        XCTAssertEqual(snap.events?.first?.start, "2026-11-01T09:00:00-05:00", "sorted by start")
        let obj = try json(try Wire.encoder().encode(snap))
        XCTAssertEqual(obj["generated_at"] as? String, "2026-11-22T08:00:00-05:00")
        XCTAssertEqual(obj["range_days"] as? Int, 7)
        XCTAssertTrue(obj["reminders"] is NSNull, "unreadable kind → explicit null")
        let e = try XCTUnwrap((obj["events"] as? [[String: Any]])?.first { $0["id"] as? String == "E1" })
        XCTAssertEqual(e["all_day"] as? Bool, false)
        XCTAssertTrue(e["calendar_color"] is NSNull)
        XCTAssertTrue(e["location"] is NSNull)
        XCTAssertEqual(e["ours"] as? Bool, false)
    }

    func testReminderWireShapeAndOurs() throws {
        let r = SnapshotReminder(id: "R1", title: "Milk", list: "Groceries", due: "2026-11-23",
                                 priority: 1, ours: CalendarSnapshot.isOurs(notes: "x\n[ha:abc]"))
        let snap = CalendarSnapshot(parts: SnapshotParts(events: [], reminders: [r]), generatedAt: "g")
        let obj = try json(try Wire.encoder().encode(snap))
        XCTAssertEqual((obj["events"] as? [Any])?.count, 0, "readable but empty stays an empty list")
        let row = try XCTUnwrap((obj["reminders"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["list"] as? String, "Groceries")
        XCTAssertTrue(row["list_color"] is NSNull)
        XCTAssertTrue(row["due_time"] is NSNull)
        XCTAssertEqual(row["due"] as? String, "2026-11-23")
        XCTAssertEqual(row["priority"] as? Int, 1)
        XCTAssertEqual(row["ours"] as? Bool, true)
        XCTAssertFalse(CalendarSnapshot.isOurs(notes: nil))
        XCTAssertEqual(HexColor.from(red: 1, green: 0.5, blue: 0), "#FF8000")
    }

    func testCalendarsCatalogAndUndatedReminders() throws {
        let dated = (0..<5).map { i in SnapshotReminder(id: "D\(i)", title: "Dated \(i)", list: "Household", due: "2026-11-2\(i)") }
        let undated = (0..<350).map { i in SnapshotReminder(id: "U\(i)", title: "Item \(i)", list: "Groceries") }
        let cals = [SnapshotCalendar(title: "Work", color: "#34C759", kind: .event, account: "Exchange"),
                    SnapshotCalendar(title: "Groceries", kind: .reminder),
                    SnapshotCalendar(title: "Family", color: "#FF9500", kind: .event, account: "iCloud")]
        let snap = CalendarSnapshot(parts: SnapshotParts(events: [], reminders: undated + dated, calendars: cals),
                                    generatedAt: "g")
        XCTAssertEqual(snap.reminders?.count, 5 + CalendarSnapshot.maxUndated, "undated capped separately")
        XCTAssertEqual(snap.reminders?.first?.id, "D0", "dated first, by due")
        XCTAssertEqual(snap.calendars?.map(\.title), ["Family", "Work", "Groceries"])
        let obj = try json(try Wire.encoder().encode(snap))
        let rows = try XCTUnwrap(obj["calendars"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["kind"] as? String, "event")
        XCTAssertEqual(rows.first?["account"] as? String, "iCloud")
        XCTAssertTrue(rows.last?["color"] is NSNull)
        let last = try XCTUnwrap((obj["reminders"] as? [[String: Any]])?.last)
        XCTAssertTrue(last["due"] is NSNull)
    }

    func testUnreadableCatalogIsExplicitNull() throws {
        let snap = CalendarSnapshot(parts: SnapshotParts(events: [], reminders: []), generatedAt: "g")
        let obj = try json(try Wire.encoder().encode(snap))
        XCTAssertTrue(obj["calendars"] is NSNull)
        XCTAssertFalse(SnapshotParts(calendars: []).isEmpty)
    }

    func testPostedAfterCompletionSync() async throws {
        let server = try StubBrainServer { _, path, _ in
            if path.hasPrefix("/api/agent/tracked") { return (200, #"{"interval_s": 300, "items": []}"#) }
            return (200, "{}")
        }
        defer { server.stop() }
        let store = FakeItemStore()
        await store.setSnapshot(SnapshotParts(events: [], reminders: [
            SnapshotReminder(id: "R1", title: "Milk", list: "Groceries", due: "2026-11-23")]))
        let agent = makeAgent(server, store: store, dir: tempDir())
        _ = await agent.syncItemStatus()
        let posts = server.requests.filter { $0.path == "/api/agent/snapshot" }
        XCTAssertEqual(posts.count, 1)
        let body = try json(try XCTUnwrap(posts.first?.body))
        XCTAssertEqual((body["reminders"] as? [[String: Any]])?.first?["title"] as? String, "Milk")
        XCTAssertEqual(server.requests.last?.method, "POST")
    }

    func testNothingReadableIsNotPosted() async throws {
        let server = try StubBrainServer { _, _, _ in (200, "{}") }
        defer { server.stop() }
        let agent = makeAgent(server, store: FakeItemStore(), dir: tempDir())
        let r = await agent.postSnapshot()
        XCTAssertEqual(r, .skipped)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testOlderBrain404DisablesSnapshot() async throws {
        let server = try StubBrainServer { _, _, _ in (404, #"{"detail":"Not Found"}"#) }
        defer { server.stop() }
        let store = FakeItemStore()
        await store.setSnapshot(SnapshotParts(events: [], reminders: nil))
        let agent = makeAgent(server, store: store, dir: tempDir())
        let r1 = await agent.postSnapshot()
        XCTAssertEqual(r1, .disabled)
        let r2 = await agent.postSnapshot()
        XCTAssertEqual(r2, .disabled)
        XCTAssertEqual(server.requests.count, 1)
        let off = await agent.snapshotPostingDisabled
        XCTAssertTrue(off)
    }

    func testServerErrorIsRetriedNextTime() async throws {
        let server = try StubBrainServer { _, _, _ in (500, "boom") }
        defer { server.stop() }
        let store = FakeItemStore()
        await store.setSnapshot(SnapshotParts(events: [], reminders: []))
        let agent = makeAgent(server, store: store, dir: tempDir())
        if case .failed = await agent.postSnapshot() {} else { XCTFail("expected failure") }
        if case .failed = await agent.postSnapshot() {} else { XCTFail("expected failure") }
        XCTAssertEqual(server.requests.count, 2, "5xx doesn't disable")
    }
}
