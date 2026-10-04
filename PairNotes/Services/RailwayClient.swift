import Foundation
import Security
import PairNotesCore

struct APIError: LocalizedError {
    let status: Int
    let code: String
    var errorDescription: String? {
        switch code {
        case "recent_login_required": return "Volvé a verificar tu identidad antes de desvincular."
        case "rate_limited": return "Esperá un momento antes de volver a intentarlo."
        case "invite_expired", "invite_unavailable": return "La invitación venció o ya no está disponible."
        case "already_paired": return "Una de las cuentas ya tiene una pareja activa."
        default: return "El servicio no pudo completar la operación (\(code))."
        }
    }
}

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let identity: SessionIdentity
    let provider: String
    let providerUserID: String?

    static func decode(_ object: [String: Any], provider: String, providerUserID: String? = nil) throws -> Self {
        guard let access = object["accessToken"] as? String, access.count >= 32,
              let refresh = object["refreshToken"] as? String, refresh.count >= 32,
              let expires = object["expiresAt"] as? NSNumber, expires.doubleValue.isFinite,
              let profile = object["identity"] as? [String: Any],
              let uid = profile["uid"] as? String, !uid.isEmpty,
              let name = profile["displayName"] as? String,
              ["apple", "google"].contains(provider) else { throw ServiceError.invalidResponse }
        return Self(accessToken: access, refreshToken: refresh,
                    expiresAt: Date(timeIntervalSince1970: expires.doubleValue / 1_000),
                    identity: SessionIdentity(uid: uid, displayName: name), provider: provider, providerUserID: providerUserID)
    }
}

@MainActor
protocol AuthSessionStore {
    func read(baseURL: URL) throws -> AuthSession?
    func write(_ session: AuthSession, baseURL: URL) throws
    func clear() throws
}

/// No access group: refresh and access tokens are private to the containing app.
/// The widget uses a different, revocable read-only credential in its shared group.
@MainActor
final class PrivateSessionStore: AuthSessionStore {
    private struct Record: Codable { let baseURL: URL; let session: AuthSession }
    private let service = (Bundle.main.bundleIdentifier ?? "org.example.PairNotes") + ".auth.v1"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "session", kSecAttrSynchronizable as String: false]
    }

    func read(baseURL: URL) throws -> AuthSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ServiceError.keychain(status) }
        guard let data = value as? Data, let record = try? JSONDecoder().decode(Record.self, from: data),
              record.baseURL == baseURL else {
            try clear()
            return nil
        }
        return record.session
    }

    func write(_ session: AuthSession, baseURL: URL) throws {
        let bytes = try JSONEncoder().encode(Record(baseURL: baseURL, session: session))
        let values: [String: Any] = [kSecValueData as String: bytes,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServiceError.keychain(status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceError.keychain(status) }
    }
}

protocol HTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class APITransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        return (data, response)
    }
}

/// One refresh task per installation session. Concurrent requests reuse its result;
/// a response from an older account can never replace the active Keychain record.
@MainActor
final class RailwayClient {
    let configuration: ServiceConfiguration
    private(set) var session: AuthSession?
    var onInvalidated: (() -> Void)?
    private let store: any AuthSessionStore
    private let transport: any HTTPTransport
    private var refreshTask: Task<AuthSession, Error>?
    private var generation = UUID()

    init(configuration: ServiceConfiguration, store: any AuthSessionStore, transport: any HTTPTransport = APITransport()) throws {
        self.configuration = configuration
        self.store = store
        self.transport = transport
        session = try store.read(baseURL: configuration.apiBaseURL)
    }

    func challenge(provider: String) async throws -> (id: String, nonce: String) {
        let result = try await json(path: "auth/challenge", body: ["provider": provider])
        guard let id = result["challengeId"] as? String, let nonce = result["nonce"] as? String,
              !id.isEmpty, nonce.count >= 32 else { throw ServiceError.invalidResponse }
        return (id, nonce)
    }

