import XCTest
@testable import MacAgentCore

final class ItemStatusTests: XCTestCase {

    // MARK: Wire format

    func testTrackedDecoding() throws {
        let json = """
        {"items": [{"apple_item_id": "A1", "kind": "reminder", "tag": "[ha:imessage:1]"},
                   {"apple_item_id": "E1", "kind": "event"}], "interval_s": 120}
        """
        let t = try Wire.decoder().decode(TrackedList.self, from: Data(json.utf8))
        XCTAssertEqual(t.items, [TrackedItem(appleItemId: "A1", kind: .reminder, tag: "[ha:imessage:1]"),
                                 TrackedItem(appleItemId: "E1", kind: .event, tag: nil)])
        XCTAssertEqual(t.intervalS, 120)
        let bare = try Wire.decoder().decode(TrackedList.self, from: Data(#"{"items": []}"#.utf8))
        XCTAssertNil(bare.intervalS)
    }

    func testReportEncodesExplicitNullsAndOptionalFoundId() throws {
        let r = ItemStatusReport(appleItemId: "A1", kind: .reminder, exists: false)
        let obj = try JSONSerialization.jsonObject(with: Wire.encoder().encode(r)) as! [String: Any]
        XCTAssertEqual(obj["apple_item_id"] as? String, "A1")
        XCTAssertEqual(obj["exists"] as? Bool, false)
        for key in ["completed", "completed_at", "title", "due", "due_time", "start", "end"] {
            XCTAssertTrue(obj[key] is NSNull, "\(key) should be an explicit null")
        }
        XCTAssertNil(obj["found_id"])
        let moved = ItemStatusReport(appleItemId: "A1", kind: .reminder, exists: true,
                                     snapshot: ItemSnapshot(completed: false, title: "x"), foundId: "A2")
        let obj2 = try JSONSerialization.jsonObject(with: Wire.encoder().encode(moved)) as! [String: Any]
        XCTAssertEqual(obj2["found_id"] as? String, "A2")
    }

    func testEventReportsHaveNoReminderFields() {
        let snap = ItemSnapshot(completed: true, completedAt: "x", title: "Dentist", due: "2026-01-01",
                                start: "2026-11-24T15:30:00-06:00", end: "2026-11-24T16:30:00-06:00")
        let r = ItemStatusReport(appleItemId: "E1", kind: .event, exists: true, snapshot: snap)
        XCTAssertNil(r.completed)
        XCTAssertNil(r.completedAt)
        XCTAssertNil(r.due)
        XCTAssertEqual(r.start, "2026-11-24T15:30:00-06:00")
    }

    // MARK: Building reports

    func reminder(_ title: String, tag: String, due: String? = nil, time: String? = nil,
                  completed: Bool = false, at: String? = nil) -> FakeItemStore.Item {
        FakeItemStore.Item(kind: .reminder, title: title, notes: "From Sarah\n\(tag)", due: due, dueTime: time,
                           completed: completed, completedAt: at)
    }

    func testCompletedAndEditedReminders() async {
        let store = FakeItemStore()
        await store.set("A1", reminder("Pick up eggs", tag: "[ha:1]", completed: true, at: "2026-11-21T09:12:00-06:00"))
        await store.set("A2", reminder("Call plumber", tag: "[ha:2]", due: "2026-11-23", time: "09:00"))
        let reports = await ItemStatusChecker(store: store).reports(for: [
            TrackedItem(appleItemId: "A1", kind: .reminder, tag: "[ha:1]"),
            TrackedItem(appleItemId: "A2", kind: .reminder, tag: "[ha:2]"),
        ])
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].completed, true)
        XCTAssertEqual(reports[0].completedAt, "2026-11-21T09:12:00-06:00")
        XCTAssertEqual(reports[1].completed, false)
        XCTAssertEqual(reports[1].due, "2026-11-23")
        XCTAssertEqual(reports[1].dueTime, "09:00")
        XCTAssertTrue(reports.allSatisfy { $0.exists && $0.foundId == nil })
    }

    func testDeletedItemReportedMissingOnlyWhenPermitted() async {
        let store = FakeItemStore()
        let tracked = [TrackedItem(appleItemId: "GONE", kind: .reminder, tag: "[ha:9]")]
        var reports = await ItemStatusChecker(store: store).reports(for: tracked)
        XCTAssertEqual(reports, [ItemStatusReport(appleItemId: "GONE", kind: .reminder, exists: false)])

        // No Reminders access → can't tell → say nothing.
        await store.setAccess(reminders: false, calendar: true)
        reports = await ItemStatusChecker(store: store).reports(for: tracked)
        XCTAssertEqual(reports, [])
    }

