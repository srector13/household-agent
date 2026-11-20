import Foundation

/// Helpers for chat.db timestamps and the ISO-8601 / calendar strings used on the wire.
public enum AppleDate {
    /// Seconds between 1970-01-01 and 2001-01-01 (Apple's reference date).
    public static let referenceOffset: TimeInterval = 978_307_200

    /// Converts `message.date`. Since macOS 10.13 this is nanoseconds since 2001-01-01 UTC; older
    /// databases stored plain seconds. Values above 1e11 can only be nanoseconds (1e11 s ≈ 3170 years).
    public static func fromMessageDate(_ raw: Int64) -> Date {
        let seconds: TimeInterval
        if raw > 100_000_000_000 || raw < -100_000_000_000 {
            seconds = TimeInterval(raw) / 1_000_000_000
        } else {
            seconds = TimeInterval(raw)
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// ISO-8601 with a numeric offset in `timeZone`, e.g. "2026-11-19T16:52:00-06:00".
    public static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Parses ISO-8601 with or without fractional seconds.
    public static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// "YYYY-MM-DD" (+ optional "HH:MM") → DateComponents in `timeZone`.
    public static func dueComponents(date: String, time: String?, timeZone: TimeZone = .current) -> DateComponents? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = timeZone
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        if let time, !time.isEmpty {
            let t = time.split(separator: ":").compactMap { Int($0) }
            guard t.count >= 2, (0...23).contains(t[0]), (0...59).contains(t[1]) else { return nil }
            comps.hour = t[0]
            comps.minute = t[1]
        }
        return comps
    }

    /// Start of the local calendar day that contains `date`.
    public static func startOfDay(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.startOfDay(for: date)
    }
}
