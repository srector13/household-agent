import Foundation
import XCTest
@testable import MacAgentCore

final class AvatarTests: XCTestCase {
    let wife = "+15551234567"
    let friend = "pat@example.com"

    func testSHA1KnownVectors() {
        XCTAssertEqual(SHA1.hex(Data()), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA1.hex(Data("abc".utf8)), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(SHA1.hex(Data(repeating: 0x61, count: 1000)), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    func testMatchingByPhoneAndEmailWithNulls() throws {
        let img = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
        let cards = [
            ContactCard(name: "Sam Rivera", phones: ["(555) 123-4567"], image: img),
            ContactCard(name: "  ", emails: ["Pat@Example.com"]),
            ContactCard(name: "Big", phones: ["+1 555 000 0000"], image: Data(count: AvatarMatcher.maxImageBytes + 1)),
        ]
        let people = AvatarMatcher.people(for: [wife, friend, "+1 (555) 123-4567", "+15550000000", "+19998887777"],
                                          contacts: cards)
        XCTAssertEqual(people.map(\.handle), [wife, friend, "+15550000000", "+19998887777"], "normalized, de-duplicated")
        XCTAssertEqual(people[0].name, "Sam Rivera")
        XCTAssertEqual(people[0].image, img.base64EncodedString())
        XCTAssertEqual(people[0].imageHash, SHA1.hex(img))
        XCTAssertNil(people[1].name, "blank name → null")
        XCTAssertNil(people[1].image)
        XCTAssertEqual(people[2].name, "Big")
        XCTAssertNil(people[2].image, "over 96 KB is not sent")
        XCTAssertEqual(people[3], AvatarPerson(handle: "+19998887777"))

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Wire.encoder().encode(AvatarBatch(people: people))) as? [String: Any])
        let last = try XCTUnwrap((obj["people"] as? [[String: Any]])?.last)
        XCTAssertTrue(last["name"] is NSNull)
        XCTAssertTrue(last["image"] is NSNull)
        XCTAssertTrue(last["image_hash"] is NSNull)
    }

    func testFingerprintChangesOnlyWithContent() {
        let a = [AvatarPerson(handle: "b", name: "B"), AvatarPerson(handle: "a", imageHash: "1")]
        let b = [AvatarPerson(handle: "a", imageHash: "1"), AvatarPerson(handle: "b", name: "B")]
        XCTAssertEqual(AvatarMatcher.fingerprint(a), AvatarMatcher.fingerprint(b))
        XCTAssertNotEqual(AvatarMatcher.fingerprint(a),
                          AvatarMatcher.fingerprint([AvatarPerson(handle: "a", imageHash: "2"), AvatarPerson(handle: "b", name: "B")]))
    }

    // MARK: Agent

    func makeAgent(_ server: StubBrainServer, contacts: ContactsSource, dir: URL) -> Agent {
        var cfg = AgentConfig(brainURL: server.baseURL.absoluteString, syncAllowlist: true)
        cfg.chatDBPath = dir.appendingPathComponent("missing-chat.db").path
        return Agent(config: cfg, client: BrainClient(baseURL: server.baseURL, token: "t"), store: FakeItemStore(),
                     stateURL: dir.appendingPathComponent("state.json"),
                     bufferURL: dir.appendingPathComponent("outbox.jsonl"),
                     syncedConfigURL: dir.appendingPathComponent("synced.json"),
                     contacts: contacts, avatarStateURL: dir.appendingPathComponent("avatars.json"))
    }

    func remote(_ v: Int, _ handles: [String]) -> RemoteAgentConfig {
        RemoteAgentConfig(settingsVersion: v, allow: .init(handles: handles, chatIds: []))
    }

    func avatarPosts(_ s: StubBrainServer) -> [StubBrainServer.Request] {
        s.requests.filter { $0.method == "POST" && $0.path == "/api/agent/avatars" }
    }

    func testPostsOnAllowlistChangeAndSkipsUnchanged() async throws {
        let server = try StubBrainServer { _, _, _ in (200, #"{"ok": true}"#) }
        defer { server.stop() }
        let contacts = FakeContactsSource(cards: [ContactCard(name: "Sam", phones: [wife], image: Data([1, 2, 3]))])
        let dir = tempDir()
        let agent = makeAgent(server, contacts: contacts, dir: dir)

        let before = await agent.syncAvatars()
        XCTAssertEqual(before, .skipped("no synced allowlist"))

        await agent.applyRemoteConfig(remote(1, [wife]))         // allowlist change → post
        XCTAssertEqual(avatarPosts(server).count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: avatarPosts(server)[0].body) as? [String: Any])
        let people = try XCTUnwrap(body["people"] as? [[String: Any]])
        XCTAssertEqual(people.first?["handle"] as? String, wife)
        XCTAssertEqual(people.first?["name"] as? String, "Sam")
        XCTAssertEqual(people.first?["image"] as? String, Data([1, 2, 3]).base64EncodedString())

        let again = await agent.syncAvatars()                      // daily tick, nothing changed
        XCTAssertEqual(again, .unchanged)
        await agent.applyRemoteConfig(remote(1, [wife]))           // same version → no trigger
        XCTAssertEqual(avatarPosts(server).count, 1)

        // Survives a restart: the cached fingerprint stops a duplicate post.
        let agent2 = makeAgent(server, contacts: contacts, dir: dir)
        await agent2.applyRemoteConfig(remote(1, [wife]))
        XCTAssertEqual(avatarPosts(server).count, 1)

        await contacts.setCards([ContactCard(name: "Sam R.", phones: [wife], image: Data([1, 2, 3]))])
        let renamed = await agent2.syncAvatars()
        XCTAssertEqual(renamed, .posted(1), "name change → re-post")

        await agent2.applyRemoteConfig(remote(2, [wife, friend]))  // new person
        XCTAssertEqual(avatarPosts(server).count, 3)
    }

    func testUnauthorizedSkipsSilentlyAndHeartbeatFlag() async throws {
        let server = try StubBrainServer { _, _, _ in (200, "{}") }
        defer { server.stop() }
        let contacts = FakeContactsSource(authorized: false)
        let agent = makeAgent(server, contacts: contacts, dir: tempDir())
        await agent.applyRemoteConfig(remote(1, [wife]))
        let r = await agent.syncAvatars()
        XCTAssertEqual(r, .skipped("no Contacts access"))
        XCTAssertTrue(avatarPosts(server).isEmpty)
        let lookups = await contacts.lookups
        XCTAssertEqual(lookups, 0)
        let hb = await agent.makeHeartbeat()
        XCTAssertFalse(hb.contactsOk)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Wire.encoder().encode(hb)) as? [String: Any])
        XCTAssertEqual(obj["contacts_ok"] as? Bool, false)

        await contacts.setAuthorized(true)
        let hb2 = await agent.makeHeartbeat()
        XCTAssertTrue(hb2.contactsOk)
    }

    func testOlderBrain404DisablesAvatars() async throws {
        let server = try StubBrainServer { _, _, _ in (404, #"{"detail":"Not Found"}"#) }
        defer { server.stop() }
        let agent = makeAgent(server, contacts: FakeContactsSource(), dir: tempDir())
        await agent.applyRemoteConfig(remote(1, [wife]))
        let off = await agent.avatarPostingDisabled
        XCTAssertTrue(off)
        let r = await agent.syncAvatars(force: true)
        XCTAssertEqual(r, .disabled)
        XCTAssertEqual(avatarPosts(server).count, 1)
    }

    func testFailedPostIsRetried() async throws {
        let server = try StubBrainServer { _, _, _ in (503, "busy") }
        defer { server.stop() }
        let agent = makeAgent(server, contacts: FakeContactsSource(), dir: tempDir())
        await agent.applyRemoteConfig(remote(1, [wife]))
        if case .failed = await agent.syncAvatars() {} else { XCTFail("expected a retry that fails again") }
        XCTAssertEqual(avatarPosts(server).count, 2, "fingerprint saved only after success")
    }
}
