import XCTest
@testable import MacAgentCore

final class AttributedBodyDecoderTests: XCTestCase {
    func testShortString() {
        let blob = makeAttributedBody("Can you grab eggs tomorrow? We're out")
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), "Can you grab eggs tomorrow? We're out")
    }

    func testMutableStringMarker() {
        let blob = makeAttributedBody("pick up the kids at 3", mutable: true)
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), "pick up the kids at 3")
    }

    func testTwoByteLength() {
        let long = String(repeating: "milk eggs bread ", count: 40) // 640 bytes → 0x81 prefix
        XCTAssertGreaterThan(long.utf8.count, 0x7F)
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttributedBody(long)), long)
    }

    func testFourByteLength() {
        let huge = String(repeating: "a", count: 70_000) // > UInt16 → 0x82 prefix
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttributedBody(huge)), huge)
    }

    func testUnicodeAndEmoji() {
        let s = "Café at 5? 🥚🥛 “quotes” — ok 👍🏽"
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttributedBody(s)), s)
    }

    func testLengthBoundary127() {
        let s = String(repeating: "x", count: 127)
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttributedBody(s)), s)
        let s128 = String(repeating: "y", count: 128)
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttributedBody(s128)), s128)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(AttributedBodyDecoder.decode(Data()))
        XCTAssertNil(AttributedBodyDecoder.decode(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(AttributedBodyDecoder.decode(Data((0..<512).map { UInt8($0 % 251) })))
        XCTAssertNil(AttributedBodyDecoder.decode(Data("NSString".utf8)))
    }

    func testTruncatedBlobReturnsNil() {
        let blob = makeAttributedBody("hello there friend")
        // Cut in the middle of the string bytes.
        let cut = blob.prefix(blob.count - 120)
        XCTAssertNil(AttributedBodyDecoder.decode(Data(cut)))
    }

    func testInvalidUTF8ReturnsNil() {
        var b = [UInt8](makeAttributedBody("abcd"))
        let idx = AttributedBodyDecoder.indexOf(Array("abcd".utf8), in: b, from: 0)!
        b[idx] = 0xFF
        b[idx + 1] = 0xFE
        XCTAssertNil(AttributedBodyDecoder.decode(Data(b)))
    }

    func testBodyTextPrefersTextColumnAndStripsPlaceholder() {
        XCTAssertEqual(MessagesDatabase.bodyText(text: "hi", attributedBody: makeAttributedBody("other")), "hi")
        XCTAssertEqual(MessagesDatabase.bodyText(text: nil, attributedBody: makeAttributedBody("other")), "other")
        XCTAssertEqual(MessagesDatabase.bodyText(text: "", attributedBody: makeAttributedBody("blob")), "blob")
        XCTAssertNil(MessagesDatabase.bodyText(text: "\u{FFFC}", attributedBody: nil))
        XCTAssertEqual(MessagesDatabase.bodyText(text: "\u{FFFC}look at this", attributedBody: nil), "look at this")
    }
}
