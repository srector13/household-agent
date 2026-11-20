import XCTest
@testable import MacAgentCore

/// Agent-level behaviour that does not need a live brain: first-run checkpointing, buffering while
/// the brain is down, and checkpoint advance over skipped rows.
final class AgentTests: XCTestCase {
    let wife = "+17855550000"

    func makeAgent(dir: URL, chatDB: URL, backfill: Int? = nil) -> Agent {
        var cfg = AgentConfig(brainURL: "http://127.0.0.1:9", allowHandles: [wife], labels: [wife: "Wife"])
        cfg.chatDBPath = chatDB.path
        // Port 9 (discard) on localhost: connection refused → "brain unreachable".
        let client = BrainClient(baseURL: URL(string: cfg.brainURL)!, token: "t")
        return Agent(config: cfg, client: client, store: FakeItemStore(),
                     stateURL: dir.appendingPathComponent("state.json"),
                     bufferURL: dir.appendingPathComponent("outbox.jsonl"), backfill: backfill)
    }

    func testFirstRunSkipsHistoryThenBuffersWhileBrainDown() async throws {
        let dir = tempDir()
        let f = try FixtureChatDB(dir: dir)
        let h = try f.addHandle(wife)
        let chat = try f.addChat(guid: "iMessage;-;\(wife)", identifier: wife)
        try f.addMessage(chat: chat, handle: h, text: "old history message")

        let agent = makeAgent(dir: dir, chatDB: f.url)
        let none = await agent.scan()
        XCTAssertEqual(none, 0, "first run must not backfill")

        let eggs = try f.addMessage(chat: chat, handle: h, text: "grab eggs tomorrow?")
        let queued = await agent.scan()
        XCTAssertEqual(queued, 1)
        let flushed = await agent.flush()
        XCTAssertFalse(flushed, "brain is unreachable")

        let buffer = OfflineBuffer(url: dir.appendingPathComponent("outbox.jsonl"))
        XCTAssertEqual(buffer.items.map(\.event.eventId), ["imessage:\(eggs)"])
        XCTAssertEqual(buffer.items.first?.event.recentContext, ["Wife: old history message"])
        let cp = Checkpoint(url: dir.appendingPathComponent("state.json"))
        XCTAssertEqual(cp.lastRowid, eggs - 1, "acked checkpoint must not advance without a 2xx")
        XCTAssertEqual(cp.scanPosition, eggs)

        let hb = await agent.makeHeartbeat()
        XCTAssertEqual(hb.bufferedEvents, 1)
        XCTAssertTrue(hb.fdaOk)
        XCTAssertEqual(hb.lastRowid, eggs - 1)

        // A restarted agent picks the buffer back up and does not re-read the row.
        let restarted = makeAgent(dir: dir, chatDB: f.url)
        let again = await restarted.scan()
        XCTAssertEqual(again, 0)
        let hb2 = await restarted.makeHeartbeat()
        XCTAssertEqual(hb2.bufferedEvents, 1)
    }

    func testSkippedRowsAdvanceAckedCheckpoint() async throws {
        let dir = tempDir()
        let f = try FixtureChatDB(dir: dir)
        let other = try f.addHandle("+19995550000")
        let chat = try f.addChat(guid: "iMessage;-;+19995550000", identifier: "+19995550000")
        let agent = makeAgent(dir: dir, chatDB: f.url)
        _ = await agent.scan()
        let last = try f.addMessage(chat: chat, handle: other, text: "not allowlisted")
        _ = await agent.scan()
        let cp = Checkpoint(url: dir.appendingPathComponent("state.json"))
        XCTAssertEqual(cp.lastRowid, last)
    }

    func testBackfill() async throws {
        let dir = tempDir()
        let f = try FixtureChatDB(dir: dir)
        let h = try f.addHandle(wife)
        let chat = try f.addChat(guid: "iMessage;-;\(wife)", identifier: wife)
        for i in 0..<5 { try f.addMessage(chat: chat, handle: h, text: "m\(i)") }
        let agent = makeAgent(dir: dir, chatDB: f.url, backfill: 2)
        let n = await agent.scan()
        XCTAssertEqual(n, 2)
    }

    func testMissingChatDBReportsNoFDA() async {
        let dir = tempDir()
        let agent = makeAgent(dir: dir, chatDB: dir.appendingPathComponent("missing.db"))
        let n = await agent.scan()
        XCTAssertEqual(n, 0)
        let hb = await agent.makeHeartbeat()
        XCTAssertFalse(hb.fdaOk)
    }

    func testWakeupCoalescesAndTimesOut() async {
        let w = Wakeup()
        await w.signal()
        await w.signal()
        let t0 = Date()
        await w.wait(timeout: 5) // pending signal → immediate
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        let t1 = Date()
        await w.wait(timeout: 0.2) // second signal was coalesced → times out
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t1), 0.15)
        Task { await sleepSeconds(0.1); await w.signal() }
        let t2 = Date()
        await w.wait(timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(t2), 2)
    }

    func testBackoff() {
        var b = Backoff(base: 1, cap: 5)
        XCTAssertEqual([b.next(), b.next(), b.next(), b.next(), b.next()], [1, 2, 4, 5, 5])
        b.reset()
        XCTAssertEqual(b.next(), 1)
    }
}
