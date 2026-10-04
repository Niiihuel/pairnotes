import Foundation
import Security

/// A revocable credential for the recipient's current widget only. Account
/// refresh tokens and provider credentials never enter the shared container.
struct WidgetAuthorization: Codable, Equatable, Sendable {
    let token: String
    let expiresAt: Date
    let baseURL: URL
    let uid: String
    let pairID: String
    let pairEpoch: UInt64
    let deviceID: String
    let apnsEnvironment: String

    func isUsable(at date: Date = Date()) -> Bool {
        guard token.count >= 32, expiresAt > date, !uid.isEmpty,
              !pairID.isEmpty, pairEpoch > 0, !deviceID.isEmpty,
              ["development", "production"].contains(apnsEnvironment) else { return false }
        guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil else { return false }
        if baseURL.scheme == "https", let host = baseURL.host, !host.isEmpty { return true }
        #if DEBUG
        return baseURL.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "")
        #else
        return false
        #endif
    }
}

enum WidgetAccessError: Error, LocalizedError {
    case notConfigured
    case keychain(OSStatus)
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "El acceso compartido del widget aún no está configurado en esta instalación."
        case .keychain: return "No se pudo guardar el acceso del widget de forma segura."
        case .invalidCredential: return "El acceso del widget venció. Volvé a conectarlo desde la app."
        }
    }
}

enum WidgetAccessStore {
    private static let service = "PairNotes.WidgetSnapshotAccess.v1"
    private static let account = "current-recipient"

    private static func query() throws -> [String: Any] {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PAIRNOTES_KEYCHAIN_GROUP") as? String else {
            throw WidgetAccessError.notConfigured
        }
        let group = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.isEmpty, !group.contains("$(") else { throw WidgetAccessError.notConfigured }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group]
    }

    static func save(_ authorization: WidgetAuthorization) throws {
        guard authorization.isUsable() else { throw WidgetAccessError.invalidCredential }
        let data = try JSONEncoder().encode(authorization)
        var item = try query()
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(item as CFDictionary, values as CFDictionary)
        if updated == errSecItemNotFound {
            item.merge(values) { _, new in new }
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw WidgetAccessError.keychain(inserted) }
        } else if updated != errSecSuccess {
            throw WidgetAccessError.keychain(updated)
        }
    }

    static func load() -> WidgetAuthorization? {
        guard var item = try? query() else { return nil }
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetAuthorization.self, from: data)
    }

    static func clear() {
        guard let item = try? query() else { return }
        SecItemDelete(item as CFDictionary)
    }
}
