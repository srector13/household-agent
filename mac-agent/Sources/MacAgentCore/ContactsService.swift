#if canImport(Contacts)
import Contacts
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads names + photos for the watched handles from Contacts. Only the keys below are fetched.
public final class SystemContactsSource: ContactsSource, @unchecked Sendable {
    // CNContactStore is thread-safe for fetches; @unchecked because it isn't marked Sendable.
    private let store = CNContactStore()

    public init() {}

    public func isAuthorized() async -> Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    public func requestAccess() async -> Bool {
        if await isAuthorized() { return true }
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return false }
        do { return try await store.requestAccess(for: .contacts) } catch {
            Log.warn("Contacts access request failed: \(error)")
            return false
        }
    }

    public func contacts(matching handles: [String]) async throws -> [ContactCard] {
        guard await isAuthorized() else { return [] }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
        ]
        var byID: [String: CNContact] = [:]
        for handle in handles {
            let predicate: NSPredicate = handle.contains("@")
                ? CNContact.predicateForContacts(matchingEmailAddress: handle)
                : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
            for c in try store.unifiedContacts(matching: predicate, keysToFetch: keys) { byID[c.identifier] = c }
        }
        return byID.values.map { c in
            ContactCard(
                name: CNContactFormatter.string(from: c, style: .fullName),
                phones: c.phoneNumbers.map { $0.value.stringValue },
                emails: c.emailAddresses.map { $0.value as String },
                image: Self.jpeg(thumbnail: c.thumbnailImageData,
                                 full: c.imageDataAvailable ? c.imageData : nil))
        }
    }

    /// ≤256 px JPEG that fits AvatarMatcher.maxImageBytes, or nil.
    static func jpeg(thumbnail: Data?, full: Data?) -> Data? {
        for source in [thumbnail, full].compactMap({ $0 }) {
            for quality in [0.8, 0.6, 0.4] {
                if let d = downscaled(source, maxPixels: 256, quality: quality), d.count <= AvatarMatcher.maxImageBytes {
                    return d
                }
            }
        }
        return nil
    }

    private static func downscaled(_ data: Data, maxPixels: Int, quality: Double) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
#endif
