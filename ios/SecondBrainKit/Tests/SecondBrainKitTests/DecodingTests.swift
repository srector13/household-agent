import Foundation
import XCTest
@testable import SecondBrainKit

/// Decodes real responses saved by the brain's tests (brain/tests/test_api_v1.py, WRITE_FIXTURES=1),
/// so a change on either side that breaks the app fails here.
final class DecodingTests: XCTestCase {
    func fixture<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try BrainAPI.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    func testInfoAndHome() throws {
        let info: Info = try fixture("info")
        XCTAssertEqual(info.appName, "Second Brain")
        XCTAssertEqual(info.reviewCount, 1)
        let home: Home = try fixture("home")
        XCTAssertEqual(home.picks.first?.title, "Call the plumber")
        XCTAssertEqual(home.picks.first?.firstStep, "Find the card")
        XCTAssertEqual(home.attention.reviews.first?.titles, ["Maybe paint the fence"])
        XCTAssertTrue(home.agenda.contains { $0.external && $0.title == "Dentist" })
        XCTAssertFalse(home.recent.isEmpty)
    }

    func testTimelineAndSources() throws {
        let t: Timeline = try fixture("timeline")
        XCTAssertTrue(t.isToday)
        XCTAssertEqual(t.week.count, 7)
        XCTAssertNotNil(t.nowDate)
        let banner = try XCTUnwrap(t.banner)
        XCTAssertEqual(banner.count, 1)
        XCTAssertTrue(banner.entry.event.text.hasPrefix("maybe get the plumber"))
        let carried = t.entries.filter(\.carried)
        XCTAssertTrue(carried.contains { $0.ours && $0.person?.photo != nil })
        XCTAssertTrue(carried.contains { !$0.ours && $0.appleId == "R-late" && $0.late })
        let swim = try XCTUnwrap(t.entries.first { $0.title == "Early swim" })
        XCTAssertTrue(swim.isEvent && swim.past && !swim.ours)
        XCTAssertEqual(swim.color, "#0A7AFF")
        XCTAssertNotNil(swim.startDate)
        XCTAssertNotNil(swim.endDate)
        XCTAssertTrue(t.entries.allSatisfy { $0.atDate != nil })

        let s: Sources = try fixture("sources")
        XCTAssertEqual(s.calendars.first?.name, "Family")
        XCTAssertTrue(s.calendars.first?.ours ?? false)
        XCTAssertEqual(s.calendars.first?.kind, "calendar")
        let groceries = try XCTUnwrap(s.lists.first { $0.name == "Groceries" })
        XCTAssertEqual(groceries.id, "list:Groceries")
        XCTAssertFalse(groceries.ours)
        XCTAssertTrue(groceries.shown)
    }

    func testTimelineIsLenient() throws {
        let json = ##"{"date":"2026-11-28","entries":[{"id":"item:x","title":"Milk"}]}"##
        let t = try BrainAPI.decoder.decode(Timeline.self, from: Data(json.utf8))
        XCTAssertEqual(t.today, "2026-11-28")
        XCTAssertNil(t.banner)
        XCTAssertEqual(t.entries.first?.kind, "reminder")
        XCTAssertFalse(t.entries.first?.done ?? true)
    }

    func testNextUpDecodesTheInKey() throws {
        let json = ##"{"kind":"event","title":"Dentist","at":"2026-11-22T09:00:00-06:00","end":null,"ongoing":false,"in":"in 25 min","where":"Home","event_id":null,"item_id":null,"color":"#34C759"}"##
        let n = try BrainAPI.decoder.decode(Home.NextUp.self, from: Data(json.utf8))
        XCTAssertEqual(n.inLabel, "in 25 min")
        XCTAssertEqual(n.where, "Home")
    }

    func testOtherScreens() throws {
        let today: Today = try fixture("today")
        XCTAssertEqual(today.picks.count, 1)
        let people: PeopleList = try fixture("people")
        XCTAssertTrue(people.people.contains { $0.contactName == "Sarah Smith" && $0.photo != nil })
        let person: PersonDetail = try fixture("person")
        XCTAssertEqual(person.gifts.first?.url, "https://example.com/k")
        XCTAssertFalse(person.messages.isEmpty)
        let todos: ItemsPage = try fixture("items_todos")
        XCTAssertTrue(todos.items.contains { $0.title == "Call the plumber" && $0.dueTime == "15:00" })
        XCTAssertNotNil(todos.items.first?.log)
        let cols: ItemsPage = try fixture("items_collections")
        XCTAssertEqual(cols.groups.first?.people.first?.items.first?.title, "Kindle")
        _ = try fixture("items_history", as: ItemsPage.self)
        let review: ReviewList = try fixture("review")
        XCTAssertEqual(review.items.first?.proposals.first?.title, "Maybe paint the fence")
        let activity: Activity = try fixture("activity")
        XCTAssertEqual(activity.events.count, 3)
        let event: EventDetail = try fixture("event")
        XCTAssertTrue(event.can.undo)
        XCTAssertEqual(event.trace.first?.label, "Received")
        let system: SystemStatus = try fixture("system")
        XCTAssertEqual(system.funnel["received"], 3)
        XCTAssertFalse(system.daily.isEmpty)
        let weekly: Weekly = try fixture("weekly")
        XCTAssertTrue(weekly.cards.isEmpty)
        let feed: NotificationFeed = try fixture("notifications")
        XCTAssertEqual(feed.items.last?.url, "/review")
        let settings: SettingsSnapshot = try fixture("settings")
        XCTAssertEqual(settings.values["daily.weekly_day"]?.string, "sun")
        XCTAssertNotNil(settings.values["watch.imessage.allow"]?.array?.first?["label"])
    }

