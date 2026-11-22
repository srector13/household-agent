import Foundation

/// Reads the brain's date strings and formats them the way the dashboard does.
///
/// The brain sends ISO-8601 with an offset ("2026-11-21T21:14:05.737999-06:00", microseconds
/// included), local times without one ("2026-11-24T14:00") and plain days ("2026-11-24").
public enum BrainDate {
    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses a timestamp. Fractional seconds are dropped; a missing offset means the device's zone.
    public static func parse(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if s.count == 10 { return day(s) }
        if let dot = s.firstIndex(of: "."), s.distance(from: s.startIndex, to: dot) == 19 {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            s.removeSubrange(dot..<end)
        }
        if s.hasSuffix("Z") || s.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) != nil {
            return isoFull.date(from: s)
        }
        // no offset: local wall time, with or without seconds
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = s.count == 16 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }

    /// A calendar day ("2026-11-24") at local midnight.
    public static func day(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// "2026-11-24" for a date (local).
    public static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "14:05" for a date (local).
    public static func timeString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "2026-11-24T14:05" local, for moving events.
    public static func localISO(_ d: Date) -> String { dayString(d) + "T" + timeString(d) }

    /// "3:00 PM" from "15:00".
    public static func clock(_ hhmm: String?) -> String? {
        guard let hhmm else { return nil }
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count >= 2 else { return hhmm }
        var c = DateComponents(); c.hour = p[0]; c.minute = p[1]
        guard let d = Calendar.current.date(from: c) else { return hhmm }
        return time(d)
    }

    public static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    /// "Today", "Tomorrow", "Yesterday", "Tue Nov 24".
    public static func niceDay(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "Tomorrow" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = cal.isDate(d, equalTo: now, toGranularity: .year) ? "EEE MMM d" : "EEE MMM d, yyyy"
        return f.string(from: d)
    }

    /// "due Tomorrow, 3:00 PM" style text for a reminder's due day + time.
    public static func due(_ day: String?, _ time: String?, now: Date = Date()) -> String? {
        guard let d = self.day(day) else { return nil }
        let base = niceDay(d, now: now)
        return clock(time).map { "\(base), \($0)" } ?? base
    }

    /// "now", "5 min ago", "3 h ago", "2 days ago".
    public static func ago(_ s: String?, now: Date = Date()) -> String {
        guard let d = parse(s) else { return "" }
        let sec = Int(now.timeIntervalSince(d))
        if sec < 60 { return "now" }
        if sec < 3600 { return "\(sec / 60) min ago" }
        if sec < 86400 { return "\(sec / 3600) h ago" }
        let days = sec / 86400
        return days == 1 ? "yesterday" : days < 14 ? "\(days) days ago" : niceDay(d, now: now)
    }

    /// Short weekday ("Tue") and day number ("24"), for agenda tiles.
    public static func tile(_ d: Date, now: Date = Date()) -> (top: String, day: String) {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE"
        let top = cal.isDate(d, inSameDayAs: now) ? "Today" : f.string(from: d)
        return (top, String(cal.component(.day, from: d)))
    }

    /// "Saturday, November 21".
    public static func longDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: d)
    }
}
