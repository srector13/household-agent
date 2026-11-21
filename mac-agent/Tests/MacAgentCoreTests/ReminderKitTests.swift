import XCTest
@testable import MacAgentCore

final class ReminderKitTests: XCTestCase {
    func decode(_ json: String) throws -> AgentCommand {
        try Wire.decoder().decode(AgentCommand.self, from: Data(json.utf8))
    }

    func giftCommand(section: String? = "Sarah", tags: [String] = ["Sarah"], fallback: String? = "Sarah · Kindle Paperwhite") -> AgentCommand {
        AgentCommand(commandId: "c1", eventId: "imessage:1", op: "create_reminder", payload: .createReminder(
            ReminderPayload(title: "Kindle Paperwhite", list: "🎁 Gift ideas", notes: "x\n[ha:imessage:1]", tag: "[ha:imessage:1]",
                            url: "https://example.com/k", section: section, tags: tags, titleFallback: fallback)))
    }

    // MARK: wire

    func testDecodeSectionTagsFallback() throws {
        let cmd = try decode("""
        {"command_id":"c1","op":"create_reminder","payload":{"title":"Kindle Paperwhite","list":"🎁 Gift ideas",
          "section":"Sarah","tags":["Sarah","gift"],"title_fallback":"Sarah · Kindle Paperwhite","tag":"[ha:x]"}}
        """)
        guard case .createReminder(let p) = cmd.payload else { return XCTFail("\(cmd.payload)") }
        XCTAssertEqual(p.section, "Sarah")
        XCTAssertEqual(p.tags, ["Sarah", "gift"])
        XCTAssertEqual(p.titleFallback, "Sarah · Kindle Paperwhite")
        XCTAssertTrue(p.wantsOrganization)
    }

