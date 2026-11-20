import XCTest
@testable import MacAgentCore

final class PersistenceTests: XCTestCase {
    func event(_ n: Int) -> InboundEvent {
        InboundEvent(eventId: "imessage:\(n)", senderHandle: "+1", senderLabel: nil, chatId: nil, isFromMe: false,
                     receivedAt: "2026-11-19T16:52:00-06:00", text: "msg \(n) — 🥚\nline2", recentContext: [])
    }

    func testOfflineBufferRoundTrip() throws {
        let url = tempDir().appendingPathComponent("outbox.jsonl")
        let b = OfflineBuffer(url: url)
        XCTAssertTrue(b.isEmpty)
        try b.append([BufferedEvent(rowid: 1, event: event(1)), BufferedEvent(rowid: 2, event: event(2))])
        try b.append([BufferedEvent(rowid: 2, event: event(2))]) // duplicate ignored
        try b.append([BufferedEvent(rowid: 3, event: event(3))])
        XCTAssertEqual(b.count, 3)

        let reloaded = OfflineBuffer(url: url)
        XCTAssertEqual(reloaded.items.map(\.rowid), [1, 2, 3])
        XCTAssertEqual(reloaded.first?.event, event(1))

        XCTAssertEqual(try reloaded.popFirst()?.rowid, 1)
        XCTAssertEqual(OfflineBuffer(url: url).items.map(\.rowid), [2, 3])
    }

    func testOfflineBufferSkipsCorruptLines() throws {
        let url = tempDir().appendingPathComponent("outbox.jsonl")
        let b = OfflineBuffer(url: url)
        try b.append([BufferedEvent(rowid: 5, event: event(5))])
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{not json\n".utf8))
        try h.close()
        XCTAssertEqual(OfflineBuffer(url: url).items.map(\.rowid), [5])
    }

    func testCheckpointRoundTrip() throws {
        let url = tempDir().appendingPathComponent("state.json")
        let c = Checkpoint(url: url)
        XCTAssertFalse(c.exists)
        try c.initialize(rowid: 100)
        try c.markScanned(120)
        try c.markAcked(110)
        try c.markAcked(105) // never goes backwards
        let r = Checkpoint(url: url)
        XCTAssertTrue(r.exists)
        XCTAssertEqual(r.lastRowid, 110)
        XCTAssertEqual(r.scanPosition, 120)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(json["last_rowid"] as? Int, 110)
    }

    func testCheckpointAcceptsPlanFormat() throws {
        let url = tempDir().appendingPathComponent("state.json")
        try Data(#"{"last_rowid": 42}"#.utf8).write(to: url)
        let c = Checkpoint(url: url)
        XCTAssertEqual(c.lastRowid, 42)
        XCTAssertEqual(c.scanPosition, 42)
    }
}
