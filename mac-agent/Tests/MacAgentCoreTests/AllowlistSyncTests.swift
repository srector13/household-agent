import XCTest
@testable import MacAgentCore

/// Brain-synced allowlist: normalization, wire decoding, and the send-time filter in Agent.flush.
final class AllowlistSyncTests: XCTestCase {
    let wife = "+17855550000"
    let other = "+19995550000"

    // MARK: Normalization (must match brain/app/gate.py normalize_handle)

    func testHandleNormalization() {
        XCTAssertEqual(HandleNormalizer.normalize("(785) 555-0000"), "+17855550000")
        XCTAssertEqual(HandleNormalizer.normalize("+1 785 555 0000"), "+17855550000")
        XCTAssertEqual(HandleNormalizer.normalize("7855550000"), "+17855550000")
        XCTAssertEqual(HandleNormalizer.normalize("+447700900123"), "+447700900123")
        XCTAssertEqual(HandleNormalizer.normalize("Her@Example.COM"), "her@example.com")
        XCTAssertEqual(HandleNormalizer.normalize("Wife <Her@Example.com>"), "her@example.com")
        XCTAssertEqual(HandleNormalizer.normalize("  "), "")
        XCTAssertEqual(HandleNormalizer.normalize(nil), "")
        XCTAssertEqual(HandleNormalizer.normalize("abc"), "abc")
    }

    func testAllowsMatchesNormalizedHandlesAndChats() {
        let list = SyncedAllowlist(settingsVersion: 3, handles: ["(785) 555-0000", "Her@Example.com"],
                                   chatIds: ["iMessage;+;chat123456"])
        XCTAssertEqual(list.handles, ["+17855550000", "her@example.com"])
        XCTAssertTrue(list.allows(handle: "7855550000", chatIdentifier: nil, chatGUID: nil))
        XCTAssertTrue(list.allows(handle: "HER@example.com", chatIdentifier: nil, chatGUID: nil))
        XCTAssertTrue(list.allows(handle: other, chatIdentifier: "chat123456", chatGUID: "iMessage;+;chat123456"))
        XCTAssertFalse(list.allows(handle: other, chatIdentifier: "chat999", chatGUID: "iMessage;+;chat999"))
        XCTAssertEqual(list.size, 3)
    }

    // MARK: Wire decoding

