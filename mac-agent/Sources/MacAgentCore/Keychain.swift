import Foundation
#if canImport(Security)
import Security
#endif

public enum TokenSource {
    /// Reads the bearer token: Keychain generic password first, then `HA_AGENT_TOKEN`.
    public static func agentToken(service: String, account: String,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        #if canImport(Security)
        if let t = keychainPassword(service: service, account: account), !t.isEmpty { return t }
        #endif
        if let t = environment["HA_AGENT_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return nil
    }

    #if canImport(Security)
    public static func keychainPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.warn("keychain lookup for \(service)/\(account) failed: OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
