import XCTest
@testable import MacAgentCore

final class AppleDateTests: XCTestCase {
    let chicago = TimeZone(identifier: "America/Chicago")!

    func testNanosecondsSinceReferenceDate() {
        // 2026-11-19T22:52:00Z = 16:52 in Chicago (CST, -06:00)
        let unix: TimeInterval = 1_795_128_720
        let raw = Int64((unix - AppleDate.referenceOffset) * 1_000_000_000)
        let d = AppleDate.fromMessageDate(raw)
        XCTAssertEqual(d.timeIntervalSince1970, unix, accuracy: 0.001)
        XCTAssertEqual(AppleDate.iso8601(d, timeZone: chicago), "2026-11-19T16:52:00-06:00")
    }

    func testLegacySeconds() {
        let unix: TimeInterval = 1_500_000_000
        let raw = Int64(unix - AppleDate.referenceOffset)
        XCTAssertEqual(AppleDate.fromMessageDate(raw).timeIntervalSince1970, unix, accuracy: 0.001)
    }

    func testZero() {
        XCTAssertEqual(AppleDate.fromMessageDate(0).timeIntervalSince1970, AppleDate.referenceOffset)
    }

    func testParseISO8601() {
        let d = AppleDate.parseISO8601("2026-11-20T16:00:00-06:00")
        XCTAssertEqual(d?.timeIntervalSince1970, 1_795_212_000)
        XCTAssertNotNil(AppleDate.parseISO8601("2026-11-20T16:00:00.250Z"))
        XCTAssertNil(AppleDate.parseISO8601("tomorrow"))
    }

    func testDueComponents() {
        let c = AppleDate.dueComponents(date: "2026-11-20", time: nil, timeZone: chicago)!
        XCTAssertEqual([c.year, c.month, c.day], [2026, 11, 20])
        XCTAssertNil(c.hour)
        let t = AppleDate.dueComponents(date: "2026-11-20", time: "18:30", timeZone: chicago)!
        XCTAssertEqual(t.hour, 18)
        XCTAssertEqual(t.minute, 30)
        XCTAssertNil(AppleDate.dueComponents(date: "2026-13-01", time: nil))
        XCTAssertNil(AppleDate.dueComponents(date: "2026-11-20", time: "25:00"))
        XCTAssertNil(AppleDate.dueComponents(date: "nope", time: nil))
    }

    func testStartOfDay() {
        let d = AppleDate.parseISO8601("2026-11-24T15:30:00-06:00")!
        XCTAssertEqual(AppleDate.iso8601(AppleDate.startOfDay(d, timeZone: chicago), timeZone: chicago),
                       "2026-11-24T00:00:00-06:00")
    }
}
