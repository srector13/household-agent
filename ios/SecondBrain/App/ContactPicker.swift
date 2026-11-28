import Contacts
import ContactsUI
import UIKit

/// Apple's contact picker. It needs no Contacts permission: the user picks one person and we get
/// just that card (name, numbers, emails, photo).
@MainActor
enum ContactPicker {
    private static var delegate: Delegate?

    static func present(_ done: @escaping (PickedContact) -> Void) {
        let picker = CNContactPickerViewController()
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0 OR emailAddresses.@count > 0")
        let d = Delegate { contact in
            delegate = nil
            if let contact { done(pick(contact)) }
        }
        delegate = d
        picker.delegate = d
        top()?.present(picker, animated: true)
    }

    private static func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    static func pick(_ c: CNContact) -> PickedContact {
        let name = CNContactFormatter.string(from: c, style: .fullName) ?? [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        func label(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "other" }
        let phones = c.isKeyAvailable(CNContactPhoneNumbersKey)
            ? c.phoneNumbers.map { PickedContact.Handle(label: label($0.label), value: $0.value.stringValue) } : []
        let emails = c.isKeyAvailable(CNContactEmailAddressesKey)
            ? c.emailAddresses.map { PickedContact.Handle(label: label($0.label), value: $0.value as String) } : []
        var photo: Data?
        if c.isKeyAvailable(CNContactThumbnailImageDataKey), let d = c.thumbnailImageData ?? (c.isKeyAvailable(CNContactImageDataKey) ? c.imageData : nil) {
            photo = jpeg(d)
        }
        let nick = c.isKeyAvailable(CNContactNicknameKey) ? c.nickname : ""
        return PickedContact(name: name.isEmpty ? (phones.first?.value ?? "Someone") : name,
                             nickname: nick.isEmpty ? nil : nick, phones: phones, emails: emails, photo: photo)
    }

    /// A small square JPEG (the brain keeps photos under 200 KB).
    private static func jpeg(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side: CGFloat = 256
        let scale = side / min(img.size.width, img.size.height)
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            img.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        return out.jpegData(compressionQuality: 0.8)
    }

    private final class Delegate: NSObject, CNContactPickerDelegate {
        let done: (CNContact?) -> Void
        init(_ done: @escaping (CNContact?) -> Void) { self.done = done }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            MainActor.assumeIsolated { done(contact) }
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            MainActor.assumeIsolated { done(nil) }
        }
    }
}
