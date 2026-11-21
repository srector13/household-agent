import Foundation
#if canImport(CReminderKit)
import CReminderKit
#endif

/// The raw ReminderKit operations, as plain synchronous functions. On macOS `.system` calls the
/// Objective-C bridge (Sources/CReminderKit); tests inject fakes. Functions may block.
public struct ReminderKitBackend: Sendable {
    /// (available, human-readable report)
    public var check: @Sendable () -> (ok: Bool, report: String)
    /// nil on success, else an error message.
    public var apply: @Sendable (_ list: String, _ reminder: String, _ section: String?, _ tags: [String]) -> String?
    /// Best-effort read-back for the probe.
    public var read: @Sendable (_ list: String, _ reminder: String) -> (section: String?, tags: [String], error: String?)

    public init(check: @escaping @Sendable () -> (ok: Bool, report: String),
                apply: @escaping @Sendable (String, String, String?, [String]) -> String?,
                read: @escaping @Sendable (String, String) -> (section: String?, tags: [String], error: String?)) {
        self.check = check
        self.apply = apply
        self.read = read
    }
}

/// ReminderOrganizer over a ReminderKitBackend: runs calls on one serial queue with a timeout,
/// caches availability, and marks itself unavailable after a timeout so calls don't pile up.
///
/// Crash guard: a private call with a changed signature can crash the process outright (not an
/// ObjC exception, so @try can't catch it). Every call is bracketed by a marker file; if the agent
/// starts and finds the marker, the previous run died inside ReminderKit, so ReminderKit stays off
/// (title fallback) until `--probe-reminderkit --write` succeeds and clears it. Without this,
/// launchd's KeepAlive + command redelivery would crash-loop on the same reminder.
public final class ReminderKitOrganizer: ReminderOrganizer, @unchecked Sendable {
    private let backend: ReminderKitBackend
    private let queue = DispatchQueue(label: "com.household.mac-agent.reminderkit")
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cached: Bool?
    private var lastReport = "not probed yet"
    private let marker: URL?
    /// True if the crash marker was present when this organizer was created.
    public let foundCrashMarker: Bool

    public init(backend: ReminderKitBackend, timeout: TimeInterval = 20, crashMarker: URL? = nil,
                honorCrashMarker: Bool = true) {
        self.backend = backend
        self.timeout = timeout
        self.marker = crashMarker
        let found = crashMarker.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        self.foundCrashMarker = found
        if found && honorCrashMarker {
            cached = false
            lastReport = "A ReminderKit call crashed the agent last time (\(crashMarker!.path) exists). "
                + "Sections & tags are off; run `mac-agent --probe-reminderkit --write` to test and re-enable."
            Log.warn(lastReport)
        }
    }

    public static var defaultCrashMarker: URL { AgentPaths.supportDir.appendingPathComponent("reminderkit.inflight") }

    /// The organizer for this platform: ReminderKit on macOS, always-unavailable elsewhere.
    public static func platformDefault(honorCrashMarker: Bool = true) -> ReminderOrganizer {
        if let b = ReminderKitBackend.system {
            return ReminderKitOrganizer(backend: b, crashMarker: defaultCrashMarker, honorCrashMarker: honorCrashMarker)
        }
        return NoReminderOrganizer()
    }

    /// Re-enables ReminderKit after a successful probe.
    public func clearCrashMarker() {
        if let m = marker { try? FileManager.default.removeItem(at: m) }
    }

