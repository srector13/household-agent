import Foundation

/// Persistent progress through chat.db, stored in state.json.
///
/// - `lastRowid`: highest ROWID the brain has acknowledged (2xx) or that was intentionally skipped,
///   with everything before it also consumed. Reported in the heartbeat.
/// - `lastScannedRowid`: highest ROWID read from chat.db and either skipped or durably written to
///   the offline buffer. Scanning resumes from here, so buffered rows are not re-read.
public struct CheckpointState: Codable, Equatable, Sendable {
    public var lastRowid: Int64
    public var lastScannedRowid: Int64

    enum CodingKeys: String, CodingKey {
        case lastRowid = "last_rowid"
        case lastScannedRowid = "last_scanned_rowid"
    }

    public init(lastRowid: Int64, lastScannedRowid: Int64? = nil) {
        self.lastRowid = lastRowid
        self.lastScannedRowid = max(lastScannedRowid ?? lastRowid, lastRowid)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let acked = try c.decode(Int64.self, forKey: .lastRowid)
        let scanned = try c.decodeIfPresent(Int64.self, forKey: .lastScannedRowid)
        self.init(lastRowid: acked, lastScannedRowid: scanned)
    }
}

public final class Checkpoint {
    public let url: URL
    public private(set) var state: CheckpointState?

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            state = try? JSONDecoder().decode(CheckpointState.self, from: data)
        }
    }

    public var exists: Bool { state != nil }
    public var lastRowid: Int64 { state?.lastRowid ?? 0 }
    public var scanPosition: Int64 { state?.lastScannedRowid ?? 0 }

    public func initialize(rowid: Int64) throws {
        try save(CheckpointState(lastRowid: rowid, lastScannedRowid: rowid))
    }

    /// Record that rows up to `rowid` have been read (skipped or buffered).
    public func markScanned(_ rowid: Int64) throws {
        let current = state ?? CheckpointState(lastRowid: 0)
        guard rowid > current.lastScannedRowid else { return }
        try save(CheckpointState(lastRowid: current.lastRowid, lastScannedRowid: rowid))
    }

    /// Record that the brain consumed everything up to `rowid`.
    public func markAcked(_ rowid: Int64) throws {
        let current = state ?? CheckpointState(lastRowid: 0)
        guard rowid > current.lastRowid else { return }
        try save(CheckpointState(lastRowid: rowid, lastScannedRowid: max(rowid, current.lastScannedRowid)))
    }

    private func save(_ new: CheckpointState) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try writeAtomically(try enc.encode(new), to: url)
        state = new
    }
}
