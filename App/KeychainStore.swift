import Foundation
import Security

enum KeychainStore {
    private static let service = "meta-ati.personal-study"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "gemini-api-key"]
    }

    static func read() -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String) throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            let code = SecItemDelete(query as CFDictionary)
            guard code == errSecSuccess || code == errSecItemNotFound else { throw StoreError.failed }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(cleaned.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            code = SecItemAdd(item as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw StoreError.failed }
    }

    enum StoreError: LocalizedError {
        case failed
        var errorDescription: String? { "Your API key could not be saved securely. Unlock your iPhone and try again." }
    }
}
