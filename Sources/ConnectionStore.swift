import Foundation
import Security

enum ConnectionStore {
    static let service = "br.allan.pontefotos.immich"
    static let account = "saved-connection"
    struct Connection: Codable { let address: String; let key: String; var profile: ConnectionProfile? = nil; var userID: String? = nil }
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    static func save(address: String, key: String, profile: ConnectionProfile? = nil, userID: String? = nil) throws {
        try profile?.validate()
        _ = try ImmichClient(address: address, key: key)
        let data = try JSONEncoder().encode(Connection(address: address, key: key, profile: profile, userID: userID))
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    static func load() throws -> Connection? {
        var item = query; item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw BridgeError(message: "Não foi possível ler a conexão salva no Chaves.") }
        return try JSONDecoder().decode(Connection.self, from: data)
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw BridgeError(message: "Chaves do macOS: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status)).") }
    }
}