    func testWeeklyCardShape() throws {
        let json = #"{"cards":[{"item_id":"itm_1","title":"Fix the fence","kind":"reminder","category":"todo","person":"Wife","why":"no date · added 10 days ago","rank":1,"due":null,"age":10,"quote":"the fence is falling","from_me":false}],"last":{"at":"2026-11-15T23:00:00+00:00","counts":{"keep":1}},"due":true}"#
        let w = try BrainAPI.decoder.decode(Weekly.self, from: Data(json.utf8))
        XCTAssertEqual(w.cards.first?.age, 10)
        XCTAssertEqual(w.last?.counts["keep"], 1)
    }

    func testFocusShape() throws {
        let json = #"{"ok":true,"item_id":"itm_1","title":"Call the plumber","kind":"reminder","status":"active","category":"todo","person":"Wife","first_step":"Find the card","steps":["Find the number","Call"],"context":"The sink leaks","due":"2026-11-22","url":null,"timer":{"item_id":"itm_1","title":"Call the plumber","minutes":10,"ends_at":"2026-11-22T03:24:05.719+00:00","started_at":"2026-11-22T03:14:05.719+00:00"},"next":{"item_id":"itm_2","title":"Buy stamps","why":"up next"}}"#
        let f = try BrainAPI.decoder.decode(FocusDetail.self, from: Data(json.utf8))
        XCTAssertEqual(f.timer?.minutes, 10)
        XCTAssertNotNil(BrainDate.parse(f.timer?.endsAt))
        XCTAssertEqual(f.next?.title, "Buy stamps")
    }
}

final class HelperTests: XCTestCase {
    func testDates() throws {
        let a = try XCTUnwrap(BrainDate.parse("2026-11-21T21:14:05.737999-06:00"))
        let b = try XCTUnwrap(BrainDate.parse("2026-11-22T03:14:05+00:00"))
        XCTAssertEqual(a.timeIntervalSince(b), 0, accuracy: 1)
        XCTAssertNotNil(BrainDate.parse("2026-11-22T03:14:05.719+00:00"))
        XCTAssertNotNil(BrainDate.parse("2026-11-24T14:00"))
        XCTAssertEqual(BrainDate.dayString(try XCTUnwrap(BrainDate.parse("2026-11-24"))), "2026-11-24")
        XCTAssertEqual(BrainDate.clock("15:00"), "3:00 PM")
        let now = try XCTUnwrap(BrainDate.parse("2026-11-24T10:00"))
        XCTAssertEqual(BrainDate.due("2026-11-25", "09:30", now: now), "Tomorrow, 9:30 AM")
        XCTAssertEqual(BrainDate.due("2026-11-24", nil, now: now), "Today")
        XCTAssertEqual(BrainDate.ago("2026-11-24T09:55", now: now), "5 min ago")
        XCTAssertNil(BrainDate.parse("soon"))
    }

    func testServerConfig() throws {
        XCTAssertEqual(ServerConfig.parse("brain:8080")?.baseURL.absoluteString, "http://brain:8080")
        XCTAssertEqual(ServerConfig.parse(" https://b.tail1234.ts.net/ ")?.baseURL.absoluteString, "https://b.tail1234.ts.net")
        XCTAssertNil(ServerConfig.parse("ftp://x"))
        XCTAssertNil(ServerConfig.parse(""))
        XCTAssertNil(ServerConfig.parse("brain:8080", password: "")?.password)
    }

    func testURLs() throws {
        let api = BrainAPI(config: ServerConfig(baseURL: URL(string: "https://b.ts.net/sb")!))
        XCTAssertEqual(try api.url("/api/v1/events/" + BrainAPI.seg("imessage:1")).absoluteString, "https://b.ts.net/sb/api/v1/events/imessage:1")
        XCTAssertEqual(BrainAPI.seg("E1/2026"), "E1%2F2026")
        XCTAssertEqual(try api.url("/avatars/k.jpg?v=abc").absoluteString, "https://b.ts.net/sb/avatars/k.jpg?v=abc")
        XCTAssertEqual(try api.url("/api/v1/activity", query: ["q": "eggs & milk", "status": nil]).absoluteString,
                       "https://b.ts.net/sb/api/v1/activity?q=eggs%20%26%20milk")
        let r = try BrainAPI(config: ServerConfig(baseURL: URL(string: "http://b:8080")!, password: "pw")).request("GET", "/x")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("app:pw".utf8).base64EncodedString())
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Requested-With"), "fetch")
    }

    func testJSONValue() throws {
        let patch = JSONValue.nested("daily.weekly_day", "fri").merged(with: .nested("daily.weekly_time", "09:00"))
        let data = try JSONEncoder().encode(patch)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        XCTAssertEqual(back?["daily"], ["weekly_day": "fri", "weekly_time": "09:00"])
        XCTAssertEqual(JSONValue.number(3).display, "3")
        XCTAssertEqual(String(data: try JSONEncoder().encode(JSONValue.number(3)), encoding: .utf8), "3")
    }
}
