import Foundation

// Contact photos + names for the people being watched (the synced allowlist handles only).
//
//   POST /api/agent/avatars ← {"people": [AvatarPerson]}
//
// Nothing else from Contacts is read or sent.

/// The parts of one contact the agent needs. Phones/emails are raw strings as stored in Contacts.
public struct ContactCard: Equatable, Sendable {
    public var name: String?
    public var phones: [String]
    public var emails: [String]
    /// JPEG bytes (already downscaled by the platform source), or nil if the contact has no photo.
    public var image: Data?

    public init(name: String? = nil, phones: [String] = [], emails: [String] = [], image: Data? = nil) {
        self.name = name
        self.phones = phones
        self.emails = emails
        self.image = image
    }
}

/// Abstraction over the Contacts framework so matching and posting can be tested anywhere.
public protocol ContactsSource: Sendable {
    /// Current authorization (no prompt).
    func isAuthorized() async -> Bool
    /// Prompts if undetermined. Returns the resulting authorization.
    func requestAccess() async -> Bool
    /// Contacts that may match any of the normalized `handles` (phone numbers or email addresses).
    func contacts(matching handles: [String]) async throws -> [ContactCard]
}

/// Never authorized; used where Contacts doesn't exist.
public struct NoContactsSource: ContactsSource {
    public init() {}
    public func isAuthorized() async -> Bool { false }
    public func requestAccess() async -> Bool { false }
    public func contacts(matching handles: [String]) async throws -> [ContactCard] { [] }
}

/// One entry of POST /api/agent/avatars. Optional fields are explicit nulls.
public struct AvatarPerson: Codable, Equatable, Sendable {
    public var handle: String
    public var name: String?
    public var image: String?
    public var imageHash: String?

    public init(handle: String, name: String? = nil, image: String? = nil, imageHash: String? = nil) {
        self.handle = handle
        self.name = name
        self.image = image
        self.imageHash = imageHash
    }

    enum CodingKeys: String, CodingKey { case handle, name, image, imageHash }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(handle, forKey: .handle)
        try c.encode(name, forKey: .name)
        try c.encode(image, forKey: .image)
        try c.encode(imageHash, forKey: .imageHash)
    }
}

struct AvatarBatch: Encodable, Sendable {
    var people: [AvatarPerson]
}

public enum AvatarMatcher {
    /// Largest image sent, in bytes (before base64).
    public static let maxImageBytes = 96 * 1024

    /// One entry per handle (in the given order, normalized, de-duplicated). Unmatched → nulls.
    public static func people(for handles: [String], contacts: [ContactCard]) -> [AvatarPerson] {
        var seen = Set<String>()
        var out: [AvatarPerson] = []
        for raw in handles {
            let handle = HandleNormalizer.normalize(raw)
            guard !handle.isEmpty, seen.insert(handle).inserted else { continue }
            guard let card = contacts.first(where: { matches($0, handle: handle) }) else {
                out.append(AvatarPerson(handle: handle))
                continue
            }
            let name = card.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            var person = AvatarPerson(handle: handle, name: (name?.isEmpty ?? true) ? nil : name)
            if let img = card.image, !img.isEmpty, img.count <= maxImageBytes {
                person.image = img.base64EncodedString()
                person.imageHash = SHA1.hex(img)
            }
            out.append(person)
        }
        return out
    }

    public static func matches(_ card: ContactCard, handle: String) -> Bool {
        if handle.contains("@") {
            return card.emails.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == handle }
        }
        return card.phones.contains { HandleNormalizer.normalize($0) == handle }
    }

    /// Changes whenever a handle, name or photo changes; used to skip re-posting identical data.
    public static func fingerprint(_ people: [AvatarPerson]) -> String {
        let line = people.sorted { $0.handle < $1.handle }
            .map { "\($0.handle)|\($0.name ?? "")|\($0.imageHash ?? "")" }
            .joined(separator: "\n")
        return SHA1.hex(Data(line.utf8))
    }
}

/// What was last posted successfully (Application Support/HouseholdAgent/avatars.json).
public struct AvatarState: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var postedAt: String

    public static func load(from url: URL) -> AvatarState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AvatarState.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Minimal SHA-1 (CryptoKit isn't available on Linux, where the core is tested). Used only for change
/// detection / cache keys, not for security.
public enum SHA1 {
    public static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> [UInt8] {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<80 {
                let v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (v << 1) | (v >> 31)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        var out: [UInt8] = []
        for h in [h0, h1, h2, h3, h4] {
            out += [UInt8(h >> 24), UInt8((h >> 16) & 0xff), UInt8((h >> 8) & 0xff), UInt8(h & 0xff)]
        }
        return out
    }
}
