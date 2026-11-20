import Foundation

/// A message row from chat.db, already joined with its sender handle and chat.
public struct MessageRow: Equatable, Sendable {
    public var rowid: Int64
    public var text: String?
    public var attributedBody: Data?
    public var date: Int64
    public var isFromMe: Bool
    public var associatedMessageType: Int64
    public var itemType: Int64
    public var handle: String?
    public var chatRowid: Int64?
    public var chatIdentifier: String?
    public var chatGUID: String?
}

/// A previous message used for `recent_context`.
public struct ContextRow: Equatable, Sendable {
    public var text: String
    public var isFromMe: Bool
    public var handle: String?
}

/// Read-only queries against ~/Library/Messages/chat.db.
public final class MessagesDatabase {
    private let db: SQLiteDatabase
    private let decodeFallback: Bool

    public init(path: String, readOnly: Bool = true, nsUnarchiverFallback: Bool = false) throws {
        db = try SQLiteDatabase(path: path, readOnly: readOnly)
        decodeFallback = nsUnarchiverFallback
    }

    /// Cheap probe used for the Full Disk Access flag: without FDA, opening succeeds lazily but the
    /// first read fails with "authorization denied" / "unable to open database file".
    public func probe() throws {
        _ = try db.query("SELECT 1 FROM message LIMIT 1")
    }

    public func maxRowid() throws -> Int64 {
        try db.query("SELECT IFNULL(MAX(ROWID), 0) FROM message").first?.first?.int ?? 0
    }

    /// ROWID to start from so the last `count` messages are (re)sent.
    public func rowidForBackfill(count: Int) throws -> Int64 {
        guard count > 0 else { return try maxRowid() }
        let rows = try db.query("SELECT ROWID FROM message ORDER BY ROWID DESC LIMIT 1 OFFSET ?", [.int(Int64(count - 1))])
        if let r = rows.first?.first?.int { return max(0, r - 1) }
        return 0
    }

    public func messages(after rowid: Int64, limit: Int = 200) throws -> [MessageRow] {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me,
               IFNULL(m.associated_message_type, 0), IFNULL(m.item_type, 0),
               h.id, c.ROWID, c.chat_identifier, c.guid
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.ROWID > ?
        ORDER BY m.ROWID ASC, c.ROWID ASC
        LIMIT ?
        """
        var seen = Set<Int64>()
        var out: [MessageRow] = []
        for r in try db.query(sql, [.int(rowid), .int(Int64(limit))]) {
            guard let id = r[0].int, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(MessageRow(
                rowid: id,
                text: r[1].string,
                attributedBody: r[2].data,
                date: r[3].int ?? 0,
                isFromMe: (r[4].int ?? 0) != 0,
                associatedMessageType: r[5].int ?? 0,
                itemType: r[6].int ?? 0,
                handle: r[7].string,
                chatRowid: r[8].int,
                chatIdentifier: r[9].string,
                chatGUID: r[10].string
            ))
        }
        return out
    }

    /// Up to `limit` earlier messages in the same chat, oldest first, tapbacks excluded.
    public func context(chatRowid: Int64, before rowid: Int64, limit: Int) throws -> [ContextRow] {
        guard limit > 0 else { return [] }
        let sql = """
        SELECT m.text, m.attributedBody, m.is_from_me, h.id
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE cmj.chat_id = ? AND m.ROWID < ?
          AND IFNULL(m.associated_message_type, 0) = 0 AND IFNULL(m.item_type, 0) = 0
        ORDER BY m.ROWID DESC
        LIMIT ?
        """
        var out: [ContextRow] = []
        for r in try db.query(sql, [.int(chatRowid), .int(rowid), .int(Int64(limit))]) {
            guard let text = Self.bodyText(text: r[0].string, attributedBody: r[1].data, fallback: decodeFallback) else { continue }
            out.append(ContextRow(text: text, isFromMe: (r[2].int ?? 0) != 0, handle: r[3].string))
        }
        return out.reversed()
    }

    /// `message.text`, or the text decoded from `attributedBody`; nil when there is nothing readable.
    /// U+FFFC (attachment placeholder) is stripped.
    public static func bodyText(text: String?, attributedBody: Data?, fallback: Bool = false) -> String? {
        var s = text
        if s == nil || s?.isEmpty == true, let blob = attributedBody, !blob.isEmpty {
            s = AttributedBodyDecoder.decode(blob, allowNSUnarchiverFallback: fallback)
        }
        guard let raw = s else { return nil }
        let cleaned = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Turns chat.db rows into wire events. Pure, so it is unit-testable.
public struct EventBuilder {
    public var config: AgentConfig
    public var timeZone: TimeZone

    public init(config: AgentConfig, timeZone: TimeZone = .current) {
        self.config = config
        self.timeZone = timeZone
    }

    public enum Decision: Equatable {
        case send(InboundEvent)
        case skip(String)
    }

    /// The handle reported as `sender_handle`. For messages the user sent, chat.db's `handle_id`
    /// already points at the other party in 1:1 chats; group chats (handle_id = 0) fall back to the
    /// chat identifier.
    public func senderHandle(for row: MessageRow) -> String? {
        if let h = row.handle, !h.isEmpty { return h }
        if let c = row.chatIdentifier, !c.isEmpty { return c }
        return nil
    }

    public func decide(_ row: MessageRow, context: [ContextRow]) -> Decision {
        if row.associatedMessageType != 0 { return .skip("tapback/reaction") }
        if row.itemType != 0 { return .skip("non-text item (type \(row.itemType))") }
        guard let handle = senderHandle(for: row) else { return .skip("no handle") }
        guard config.isAllowed(handle: handle, chatIdentifier: row.chatIdentifier, chatGUID: row.chatGUID) else {
            return .skip("not allowlisted")
        }
        guard let text = MessagesDatabase.bodyText(text: row.text, attributedBody: row.attributedBody,
                                                   fallback: config.useNSUnarchiverFallback) else {
            return .skip("empty text")
        }
        let event = InboundEvent(
            eventId: "imessage:\(row.rowid)",
            source: "imessage",
            senderHandle: handle,
            senderLabel: config.labels[handle],
            chatId: row.chatGUID ?? row.chatIdentifier,
            isFromMe: row.isFromMe,
            receivedAt: AppleDate.iso8601(AppleDate.fromMessageDate(row.date), timeZone: timeZone),
            text: text,
            recentContext: formatContext(context)
        )
        return .send(event)
    }

    public func formatContext(_ rows: [ContextRow]) -> [String] {
        rows.map { r in
            let who: String
            if r.isFromMe {
                who = "Me"
            } else if let h = r.handle {
                who = config.labels[h] ?? h
            } else {
                who = "Them"
            }
            return "\(who): \(Self.truncate(r.text, max: 300))"
        }
    }

    static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}
