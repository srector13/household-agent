import Foundation
import XCTest
@testable import SecondBrainKit

/// Runs the client against a real brain when BRAIN_URL is set (CI and local dev only):
///   BRAIN_URL=http://127.0.0.1:8080 swift test
final class LiveTests: XCTestCase {
    var api: BrainAPI!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["BRAIN_URL"], let cfg = ServerConfig.parse(s) else {
            throw XCTSkip("BRAIN_URL not set")
        }
        api = BrainAPI(config: cfg)
    }

    func testEveryScreenDecodes() async throws {
        _ = try await api.info()
        _ = try await api.home()
        _ = try await api.today()
        _ = try await api.weekly()
        let people = try await api.people()
        if let p = people.first { _ = try await api.person(p.key) }
        for tab in ["todos", "collections", "history"] { _ = try await api.items(tab: tab) }
        _ = try await api.review()
        let act = try await api.activity()
        if let e = act.events.first { _ = try await api.event(e.id) }
        _ = try await api.system()
        _ = try await api.notifications(after: 0)
        _ = try await api.settings()
        _ = try await api.timeline()
        _ = try await api.sources()
    }

    func testTimelineSourcesAndPeople() async throws {
        let t = try await api.timeline()
        XCTAssertEqual(t.week.count, 7)
        _ = try await api.timeline(day: t.week.first?.date)
        let s = try await api.sources()
        if let other = s.calendars.first(where: { !$0.ours }) {
            let hidden = try await api.setSource(kind: "calendar", name: other.name, shown: false)
            XCTAssertEqual(hidden.calendars.first { $0.name == other.name }?.shown, false)
            try await api.setSource(kind: "calendar", name: other.name, shown: true)
        }
        if let r = t.entries.first(where: { !$0.ours && !$0.isEvent }), let id = r.appleId {
            try await api.appleDone(id, done: true)
            try await api.appleDone(id, done: false)
            try await api.appleMove(id, due: t.date, dueTime: "21:30")
        }
        let p = try await api.addPerson(name: "Test Person", label: "Tester", handle: "+13125550123", photo: nil, isMe: false)
        XCTAssertEqual(p.label, "Tester")
        try await api.removePerson(p.key)
    }

    func testActionsRoundTrip() async throws {
        try await api.capture("remind me to water the plants tomorrow")
        let page = try await api.items(tab: "todos")
        guard let it = page.items.first(where: { $0.isOpen && $0.isReminder }) else { throw XCTSkip("no open reminder") }
        let opts = try await api.snoozeOptions(it.id)
        XCTAssertFalse(opts.options.isEmpty)
        let r = try await api.snooze(it.id, key: opts.options[0].key)
        XCTAssertNotNil(r.label)
        try await api.reschedule(it.id, due: BrainDate.dayString(Date().addingTimeInterval(86400 * 3)), dueTime: "08:15")
        let f = try await api.focus(it.id)
        XCTAssertEqual(f.itemId, it.id)
        try await api.startTimer(it.id, minutes: 10)
        try await api.stopTimer()
        try await api.setDone(it.id, true)
        try await api.setDone(it.id, false)
        try await api.delete(it.id)
        try await api.restore(it.id)
        if let e = try await api.activity().events.first {
            let d = try await api.event(e.id)
            if d.can.retry { try await api.eventAction("retry", e.id) }
        }
        do {
            try await api.eventAction("approve", "nope:1")
            XCTFail("expected an error")
        } catch let BrainError.server(status, _) {
            XCTAssertTrue(status == 404 || status == 409)
        }
    }
}