    func testDecodeWithoutNewFieldsAndNulls() throws {
        let old = try decode(#"{"command_id":"c1","op":"create_reminder","payload":{"title":"Pick up eggs"}}"#)
        guard case .createReminder(let p) = old.payload else { return XCTFail() }
        XCTAssertNil(p.section)
        XCTAssertNil(p.tags)
        XCTAssertFalse(p.wantsOrganization)
        let nulls = try decode(#"{"command_id":"c1","op":"create_reminder","payload":{"title":"x","section":null,"tags":[],"title_fallback":null}}"#)
        guard case .createReminder(let q) = nulls.payload else { return XCTFail() }
        XCTAssertFalse(q.wantsOrganization)
        XCTAssertFalse(ReminderPayload(title: "x", section: "   ").wantsOrganization)
    }

    func testResultEncodesWarning() throws {
        let r = CommandResult(status: .done, appleItemId: "id", warning: "ReminderKit unavailable — used title fallback")
        let json = String(decoding: try Wire.encoder().encode(r), as: UTF8.self)
        XCTAssertTrue(json.contains(#""warning":"ReminderKit unavailable — used title fallback""#), json)
        let plain = String(decoding: try Wire.encoder().encode(CommandResult.done("id")), as: UTF8.self)
        XCTAssertTrue(plain.contains(#""warning":null"#), plain)
        XCTAssertEqual(try Wire.decoder().decode(CommandResult.self, from: Data(json.utf8)), r)
    }

    func testHeartbeatEncodesReminderKitFlag() throws {
        let never = Heartbeat(lastRowid: 1, fdaOk: true, remindersOk: true, calendarOk: true, uptimeS: 1, bufferedEvents: 0)
        XCTAssertTrue(String(decoding: try Wire.encoder().encode(never), as: UTF8.self).contains(#""reminderkit_ok":null"#))
        let ok = Heartbeat(lastRowid: 1, fdaOk: true, remindersOk: true, calendarOk: true, uptimeS: 1, bufferedEvents: 0,
                           reminderkitOk: true)
        let json = String(decoding: try Wire.encoder().encode(ok), as: UTF8.self)
        XCTAssertTrue(json.contains(#""reminderkit_ok":true"#), json)
        XCTAssertEqual(try Wire.decoder().decode(Heartbeat.self, from: Data(json.utf8)).reminderkitOk, true)
    }

    func testConfigUseReminderKit() throws {
        XCTAssertTrue(try JSONDecoder().decode(AgentConfig.self, from: Data(#"{"brain_url":"http://b"}"#.utf8)).useReminderKit)
        XCTAssertFalse(try JSONDecoder().decode(AgentConfig.self,
                                                from: Data(#"{"brain_url":"http://b","use_reminderkit":false}"#.utf8)).useReminderKit)
    }

    // MARK: executor

    func testAvailablePassesSectionAndTags() async throws {
        let store = FakeItemStore()
        let org = FakeOrganizer(available: true)
        let r = await CommandExecutor(store: store, organizer: org).execute(giftCommand())
        XCTAssertEqual(r.status, .done)
        XCTAssertNil(r.warning)
        let id = try XCTUnwrap(r.appleItemId)
        let calls = await org.calls
        XCTAssertEqual(calls, [FakeOrganizer.Call(list: "list:🎁 Gift ideas", reminder: id, section: "Sarah", tags: ["Sarah"])])
        let item = await store.items[id]
        XCTAssertEqual(item?.title, "Kindle Paperwhite")
        XCTAssertEqual(item?.url, "https://example.com/k")
    }

    func testUnavailableUsesFallbackTitleBeforeCreating() async throws {
        let store = FakeItemStore()
        let org = FakeOrganizer(available: false)
        let r = await CommandExecutor(store: store, organizer: org).execute(giftCommand())
        XCTAssertEqual(r.status, .done)
        XCTAssertEqual(r.warning, "ReminderKit unavailable — used title fallback")
        let item = await store.items[try XCTUnwrap(r.appleItemId)]
        XCTAssertEqual(item?.title, "Sarah · Kindle Paperwhite")
        let calls = await org.calls
        XCTAssertTrue(calls.isEmpty)
        let updates = await store.updateCount
        XCTAssertEqual(updates, 0, "created with the fallback title directly, not renamed")
    }

    func testApplyFailureRenamesToFallback() async throws {
        let store = FakeItemStore()
        let org = FakeOrganizer(available: true, failApply: true)
        let r = await CommandExecutor(store: store, organizer: org).execute(giftCommand())
        XCTAssertEqual(r.status, .done)
        XCTAssertTrue(r.warning?.contains("boom") == true, r.warning ?? "")
        let item = await store.items[try XCTUnwrap(r.appleItemId)]
        XCTAssertEqual(item?.title, "Sarah · Kindle Paperwhite")
    }

    func testNoFallbackTitleKeepsTitle() async throws {
        let store = FakeItemStore()
        let r = await CommandExecutor(store: store, organizer: FakeOrganizer(available: false))
            .execute(giftCommand(section: nil, tags: ["Sarah"], fallback: nil))
        XCTAssertEqual(r.status, .done)
        XCTAssertNotNil(r.warning)
        let item = await store.items[try XCTUnwrap(r.appleItemId)]
        XCTAssertEqual(item?.title, "Kindle Paperwhite")
    }

    func testPlainReminderDoesNotTouchOrganizer() async throws {
        let store = FakeItemStore()
        let org = FakeOrganizer(available: false)
        let r = await CommandExecutor(store: store, organizer: org).execute(giftCommand(section: nil, tags: []))
        XCTAssertNil(r.warning)
        let checks = await org.availabilityChecks
        XCTAssertEqual(checks, 0)
        let item = await store.items[try XCTUnwrap(r.appleItemId)]
        XCTAssertEqual(item?.title, "Kindle Paperwhite")
    }

    func testIdempotentRedeliveryDoesNotDuplicate() async throws {
        let store = FakeItemStore()
        let exec = CommandExecutor(store: store, organizer: FakeOrganizer(available: false))
        let a = await exec.execute(giftCommand())
        let b = await exec.execute(giftCommand())
        XCTAssertEqual(a.appleItemId, b.appleItemId)
        let creates = await store.createCount
        XCTAssertEqual(creates, 1)
    }

    func testDefaultExecutorHasNoOrganizer() async throws {
        let r = await CommandExecutor(store: FakeItemStore()).execute(giftCommand())
        XCTAssertEqual(r.warning, "ReminderKit unavailable — used title fallback")
    }

    // MARK: ReminderKitOrganizer over a fake backend

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testOrganizerCachesAvailabilityAndPropagatesErrors() async throws {
        let checks = Counter()
        let backend = ReminderKitBackend(
            check: { checks.bump(); return (true, "all good") },
            apply: { _, _, section, _ in section == "bad" ? "save failed: nope" : nil },
            read: { _, _ in ("Sarah", ["Sarah"], nil) })
        let org = ReminderKitOrganizer(backend: backend, timeout: 5)
        let before = await org.lastKnownAvailability()
        XCTAssertNil(before)
        let a = await org.isAvailable()
        let b = await org.isAvailable()
        XCTAssertTrue(a && b)
        XCTAssertEqual(checks.value, 1)
        let report = await org.report()
        XCTAssertEqual(report, "all good")
        try await org.apply(listIdentifier: "L", reminderIdentifier: "R", section: "Sarah", tags: ["Sarah"])
        do {
            try await org.apply(listIdentifier: "L", reminderIdentifier: "R", section: "bad", tags: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual("\(error)", "save failed: nope")
        }
        let back = await org.readBack(listIdentifier: "L", reminderIdentifier: "R")
        XCTAssertEqual(back.section, "Sarah")
    }

    func testOrganizerRetriesOnceWhenReminderNotVisibleYet() async throws {
        let attempts = Counter()
        let backend = ReminderKitBackend(
            check: { (true, "ok") },
            apply: { _, _, _, _ in attempts.bump(); return attempts.value == 1 ? "reminder not found in ReminderKit (nil)" : nil },
            read: { _, _ in (nil, [], nil) })
        let org = ReminderKitOrganizer(backend: backend, timeout: 5)
        org.retryDelayNs = 1_000_000
        try await org.apply(listIdentifier: "L", reminderIdentifier: "R", section: "S", tags: [])
        XCTAssertEqual(attempts.value, 2)
    }

    func testOrganizerTimeoutMarksUnavailable() async throws {
        let backend = ReminderKitBackend(
            check: { (true, "ok") },
            apply: { _, _, _, _ in Thread.sleep(forTimeInterval: 2); return nil },
            read: { _, _ in (nil, [], nil) })
        let org = ReminderKitOrganizer(backend: backend, timeout: 0.3)
        let ok = await org.isAvailable()
        XCTAssertTrue(ok)
        do {
            try await org.apply(listIdentifier: "L", reminderIdentifier: "R", section: "S", tags: [])
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("timed out"))
        }
        let after = await org.isAvailable()
        XCTAssertFalse(after)
        let known = await org.lastKnownAvailability()
        XCTAssertEqual(known, false)
    }

    func testUnavailableBackendCheck() async {
        let org = ReminderKitOrganizer(backend: ReminderKitBackend(
            check: { (false, "MISSING REMSaveRequest -saveSynchronouslyWithError:") },
            apply: { _, _, _, _ in "unavailable" }, read: { _, _ in (nil, [], "unavailable") }))
        let ok = await org.isAvailable()
        XCTAssertFalse(ok)
        XCTAssertNil(ReminderKitBackend.system, "no ReminderKit off-Mac")
        XCTAssertTrue(ReminderKitOrganizer.platformDefault() is NoReminderOrganizer)
    }

    func testAgentHeartbeatReportsOrganizer() async throws {
        let dir = tempDir()
        let config = AgentConfig(brainURL: "http://127.0.0.1:9", chatDBPath: dir.appendingPathComponent("none.db").path)
        let agent = Agent(config: config, client: BrainClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t"),
                          store: FakeItemStore(), organizer: FakeOrganizer(available: true),
                          stateURL: dir.appendingPathComponent("state.json"),
                          bufferURL: dir.appendingPathComponent("outbox.jsonl"),
                          syncedConfigURL: dir.appendingPathComponent("synced.json"))
        let before = await agent.makeHeartbeat()
        XCTAssertNil(before.reminderkitOk)
    }

    func testCrashMarkerDisablesReminderKitUntilCleared() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rk-\(UUID().uuidString)")
        let marker = dir.appendingPathComponent("reminderkit.inflight")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = CallCounter()
        let backend = ReminderKitBackend(
            check: { calls.increment(); return (true, "ok") },
            apply: { _, _, _, _ in
                // the marker exists while the private call runs
                return FileManager.default.fileExists(atPath: marker.path) ? nil : "marker missing during call"
            },
            read: { _, _ in (nil, [], nil) })

        // normal run: marker written during the call, removed afterwards
        let ok = ReminderKitOrganizer(backend: backend, timeout: 5, crashMarker: marker)
        let available = await ok.isAvailable()
        XCTAssertTrue(available)
        try await ok.apply(listIdentifier: "L", reminderIdentifier: "R", section: "Sarah", tags: ["Sarah"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // simulate a crash mid-call: marker left behind → next start keeps ReminderKit off without calling it
        _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
        let before = calls.value
        let afterCrash = ReminderKitOrganizer(backend: backend, timeout: 5, crashMarker: marker)
        let availableAfterCrash = await afterCrash.isAvailable()
        XCTAssertFalse(availableAfterCrash)
        XCTAssertEqual(calls.value, before)
        XCTAssertTrue(afterCrash.foundCrashMarker)

        // the probe ignores the marker and clears it on success
        let probe = ReminderKitOrganizer(backend: backend, timeout: 5, crashMarker: marker, honorCrashMarker: false)
        let probeAvailable = await probe.isAvailable()
        XCTAssertTrue(probeAvailable)
        probe.clearCrashMarker()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
