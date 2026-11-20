import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AgentInfo {
    public static let version = "0.1.0"
    public static let bundleIdentifier = "com.household.mac-agent"
}

/// Paths used by the agent. Everything lives under the user's Library so the agent never needs root.
public enum AgentPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/HouseholdAgent", isDirectory: true)
    }

    public static var logsDir: URL {
        home.appendingPathComponent("Library/Logs/HouseholdAgent", isDirectory: true)
    }

    public static var defaultConfig: URL { supportDir.appendingPathComponent("config.json") }
    public static var state: URL { supportDir.appendingPathComponent("state.json") }
    public static var buffer: URL { supportDir.appendingPathComponent("outbox.jsonl") }
    public static var chatDB: URL { home.appendingPathComponent("Library/Messages/chat.db") }

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Writes `data` to `url` atomically (temp file + rename) so a crash never leaves a torn file.
func writeAtomically(_ data: Data, to url: URL) throws {
    try AgentPaths.ensureDirectory(url.deletingLastPathComponent())
    try data.write(to: url, options: .atomic)
}

func isStderrTTY() -> Bool { isatty(2) != 0 }
