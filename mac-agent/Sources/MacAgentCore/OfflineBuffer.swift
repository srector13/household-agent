import Foundation

/// One queued event plus the chat.db ROWID it came from (so the checkpoint can advance on ack).
public struct BufferedEvent: Codable, Equatable, Sendable {
    public var rowid: Int64
    public var event: InboundEvent

    public init(rowid: Int64, event: InboundEvent) {
        self.rowid = rowid
        self.event = event
    }
}

/// Durable FIFO of events waiting to be delivered to the brain, stored as JSON Lines.
///
/// Every new event goes through the buffer (append → deliver → pop), so a brain outage or a crash
/// never loses a message, and delivery stays in ROWID order. The file is tiny in practice
/// (household volume), so popping simply rewrites it atomically.
public final class OfflineBuffer {
    public let url: URL
    public private(set) var items: [BufferedEvent] = []

    public init(url: URL) {
        self.url = url
        load()
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public var first: BufferedEvent? { items.first }

    private func load() {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        let dec = Wire.decoder()
        var loaded: [BufferedEvent] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let item = try? dec.decode(BufferedEvent.self, from: Data(line)) {
                loaded.append(item)
            } else {
                Log.warn("outbox: dropping unreadable line (\(line.count) bytes)")
            }
        }
        items = loaded
    }

    public func append(_ newItems: [BufferedEvent]) throws {
        guard !newItems.isEmpty else { return }
        let fresh = newItems.filter { n in !items.contains { $0.event.eventId == n.event.eventId } }
        guard !fresh.isEmpty else { return }
        let enc = Wire.encoder()
        var chunk = Data()
        for item in fresh {
            chunk.append(try enc.encode(item))
            chunk.append(UInt8(ascii: "\n"))
        }
        try AgentPaths.ensureDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: chunk)
        try h.synchronize()
        items.append(contentsOf: fresh)
    }

    @discardableResult
    public func popFirst() throws -> BufferedEvent? {
        guard !items.isEmpty else { return nil }
        let head = items.removeFirst()
        try rewrite()
        return head
    }

    private func rewrite() throws {
        let enc = Wire.encoder()
        var data = Data()
        for item in items {
            data.append(try enc.encode(item))
            data.append(UInt8(ascii: "\n"))
        }
        try writeAtomically(data, to: url)
    }
}