    func testStoreErrorsAreNeverReportedAsMissing() async {
        let store = FakeItemStore()
        await store.markUnknown("A1")
        await store.setFindFails(true)
        let reports = await ItemStatusChecker(store: store).reports(for: [
            TrackedItem(appleItemId: "A1", kind: .reminder, tag: "[ha:1]"),   // lookup error
            TrackedItem(appleItemId: "A2", kind: .reminder, tag: "[ha:2]"),   // not found, tag search fails
        ])
        XCTAssertEqual(reports, [])
    }

    func testTagFallbackReportsFoundId() async {
        let store = FakeItemStore()
        await store.set("NEW", reminder("Pick up eggs", tag: "[ha:1]", completed: true))
        let reports = await ItemStatusChecker(store: store).reports(for: [
            TrackedItem(appleItemId: "OLD", kind: .reminder, tag: "[ha:1]"),
        ])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].appleItemId, "OLD")
        XCTAssertEqual(reports[0].foundId, "NEW")
        XCTAssertTrue(reports[0].exists)
        XCTAssertEqual(reports[0].completed, true)
    }

    func testCalendarPermissionIsPerKind() async {
        let store = FakeItemStore()
        await store.set("E1", FakeItemStore.Item(kind: .event, title: "Dentist", notes: "[ha:3]",
                                                 start: "2026-11-24T15:30:00-06:00", end: "2026-11-24T16:30:00-06:00"))
        await store.setAccess(reminders: true, calendar: false)
        let tracked = [TrackedItem(appleItemId: "E1", kind: .event, tag: "[ha:3]"),
                       TrackedItem(appleItemId: "R-GONE", kind: .reminder, tag: nil)]
        let reports = await ItemStatusChecker(store: store).reports(for: tracked)
        XCTAssertEqual(reports.map(\.appleItemId), ["R-GONE"])
    }

    // MARK: Schedule

    func testIntervalClamp() {
        XCTAssertEqual(StatusSyncSchedule.clamp(nil), 300)
        XCTAssertEqual(StatusSyncSchedule.clamp(5), 60)
        XCTAssertEqual(StatusSyncSchedule.clamp(120), 120)
        XCTAssertEqual(StatusSyncSchedule.clamp(99_999), 3600)
    }

    func testScheduleTimingAndDebounce() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = StatusSyncSchedule(start: t0)
        XCTAssertEqual(s.nextRun, t0.addingTimeInterval(30), "first sync ~30 s after start")
        s.setInterval(120)
        s.noteSynced(at: t0.addingTimeInterval(30))
        XCTAssertEqual(s.nextRun, t0.addingTimeInterval(150))

        // A command at t+40 → sync at t+45; another at t+43 pushes it to t+48 (trailing debounce).
        s.noteCommand(at: t0.addingTimeInterval(40))
        XCTAssertEqual(s.nextRun, t0.addingTimeInterval(45))
        s.noteCommand(at: t0.addingTimeInterval(43))
        XCTAssertEqual(s.nextRun, t0.addingTimeInterval(48))
        // …but a steady stream can't postpone it beyond 30 s after the first command.
        s.noteCommand(at: t0.addingTimeInterval(68))
        XCTAssertEqual(s.nextRun, t0.addingTimeInterval(70))
        s.noteSynced(at: t0.addingTimeInterval(70))
        XCTAssertEqual(s.nextRun, t0.addingTimeInterval(190))

        s.disable()
        XCTAssertNil(s.nextRun)
    }

    // MARK: Agent ↔ brain (stub HTTP server)

    func makeAgent(_ server: StubBrainServer, store: FakeItemStore, dir: URL) -> Agent {
        var cfg = AgentConfig(brainURL: server.baseURL.absoluteString, syncAllowlist: false)
        cfg.chatDBPath = dir.appendingPathComponent("missing-chat.db").path
        return Agent(config: cfg, client: BrainClient(baseURL: server.baseURL, token: "t"), store: store,
                     stateURL: dir.appendingPathComponent("state.json"),
                     bufferURL: dir.appendingPathComponent("outbox.jsonl"),
                     syncedConfigURL: dir.appendingPathComponent("synced.json"))
    }

    func testOlderBrain404DisablesSync() async throws {
        let server = try StubBrainServer { _, _, _ in (404, #"{"detail":"Not Found"}"#) }
        defer { server.stop() }
        let agent = makeAgent(server, store: FakeItemStore(), dir: tempDir())
        let r1 = await agent.syncItemStatus()
        XCTAssertEqual(r1, .disabled)
        let disabled = await agent.statusSyncDisabled
        XCTAssertTrue(disabled)
        let next = await agent.nextStatusSync
        XCTAssertNil(next)
        let r2 = await agent.syncItemStatus()
        XCTAssertEqual(r2, .disabled)
        XCTAssertEqual(server.requests.count, 1, "no further calls once disabled")
    }

    func testFullRoundTripInBatches() async throws {
        let store = FakeItemStore()
        var tracked: [[String: Any]] = []
        for i in 0..<450 {
            await store.set("A\(i)", reminder("Item \(i)", tag: "[ha:\(i)]", completed: i % 2 == 0))
            tracked.append(["apple_item_id": "A\(i)", "kind": "reminder", "tag": "[ha:\(i)]"])
        }
        tracked.append(["apple_item_id": "GONE", "kind": "reminder", "tag": "[ha:gone]"])
        let trackedJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["items": tracked, "interval_s": 90]),
                                 as: UTF8.self)
        let server = try StubBrainServer { method, path, _ in
            if method == "GET" && path == "/api/agent/tracked" { return (200, trackedJSON) }
            if method == "POST" && path == "/api/agent/item-status" { return (200, #"{"ok": true, "updated": 1}"#) }
            return (404, "{}")
        }
        defer { server.stop() }
        let agent = makeAgent(server, store: store, dir: tempDir())
        let result = await agent.syncItemStatus()
        XCTAssertEqual(result, .synced(tracked: 451, reported: 451))
        let interval = await agent.statusSyncInterval
        XCTAssertEqual(interval, 90)
        let refreshed = await store.refreshCount
        XCTAssertEqual(refreshed, 1)

        let posts = server.requests.filter { $0.path == "/api/agent/item-status" }
        XCTAssertEqual(posts.count, 3, "451 reports → batches of 200, 200, 51")
        var all: [[String: Any]] = []
        for p in posts {
            let obj = try JSONSerialization.jsonObject(with: p.body) as! [String: Any]
            let items = obj["items"] as! [[String: Any]]
            XCTAssertLessThanOrEqual(items.count, 200)
            all += items
        }
        XCTAssertEqual(all.count, 451)
        XCTAssertEqual(all.first { $0["apple_item_id"] as? String == "GONE" }?["exists"] as? Bool, false)
        XCTAssertEqual(all.first { $0["apple_item_id"] as? String == "A0" }?["completed"] as? Bool, true)
    }

    func testCommandsTriggerDebouncedSync() async throws {
        let server = try StubBrainServer { _, _, _ in (200, #"{"items": [], "interval_s": 3600}"#) }
        defer { server.stop() }
        let agent = makeAgent(server, store: FakeItemStore(), dir: tempDir())
        _ = await agent.syncItemStatus()
        let periodic = await agent.nextStatusSync!
        XCTAssertGreaterThan(periodic.timeIntervalSinceNow, 3000)
        let now = Date()
        await agent.noteCommandsExecuted(at: now)
        let next = await agent.nextStatusSync!
        XCTAssertEqual(next.timeIntervalSince(now), StatusSyncSchedule.debounce, accuracy: 0.001)
    }

    func testNetworkErrorKeepsSyncEnabled() async {
        let cfgDir = tempDir()
        var cfg = AgentConfig(brainURL: "http://127.0.0.1:9", syncAllowlist: false)
        cfg.chatDBPath = cfgDir.appendingPathComponent("x.db").path
        let agent = Agent(config: cfg, client: BrainClient(baseURL: URL(string: cfg.brainURL)!, token: "t"),
                          store: FakeItemStore(), stateURL: cfgDir.appendingPathComponent("s.json"),
                          bufferURL: cfgDir.appendingPathComponent("o.jsonl"),
                          syncedConfigURL: cfgDir.appendingPathComponent("c.json"))
        let r = await agent.syncItemStatus()
        if case .failed = r {} else { XCTFail("expected .failed, got \(r)") }
        let disabled = await agent.statusSyncDisabled
        XCTAssertFalse(disabled)
        let next = await agent.nextStatusSync
        XCTAssertNotNil(next)
    }
}