    /// Wraps a backend call with the crash marker (written before, removed after it returns).
    private func guarded<T: Sendable>(_ body: @escaping @Sendable () -> T) -> @Sendable () -> T {
        let marker = self.marker
        return {
            if let m = marker {
                try? FileManager.default.createDirectory(at: m.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: m.path, contents: Data("ReminderKit call in progress\n".utf8))
            }
            let result = body()
            if let m = marker { try? FileManager.default.removeItem(at: m) }
            return result
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func isAvailable() async -> Bool {
        if let c = locked({ cached }) { return c }
        let backend = self.backend
        let result = await run(guarded { backend.check() }) ?? (ok: false, report: "availability check timed out")
        locked {
            cached = result.ok
            lastReport = result.report
        }
        if !result.ok { Log.warn("ReminderKit unavailable:\n\(result.report)") }
        return result.ok
    }

    public func lastKnownAvailability() async -> Bool? { locked { cached } }

    /// Report from the last availability check (runs one if needed).
    public func report() async -> String {
        _ = await isAvailable()
        return locked { lastReport }
    }

    public func apply(listIdentifier: String, reminderIdentifier: String, section: String?, tags: [String]) async throws {
        do {
            try await applyOnce(listIdentifier, reminderIdentifier, section, tags)
        } catch let e as OrganizerError where e.description.contains("not found in ReminderKit") {
            // EventKit just saved the reminder; give remindd a moment to make it visible, then retry once.
            try? await Task.sleep(nanoseconds: retryDelayNs)
            try await applyOnce(listIdentifier, reminderIdentifier, section, tags)
        }
    }

    /// Delay before the single retry above (shortened in tests).
    var retryDelayNs: UInt64 = 1_000_000_000

    private func applyOnce(_ listIdentifier: String, _ reminderIdentifier: String, _ section: String?,
                           _ tags: [String]) async throws {
        let backend = self.backend
        guard let outcome = await run(guarded { backend.apply(listIdentifier, reminderIdentifier, section, tags) }) else {
            // A hung private call: stop using ReminderKit until the agent restarts.
            locked {
                cached = false
                lastReport = "a ReminderKit call timed out after \(Int(timeout))s"
            }
            throw OrganizerError("ReminderKit call timed out")
        }
        if let message = outcome { throw OrganizerError(message) }
    }

    public func readBack(listIdentifier: String, reminderIdentifier: String) async
        -> (section: String?, tags: [String], error: String?) {
        let backend = self.backend
        return await run(guarded { backend.read(listIdentifier, reminderIdentifier) })
            ?? (section: nil, tags: [], error: "read-back timed out")
    }

    /// Runs `body` on the serial queue; nil if it doesn't finish within `timeout`.
    private func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        let once = ResumeOnce<T?>()
        let timeout = self.timeout
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            once.set(c)
            queue.async { once.resume(body()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }
}

/// Resumes a continuation exactly once (first of: result, timeout).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func set(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        continuation = c
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

extension ReminderKitBackend {
    /// The real backend (Objective-C bridge), or nil where ReminderKit can't exist.
    public static var system: ReminderKitBackend? {
        #if canImport(CReminderKit)
        return ReminderKitBackend(
            check: {
                var report: UnsafeMutablePointer<CChar>?
                let ok = ha_rk_check(&report) == 1
                return (ok, takeString(report) ?? "")
            },
            apply: { list, reminder, section, tags in
                var error: UnsafeMutablePointer<CChar>?
                let cTags = tags.map { strdup($0) }
                defer { cTags.forEach { free($0) } }
                let pointers: [UnsafePointer<CChar>?] = cTags.map { $0.map { UnsafePointer($0) } }
                let rc = pointers.withUnsafeBufferPointer { buf in
                    ha_rk_apply(list, reminder, section, buf.baseAddress, Int32(tags.count), &error)
                }
                let message = takeString(error)
                return rc == 0 ? nil : (message ?? "ReminderKit error \(rc)")
            },
            read: { list, reminder in
                var section: UnsafeMutablePointer<CChar>?
                var tags: UnsafeMutablePointer<CChar>?
                var error: UnsafeMutablePointer<CChar>?
                let rc = ha_rk_read(list, reminder, &section, &tags, &error)
                let tagList = (takeString(tags) ?? "").split(separator: ",").map(String.init)
                return (takeString(section), tagList, rc == 0 ? nil : (takeString(error) ?? "error \(rc)"))
            }
        )
        #else
        return nil
        #endif
    }
}

#if canImport(CReminderKit)
/// Copies and frees a malloc'd C string from the bridge.
private func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { ha_rk_free(p) }
    return String(cString: p)
}
#endif