    func exchange(provider: String, idToken: String, challengeID: String, providerUserID: String?,
                  expectedUID: String?, deviceID: String) async throws -> AuthSession {
        let expectedGeneration = generation
        var reauthenticationToken: String?
        if let expectedUID {
            guard let saved = session, saved.identity.uid == expectedUID else { throw ServiceError.sessionChanged }
            let current = saved.expiresAt.timeIntervalSinceNow < 60 ? try await refresh() : saved
            reauthenticationToken = current.accessToken
        }
        let result = try await json(path: "auth/exchange", body: ["provider": provider, "idToken": idToken,
            "challengeId": challengeID, "deviceId": deviceID], token: reauthenticationToken)
        let value = try AuthSession.decode(result, provider: provider, providerUserID: providerUserID)
        guard generation == expectedGeneration else { throw ServiceError.sessionChanged }
        if let expectedUID, value.identity.uid != expectedUID {
            _ = try? await json(path: "auth/signout", body: ["deviceId": deviceID], token: value.accessToken)
            throw ServiceError.sessionChanged
        }
        try store.write(value, baseURL: configuration.apiBaseURL)
        generation = UUID()
        refreshTask = nil
        session = value
        return value
    }

    func authenticatedJSON(path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> [String: Any] {
        let bytes = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await authenticatedData(path: path, method: method, body: bytes, headers: ["Content-Type": "application/json"])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceError.invalidResponse }
        return object
    }

    func authenticatedData(path: String, method: String = "GET", query: [URLQueryItem] = [],
                           body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        guard let initial = session else { throw ServiceError.signedOut }
        let expectedGeneration = generation
        var current = initial
        if initial.expiresAt.timeIntervalSinceNow < 60 { current = try await refresh() }
        try checkSession(generation: expectedGeneration, uid: initial.identity.uid)
        var request = try request(path: path, method: method, query: query, body: body, token: current.accessToken, headers: headers)
        var (data, response) = try await transport.execute(request)
        try checkSession(generation: expectedGeneration, uid: initial.identity.uid)
        if response.statusCode == 401 {
            if session?.accessToken != current.accessToken, let newer = session { current = newer }
            else { current = try await refresh() }
            try checkSession(generation: expectedGeneration, uid: initial.identity.uid)
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await transport.execute(request)
            try checkSession(generation: expectedGeneration, uid: initial.identity.uid)
        }
        if response.statusCode == 401 { clear() }
        try validate(data, response)
        return data
    }

    func refresh() async throws -> AuthSession {
        if let refreshTask { return try await refreshTask.value }
        guard let old = session else { throw ServiceError.signedOut }
        let expectedGeneration = generation
        let task = Task<AuthSession, Error> { @MainActor in
            do {
                let data = try await json(path: "auth/refresh", body: ["refreshToken": old.refreshToken])
                let value = try AuthSession.decode(data, provider: old.provider, providerUserID: old.providerUserID)
                try checkSession(generation: expectedGeneration, uid: old.identity.uid)
                guard value.identity.uid == old.identity.uid else { throw ServiceError.sessionChanged }
                // Persist the rotated token before exposing it to another request.
                try store.write(value, baseURL: configuration.apiBaseURL)
                session = value
                return value
            } catch {
                if generation == expectedGeneration, let api = error as? APIError, [401, 403].contains(api.status) { clear() }
                if generation == expectedGeneration, let serviceError = error as? ServiceError, case .keychain = serviceError { clear() }
                throw error
            }
        }
        refreshTask = task
        defer { if generation == expectedGeneration { refreshTask = nil } }
        return try await task.value
    }

    func clear() {
        generation = UUID()
        refreshTask = nil
        session = nil
        try? store.clear()
        onInvalidated?()
    }

    private func checkSession(generation expected: UUID, uid: String) throws {
        try Task.checkCancellation()
        guard generation == expected, session?.identity.uid == uid else { throw ServiceError.sessionChanged }
    }

    private func json(path: String, body: [String: Any], token: String? = nil) async throws -> [String: Any] {
        let request = try request(path: path, method: "POST", body: JSONSerialization.data(withJSONObject: body),
                                  token: token, headers: ["Content-Type": "application/json"])
        let (data, response) = try await transport.execute(request)
        try validate(data, response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceError.invalidResponse }
        return object
    }

    private func request(path: String, method: String, query: [URLQueryItem] = [], body: Data?, token: String?,
                          headers: [String: String]) throws -> URLRequest {
        guard !path.hasPrefix("/"), !path.contains(".."), !path.contains(":") else { throw ServiceError.invalidResponse }
        var components = URLComponents(url: configuration.apiBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func validate(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let code = error?["message"] as? String ?? error?["code"] as? String ?? "http_\(response.statusCode)"
            // Only accept compact error codes, never echo tokens or arbitrary server HTML.
            let safe = code.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) != nil ? code : "http_\(response.statusCode)"
            throw APIError(status: response.statusCode, code: safe)
        }
        guard data.count <= 24 * 1024 * 1024 else { throw ServiceError.invalidResponse }
    }
}
