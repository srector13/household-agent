import Foundation
import SecondBrainKit

/// The Today widget can't read the app's settings (no App Group, so any certificate can re-sign the
/// app). Instead the app shows a short code — the brain's address and password — and you paste it
/// once when you edit the widget.
enum WidgetConnection {
    static let prefix = "sb1:"

    static func code(for cfg: ServerConfig) -> String {
        var obj = ["u": cfg.baseURL.absoluteString]
        if let pw = cfg.password { obj["p"] = pw }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return prefix + data.base64EncodedString()
    }

    static func config(from code: String?) -> ServerConfig? {
        guard var s = code?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            guard let data = Data(base64Encoded: s),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let u = obj["u"] else { return nil }
            return ServerConfig.parse(u, password: obj["p"])
        }
        return ServerConfig.parse(s)   // a bare address works for a brain without a password
    }
}
