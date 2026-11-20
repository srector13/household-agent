import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info, warn, error

    public init(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "warn", "warning": self = .warn
        case "error": self = .error
        default: self = .info
        }
    }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Minimal thread-safe logger: appends to ~/Library/Logs/HouseholdAgent/agent.log with size-based
/// rotation (agent.log.1 … agent.log.N) and mirrors to stderr when attached to a terminal.
/// (Under launchd, stderr goes to a separate file that only catches crashes, so we do not duplicate.)
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var fileURL: URL?
    private var handle: FileHandle?
    private var level: LogLevel = .info
    private var maxBytes: UInt64 = 5 * 1024 * 1024
    private var keep = 3
    private var mirrorToStderr = isStderrTTY()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public func configure(directory: URL?, level: LogLevel, maxBytes: UInt64 = 5 * 1024 * 1024, keep: Int = 3, mirrorToStderr: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.level = level
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
        if let mirror = mirrorToStderr { self.mirrorToStderr = mirror }
        try? handle?.close()
        handle = nil
        fileURL = nil
        guard let directory else { return }
        do {
            try AgentPaths.ensureDirectory(directory)
            let url = directory.appendingPathComponent("agent.log")
            fileURL = url
            openLocked()
        } catch {
            FileHandle.standardError.write(Data("log: cannot create \(directory.path): \(error)\n".utf8))
        }
    }

    private func openLocked() {
        guard let url = fileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeededLocked() {
        guard let url = fileURL, let h = handle else { return }
        let size = (try? h.offset()) ?? 0
        guard size >= maxBytes else { return }
        try? h.close()
        handle = nil
        let fm = FileManager.default
        let path = url.path
        try? fm.removeItem(atPath: "\(path).\(keep)")
        if keep > 1 {
            for i in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: "\(path).\(i)") {
                try? fm.moveItem(atPath: "\(path).\(i)", toPath: "\(path).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
        openLocked()
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        lock.lock(); defer { lock.unlock() }
        guard level >= self.level else { return }
        let line = "\(formatter.string(from: Date())) [\(level.label)] \(message())\n"
        let data = Data(line.utf8)
        if let h = handle {
            h.write(data)
            rotateIfNeededLocked()
        }
        if mirrorToStderr || handle == nil {
            FileHandle.standardError.write(data)
        }
    }

    public static func debug(_ m: @autoclosure () -> String) { shared.log(.debug, m()) }
    public static func info(_ m: @autoclosure () -> String) { shared.log(.info, m()) }
    public static func warn(_ m: @autoclosure () -> String) { shared.log(.warn, m()) }
    public static func error(_ m: @autoclosure () -> String) { shared.log(.error, m()) }
}
