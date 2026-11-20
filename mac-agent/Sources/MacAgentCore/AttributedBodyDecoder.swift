import Foundation

/// Extracts the plain text from `message.attributedBody`, a typedstream-archived
/// NSAttributedString (the format written by the legacy `NSArchiver`).
///
/// Since macOS Ventura many messages have `text = NULL` and only this blob. The layout is:
///
///     04 0B "streamtyped" 81 E8 03 84 01 40 84 84 84 "NSMutableAttributedString" 00
///     84 84 "NSAttributedString" 00 84 84 08 "NSObject" 00 85 92 84 84 84 08 "NSString" 01 94
///     84 01 2B <length> <UTF-8 bytes> 86 84 ...
///
/// i.e. after the NSString class record comes a `+` (0x2B, "C string with length") type tag, then a
/// typedstream integer length, then the UTF-8 bytes. Integers are encoded as a single byte when
/// < 0x80, otherwise 0x81 + Int16 LE or 0x82 + Int32 LE.
public enum AttributedBodyDecoder {
    private static let markers: [[UInt8]] = [Array("NSString".utf8), Array("NSMutableString".utf8)]
    private static let plusTag: UInt8 = 0x2B
    /// How far past the class name we look for the `+` tag (class version + reference bytes).
    private static let searchWindow = 16

    public static func decode(_ data: Data, allowNSUnarchiverFallback: Bool = false) -> String? {
        if let s = decodeTypedStream([UInt8](data)) { return s }
        #if canImport(AppKit)
        if allowNSUnarchiverFallback { return decodeWithNSUnarchiver(data) }
        #endif
        return nil
    }

    /// Pure-Swift parser; returns nil for anything that does not look like an archived string.
    public static func decodeTypedStream(_ bytes: [UInt8]) -> String? {
        for marker in markers {
            var searchFrom = 0
            while let markerIndex = indexOf(marker, in: bytes, from: searchFrom) {
                searchFrom = markerIndex + 1
                let afterMarker = markerIndex + marker.count
                let windowEnd = min(bytes.count, afterMarker + searchWindow)
                guard afterMarker < windowEnd,
                      let plus = bytes[afterMarker..<windowEnd].firstIndex(of: plusTag) else { continue }
                if let s = readLengthPrefixedString(bytes, at: plus + 1) {
                    return s
                }
            }
        }
        return nil
    }

    static func readLengthPrefixedString(_ bytes: [UInt8], at start: Int) -> String? {
        guard start < bytes.count else { return nil }
        var i = start
        let lead = bytes[i]
        i += 1
        let length: Int
        switch lead {
        case 0x81:
            guard i + 2 <= bytes.count else { return nil }
            length = Int(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            i += 2
        case 0x82:
            guard i + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            length = Int(v)
            i += 4
        case 0x00..<0x80:
            length = Int(lead)
        default:
            return nil
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        guard let s = String(bytes: bytes[i..<(i + length)], encoding: .utf8) else { return nil }
        return s
    }

    static func indexOf(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, from <= haystack.count - needle.count else { return nil }
        let first = needle[0]
        var i = from
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var match = true
                for j in 1..<needle.count where haystack[i + j] != needle[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    #if canImport(AppKit)
    /// Uses the deprecated NSUnarchiver. Only reached when the pure parser fails AND the caller
    /// opted in, because malformed input can raise an Objective-C exception that Swift cannot catch.
    static func decodeWithNSUnarchiver(_ data: Data) -> String? {
        let header = Data("streamtyped".utf8)
        guard data.count > 16, data.range(of: header, in: 0..<min(data.count, 16)) != nil else { return nil }
        guard let obj = NSUnarchiver.unarchiveObject(with: data) else { return nil }
        if let s = obj as? NSAttributedString { return s.string }
        if let s = obj as? String { return s }
        return nil
    }
    #endif
}
