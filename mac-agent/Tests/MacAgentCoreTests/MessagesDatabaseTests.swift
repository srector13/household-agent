import XCTest
@testable import MacAgentCore

final class MessagesDatabaseTests: XCTestCase {
    let chicago = TimeZone(identifier: "America/Chicago")!
    let wife = "+17855550000"

    func makeFixture() throws -> (FixtureChatDB, chat: Int64, wifeHandle: Int64) {
        let f = try FixtureChatDB(dir: tempDir())
        let h = try f.addHandle(wife)
        let c = try f.addChat(guid: "iMessage;-;\(wife)", identifier: wife)
        return (f, c, h)
    }

    func config(allow: [String] = []) -> AgentConfig {
        AgentConfig(brainURL: "http://brain", syncAllowlist: false, allowHandles: allow, labels: [wife: "Wife"],
                    contextCount: 5)
    }

    func testMessagesAfterAndBuilder() throws {
        let (f, chat, h) = try makeFixture()
        try f.addMessage(chat: chat, handle: h, text: "heading home soon", fromMe: true)
        try f.addMessage(chat: chat, handle: h, text: "ok")
        try f.addMessage(chat: chat, handle: h, text: "Loved “ok”", associated: 2000) // tapback
        let eggs = try f.addMessage(chat: chat, handle: h, text: nil,
                                    body: makeAttributedBody("Can you grab eggs tomorrow? We're out"),
                                    date: 785_285_520_000_000_000)

        let db = try MessagesDatabase(path: f.url.path)
        try db.probe()
        XCTAssertEqual(try db.maxRowid(), eggs)
        XCTAssertEqual(try db.rowidForBackfill(count: 2), eggs - 2)

        let rows = try db.messages(after: 0)
        XCTAssertEqual(rows.count, 4)
        let builder = EventBuilder(config: config(), timeZone: chicago)
        XCTAssertEqual(builder.decide(rows[2], context: []), .skip("tapback/reaction"))

        let row = rows[3]
        let ctx = try db.context(chatRowid: row.chatRowid!, before: row.rowid, limit: 5)
        XCTAssertEqual(ctx.map(\.text), ["heading home soon", "ok"]) // tapback excluded, oldest first
        guard case .send(let e) = builder.decide(row, context: ctx) else { return XCTFail("expected send") }
        XCTAssertEqual(e.eventId, "imessage:\(eggs)")
        XCTAssertEqual(e.source, "imessage")
        XCTAssertEqual(e.senderHandle, wife)
        XCTAssertEqual(e.senderLabel, "Wife")
        XCTAssertEqual(e.chatId, "iMessage;-;\(wife)")
        XCTAssertFalse(e.isFromMe)
        XCTAssertEqual(e.text, "Can you grab eggs tomorrow? We're out")
        XCTAssertEqual(e.recentContext, ["Me: heading home soon", "Wife: ok"])
        // 785285520 s after 2001-01-01 = 2025-11-19T22:52:00Z
        XCTAssertEqual(e.receivedAt, "2025-11-19T16:52:00-06:00")
    }

    func testFromMeUsesOtherPartyHandle() throws {
        let (f, chat, h) = try makeFixture()
        try f.addMessage(chat: chat, handle: h, text: "note to self: buy stamps", fromMe: true)
        let row = try MessagesDatabase(path: f.url.path).messages(after: 0)[0]
        guard case .send(let e) = EventBuilder(config: config()).decide(row, context: []) else { return XCTFail() }
        XCTAssertTrue(e.isFromMe)
        XCTAssertEqual(e.senderHandle, wife)
    }

    func testGroupChatFromMeFallsBackToChatIdentifier() throws {
        let f = try FixtureChatDB(dir: tempDir())
        let chat = try f.addChat(guid: "iMessage;+;chat123", identifier: "chat123", style: 43)
        try f.addMessage(chat: chat, handle: 0, text: "who's bringing snacks", fromMe: true)
        let row = try MessagesDatabase(path: f.url.path).messages(after: 0)[0]
        XCTAssertNil(row.handle)
        guard case .send(let e) = EventBuilder(config: config()).decide(row, context: []) else { return XCTFail() }
        XCTAssertEqual(e.senderHandle, "chat123")
        XCTAssertEqual(e.chatId, "iMessage;+;chat123")
    }

    func testPrefilterAndEmptySkips() throws {
        let (f, chat, h) = try makeFixture()
        let other = try f.addHandle("+19995550000")
        let otherChat = try f.addChat(guid: "iMessage;-;+19995550000", identifier: "+19995550000")
        try f.addMessage(chat: otherChat, handle: other, text: "spam")
        try f.addMessage(chat: chat, handle: h, text: nil, body: nil)
        try f.addMessage(chat: chat, handle: h, text: "\u{FFFC}")
        try f.addMessage(chat: chat, handle: h, text: "group renamed", itemType: 2)
        let rows = try MessagesDatabase(path: f.url.path).messages(after: 0)
        let b = EventBuilder(config: config(allow: [wife]))
        XCTAssertEqual(rows.map { b.decide($0, context: []) }, [
            .skip("not allowlisted"), .skip("empty text"), .skip("empty text"), .skip("non-text item (type 2)"),
        ])
        // Same result with a synced allowlist (normalized match on the wife's number only).
        let synced = EventBuilder(config: config(), prefilter: .synced(
            SyncedAllowlist(settingsVersion: 1, handles: ["(785) 555-0000"], chatIds: [])))
        XCTAssertEqual(synced.decide(rows[0], context: []), .skip("not allowlisted"))
        // Sync on but never synced: nothing is filtered at scan time (held at send time instead).
        let unsynced = EventBuilder(config: config(), prefilter: .synced(nil))
        if case .skip = unsynced.decide(rows[0], context: []) { XCTFail("must not filter before first sync") }
    }

    func testReadOnlyOpenCannotWrite() throws {
        let (f, chat, h) = try makeFixture()
        try f.addMessage(chat: chat, handle: h, text: "x")
        let ro = try SQLiteDatabase(path: f.url.path, readOnly: true)
        XCTAssertThrowsError(try ro.execute("DELETE FROM message"))
    }

    func testSeesNewRowsOnLongLivedConnection() throws {
        let (f, chat, h) = try makeFixture()
        let db = try MessagesDatabase(path: f.url.path)
        XCTAssertEqual(try db.messages(after: 0).count, 0)
        try f.addMessage(chat: chat, handle: h, text: "new one")
        XCTAssertEqual(try db.messages(after: 0).map(\.text), ["new one"])
    }

    func testMissingDatabaseFailsProbe() {
        XCTAssertThrowsError(try MessagesDatabase(path: "/nonexistent/chat.db").probe())
    }
}
