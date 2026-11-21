import Foundation
@testable import MacAgentCore

/// Builds a typedstream blob shaped like a real `message.attributedBody`.
func makeAttributedBody(_ text: String, mutable: Bool = false) -> Data {
    var b: [UInt8] = [0x04, 0x0B]
    b += Array("streamtyped".utf8)
    b += [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
    b += [0x19] + Array("NSMutableAttributedString".utf8) + [0x00]
    b += [0x84, 0x84, 0x12] + Array("NSAttributedString".utf8) + [0x00]
    b += [0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
    if mutable {
        b += [0x0F] + Array("NSMutableString".utf8) + [0x01, 0x84, 0x84]
    }
    b += [0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
    let utf8 = Array(text.utf8)
    if utf8.count < 0x80 {
        b.append(UInt8(utf8.count))
    } else if utf8.count <= 0xFFFF {
        b += [0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]
    } else {
        let n = UInt32(utf8.count)
        b += [0x82, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
    }
    b += utf8
    // Trailing attribute runs, as in real blobs.
    b += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x05, 0x92, 0x84, 0x84, 0x84, 0x0C]
    b += Array("NSDictionary".utf8) + [0x00, 0x94, 0x84, 0x01, 0x69, 0x01, 0x92, 0x84, 0x96, 0x96]
    b += [0x1D] + Array("__kIMMessagePartAttributeName".utf8) + [0x86, 0x92, 0x84, 0x84, 0x84, 0x08]
    b += Array("NSNumber".utf8) + [0x00, 0x84, 0x84, 0x07] + Array("NSValue".utf8) + [0x00, 0x94, 0x84, 0x01, 0x2A, 0x84, 0x99, 0x99, 0x00, 0x86, 0x86, 0x86]
    return Data(b)
}

func tempDir(_ name: String = #function) -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("macagent-tests-\(safe)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal chat.db with the tables/columns the agent reads.
final class FixtureChatDB {
    let url: URL
    let db: SQLiteDatabase

    init(dir: URL) throws {
        url = dir.appendingPathComponent("chat.db")
        db = try SQLiteDatabase(path: url.path, readOnly: false)
        try db.execute("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
                           style INTEGER, chat_identifier TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT,
                              attributedBody BLOB, handle_id INTEGER DEFAULT 0, date INTEGER,
                              is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
                              item_type INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0,
                                        PRIMARY KEY (chat_id, message_id));
        """)
    }

    @discardableResult
    func addHandle(_ id: String) throws -> Int64 {
        _ = try db.query("INSERT INTO handle (id, service) VALUES (?, 'iMessage')", [.text(id)])
        return try db.query("SELECT last_insert_rowid()").first!.first!.int!
    }

    @discardableResult
    func addChat(guid: String, identifier: String, style: Int64 = 45) throws -> Int64 {
        _ = try db.query("INSERT INTO chat (guid, style, chat_identifier) VALUES (?, ?, ?)",
                         [.text(guid), .int(style), .text(identifier)])
        return try db.query("SELECT last_insert_rowid()").first!.first!.int!
    }

    @discardableResult
    func addMessage(chat: Int64, handle: Int64, text: String?, body: Data? = nil, fromMe: Bool = false,
                    date: Int64 = 785_000_000_000_000_000, associated: Int64 = 0, itemType: Int64 = 0) throws -> Int64 {
        _ = try db.query("""
            INSERT INTO message (guid, text, attributedBody, handle_id, date, is_from_me, associated_message_type, item_type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(UUID().uuidString), text.map { .text($0) } ?? .null, body.map { .blob($0) } ?? .null,
                  .int(handle), .int(date), .int(fromMe ? 1 : 0), .int(associated), .int(itemType)])
        let id = try db.query("SELECT last_insert_rowid()").first!.first!.int!
        _ = try db.query("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [.int(chat), .int(id)])
        return id
    }
}

/// In-memory ItemStore for executor tests.
actor FakeItemStore: ItemStore {
    struct Item {
        var kind: ItemKind
        var title: String
        var notes: String?
        var url: String?
        var due: String?
        var dueTime: String?
        var alert: String?
        var start: String?
        var end: String?
        var allDay: Bool = false
        var location: String?
        var completed = false
        var list: String?
    }

    var items: [String: Item] = [:]
    var createCount = 0
    var updateCount = 0
    private var next = 0

    func findItem(taggedWith tag: String, kind: ItemKind, around date: Date?) async throws -> String? {
        items.first { $0.value.kind == kind && ($0.value.notes ?? "").contains(tag) }?.key
    }

    func createReminder(_ p: ReminderPayload) async throws -> String {
        next += 1
        createCount += 1
        let id = "rem-\(next)"
        items[id] = Item(kind: .reminder, title: p.title, notes: p.notes, url: p.url, due: p.due, dueTime: p.dueTime,
                         alert: p.alert, list: p.list)
        return id
    }

    func createEvent(_ p: EventPayload) async throws -> String {
        next += 1
        createCount += 1
        let id = "evt-\(next)"
        items[id] = Item(kind: .event, title: p.title, notes: p.notes, url: p.url, start: p.start, end: p.end,
                         allDay: p.allDay ?? false, location: p.location)
        return id
    }

    func deleteItem(id: String, kind: ItemKind?) async throws -> Bool {
        items.removeValue(forKey: id) != nil
    }

    func updateItem(id: String, kind: ItemKind, changes ch: ItemChanges, notesAppend: String?) async throws -> Bool {
        guard var it = items[id] else { return false }
        func apply<T>(_ patch: Patch<T>, _ field: inout T?) {
            switch patch {
            case .set(let v): field = v
            case .clear: field = nil
            case .keep: break
            }
        }
        if let t = ch.title.value { it.title = t }
        apply(ch.due, &it.due)
        if !ch.due.isKeep || !ch.dueTime.isKeep { it.dueTime = ch.dueTime.value }
        apply(ch.alert, &it.alert)
        apply(ch.start, &it.start)
        apply(ch.end, &it.end)
        apply(ch.location, &it.location)
        apply(ch.url, &it.url)
        if let a = ch.allDay.value { it.allDay = a }
        if let c = ch.completed.value { it.completed = c }
        if let note = notesAppend { it.notes = NotesEditor.append(note, to: it.notes) }
        items[id] = it
        updateCount += 1
        return true
    }

    func listIdentifier(ofReminder id: String) async throws -> String? {
        items[id].map { "list:" + ($0.list ?? "default") }
    }

    func permissionFlags() async -> (reminders: Bool, calendar: Bool) { (true, true) }
}

/// Records what the executor asked to organize; can be unavailable or fail on apply.
actor FakeOrganizer: ReminderOrganizer {
    struct Call: Equatable { var list: String; var reminder: String; var section: String?; var tags: [String] }
    var available: Bool
    var failApply: Bool
    var calls: [Call] = []
    var availabilityChecks = 0

    init(available: Bool = true, failApply: Bool = false) {
        self.available = available
        self.failApply = failApply
    }

    func isAvailable() async -> Bool {
        availabilityChecks += 1
        return available
    }

    func lastKnownAvailability() async -> Bool? { availabilityChecks == 0 ? nil : available }

    func apply(listIdentifier: String, reminderIdentifier: String, section: String?, tags: [String]) async throws {
        if failApply { throw OrganizerError("boom") }
        calls.append(Call(list: listIdentifier, reminder: reminderIdentifier, section: section, tags: tags))
    }
}