    func testRemoteConfigDecoding() throws {
        let json = #"{"settings_version": 7, "allow": {"handles": ["+17855550000", "someone@icloud.com"], "chat_ids": ["iMessage;+;chat123456"]}, "allow_self_notes": false, "extra": 1}"#
        let cfg = try Wire.decoder().decode(RemoteAgentConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.settingsVersion, 7)
        XCTAssertEqual(cfg.allow.handles, ["+17855550000", "someone@icloud.com"])
        XCTAssertEqual(cfg.allow.chatIds, ["iMessage;+;chat123456"])
        XCTAssertEqual(cfg.allowSelfNotes, false)
        let sparse = try Wire.decoder().decode(RemoteAgentConfig.self,
                                               from: Data(#"{"settings_version": 1, "allow": {}}"#.utf8))
        XCTAssertEqual(sparse.allow.handles, [])
        XCTAssertNil(sparse.allowSelfNotes)
    }

    func testHeartbeatAckDecoding() throws {
        let ack = try Wire.decoder().decode(HeartbeatAck.self, from: Data(#"{"ok": true, "settings_version": 7}"#.utf8))
        XCTAssertEqual(ack.settingsVersion, 7)
        let old = try Wire.decoder().decode(HeartbeatAck.self, from: Data(#"{"ok": true}"#.utf8))
        XCTAssertNil(old.settingsVersion)
    }

    func testHeartbeatEncodesAllowlistFields() throws {
        let hb = Heartbeat(lastRowid: 5, fdaOk: true, remindersOk: true, calendarOk: true, uptimeS: 1,
                           bufferedEvents: 0, allowlistVersion: nil, allowlistSize: 0)
        let obj = try JSONSerialization.jsonObject(with: Wire.encoder().encode(hb)) as! [String: Any]
        XCTAssertTrue(obj["allowlist_version"] is NSNull, "unsynced version is sent as explicit null")
        XCTAssertEqual(obj["allowlist_size"] as? Int, 0)
        let hb2 = Heartbeat(lastRowid: 5, fdaOk: true, remindersOk: true, calendarOk: true, uptimeS: 1,
                            bufferedEvents: 0, allowlistVersion: 7, allowlistSize: 2)
        let back = try Wire.decoder().decode(Heartbeat.self, from: Wire.encoder().encode(hb2))
        XCTAssertEqual(back, hb2)
    }

    func testConfigDecodingSyncAllowlist() throws {
        let dflt = try JSONDecoder().decode(AgentConfig.self, from: Data(#"{"brain_url": "http://b"}"#.utf8))
        XCTAssertTrue(dflt.syncAllowlist)
        let off = try JSONDecoder().decode(AgentConfig.self, from: Data(#"{"brain_url": "http://b", "sync_allowlist": false, "allow_handles": ["+1"]}"#.utf8))
        XCTAssertFalse(off.syncAllowlist)
        XCTAssertEqual(off.allowHandles, ["+1"])
    }

    func testSyncedAllowlistPersistence() throws {
        let url = tempDir().appendingPathComponent("synced_config.json")
        XCTAssertNil(SyncedAllowlist.load(from: url))
        let list = SyncedAllowlist(settingsVersion: 4, handles: [wife], chatIds: ["c"], allowSelfNotes: true)
        try list.save(to: url)
        XCTAssertEqual(SyncedAllowlist.load(from: url), list)
    }

    // MARK: Agent send-time filter

    func makeAgent(dir: URL, chatDB: URL) -> Agent {
        var cfg = AgentConfig(brainURL: "http://127.0.0.1:9", syncAllowlist: true, labels: [wife: "Wife"])
        cfg.chatDBPath = chatDB.path
        return Agent(config: cfg, client: BrainClient(baseURL: URL(string: cfg.brainURL)!, token: "t"),
                     store: FakeItemStore(),
                     stateURL: dir.appendingPathComponent("state.json"),
                     bufferURL: dir.appendingPathComponent("outbox.jsonl"),
                     syncedConfigURL: dir.appendingPathComponent("synced_config.json"))
    }

    func remote(_ version: Int, handles: [String], chats: [String] = []) -> RemoteAgentConfig {
        RemoteAgentConfig(settingsVersion: version, allow: .init(handles: handles, chatIds: chats))
    }

    func testHoldsUntilSyncedThenDropsNonAllowedAndSendsAllowed() async throws {
        let dir = tempDir()
        let f = try FixtureChatDB(dir: dir)
        let hw = try f.addHandle(wife), ho = try f.addHandle(other)
        let cw = try f.addChat(guid: "iMessage;-;\(wife)", identifier: wife)
        let co = try f.addChat(guid: "iMessage;-;\(other)", identifier: other)
        let agent = makeAgent(dir: dir, chatDB: f.url)
        _ = await agent.scan() // first run: checkpoint at max ROWID

        let o = try f.addMessage(chat: co, handle: ho, text: "private to someone else")
        let w = try f.addMessage(chat: cw, handle: hw, text: "grab eggs tomorrow?")
        let queued = await agent.scan()
        XCTAssertEqual(queued, 2, "never synced: everything is buffered (held), nothing dropped")

        // Never synced → hold: nothing sent, nothing dropped, checkpoint stays put.
        let held = await agent.flush()
        XCTAssertTrue(held)
        XCTAssertEqual(OfflineBuffer(url: dir.appendingPathComponent("outbox.jsonl")).count, 2)
        XCTAssertEqual(Checkpoint(url: dir.appendingPathComponent("state.json")).lastRowid, o - 1)
        let hb0 = await agent.makeHeartbeat()
        XCTAssertNil(hb0.allowlistVersion)
        XCTAssertEqual(hb0.allowlistSize, 0)

        // Synced: the non-allowlisted head is dropped (checkpoint advances past it); wife's event is
        // attempted (brain is down → stays buffered).
        await agent.applyRemoteConfig(remote(7, handles: ["7855550000"]))
        let flushed = await agent.flush()
        XCTAssertFalse(flushed, "brain unreachable for the allowed event")
        let buf = OfflineBuffer(url: dir.appendingPathComponent("outbox.jsonl"))
        XCTAssertEqual(buf.items.map(\.event.eventId), ["imessage:\(w)"])
        XCTAssertEqual(buf.items.first?.chatIdentifier, wife)
        XCTAssertEqual(Checkpoint(url: dir.appendingPathComponent("state.json")).lastRowid, w - 1)

        let hb = await agent.makeHeartbeat()
        XCTAssertEqual(hb.allowlistVersion, 7)
        XCTAssertEqual(hb.allowlistSize, 1)

        // Scan-time filtering now applies too: a new non-allowlisted message is never buffered.
        let o2 = try f.addMessage(chat: co, handle: ho, text: "another private one")
        let n = await agent.scan()
        XCTAssertEqual(n, 0)
        XCTAssertGreaterThan(o2, w)

        // Cached list survives a restart.
        let restarted = makeAgent(dir: dir, chatDB: f.url)
        let hb2 = await restarted.makeHeartbeat()
        XCTAssertEqual(hb2.allowlistVersion, 7)
    }

    func testListShrinkDropsAlreadyBufferedEvents() async throws {
        let dir = tempDir()
        let f = try FixtureChatDB(dir: dir)
        let hw = try f.addHandle(wife)
        let cw = try f.addChat(guid: "iMessage;-;\(wife)", identifier: wife)
        let agent = makeAgent(dir: dir, chatDB: f.url)
        await agent.applyRemoteConfig(remote(1, handles: [wife]))
        _ = await agent.scan()
        let w = try f.addMessage(chat: cw, handle: hw, text: "grab eggs")
        let queued = await agent.scan()
        XCTAssertEqual(queued, 1)
        // Removed from the allowlist in the dashboard before delivery → dropped at send time.
        await agent.applyRemoteConfig(remote(2, handles: []))
        let ok = await agent.flush()
        XCTAssertTrue(ok)
        XCTAssertEqual(OfflineBuffer(url: dir.appendingPathComponent("outbox.jsonl")).count, 0)
        XCTAssertEqual(Checkpoint(url: dir.appendingPathComponent("state.json")).lastRowid, w)
    }

    func testGroupChatMatchesOnChatId() async throws {
        let dir = tempDir()
        let f = try FixtureChatDB(dir: dir)
        let ho = try f.addHandle(other)
        let guid = "iMessage;+;chat123456"
        let group = try f.addChat(guid: guid, identifier: "chat123456", style: 43)
        let agent = makeAgent(dir: dir, chatDB: f.url)
        await agent.applyRemoteConfig(remote(3, handles: [], chats: [guid]))
        _ = await agent.scan()
        let m = try f.addMessage(chat: group, handle: ho, text: "family dinner sunday at 6")
        let queued = await agent.scan()
        XCTAssertEqual(queued, 1, "group chat on the allowlist is buffered even though the sender is not")
        let flushed = await agent.flush()
        XCTAssertFalse(flushed, "attempted delivery (brain down), not dropped")
        let buf = OfflineBuffer(url: dir.appendingPathComponent("outbox.jsonl"))
        XCTAssertEqual(buf.items.map(\.event.eventId), ["imessage:\(m)"])
        XCTAssertEqual(buf.items.first?.event.chatId, guid)
    }

    func testSyncOffIgnoresSyncedList() async throws {
        let dir = tempDir()
        try SyncedAllowlist(settingsVersion: 9, handles: [], chatIds: []).save(to: dir.appendingPathComponent("synced_config.json"))
        let f = try FixtureChatDB(dir: dir)
        var cfg = AgentConfig(brainURL: "http://127.0.0.1:9", syncAllowlist: false, allowHandles: [wife])
        cfg.chatDBPath = f.url.path
        let agent = Agent(config: cfg, client: BrainClient(baseURL: URL(string: cfg.brainURL)!, token: "t"),
                          store: FakeItemStore(), stateURL: dir.appendingPathComponent("state.json"),
                          bufferURL: dir.appendingPathComponent("outbox.jsonl"),
                          syncedConfigURL: dir.appendingPathComponent("synced_config.json"))
        let hw = try f.addHandle(wife)
        let cw = try f.addChat(guid: "iMessage;-;\(wife)", identifier: wife)
        _ = await agent.scan()
        try f.addMessage(chat: cw, handle: hw, text: "grab eggs")
        let n = await agent.scan()
        XCTAssertEqual(n, 1)
        let hb = await agent.makeHeartbeat()
        XCTAssertNil(hb.allowlistVersion)
        XCTAssertEqual(hb.allowlistSize, 1)
    }

    func testOldOutboxLinesWithoutChatIdentifierStillLoad() throws {
        let url = tempDir().appendingPathComponent("outbox.jsonl")
        let line = #"{"rowid": 3, "event": {"event_id": "imessage:3", "source": "imessage", "sender_handle": "+17855550000", "is_from_me": false, "received_at": "2026-11-20T10:00:00-06:00", "text": "hi", "recent_context": []}}"#
        try Data((line + "\n").utf8).write(to: url)
        let buf = OfflineBuffer(url: url)
        XCTAssertEqual(buf.count, 1)
        XCTAssertNil(buf.first?.chatIdentifier)
    }
}
