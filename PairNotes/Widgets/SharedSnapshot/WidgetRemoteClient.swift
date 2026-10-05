import Foundation
import PairNotesCore

struct WidgetRefreshResult: Sendable {
    let snapshot: NoteWidgetSnapshot?
    let couple: CoupleWidgetSnapshot?
    let avatars: [String: Data]
    let message: String
    let cached: Bool
    let expiresAt: Date?
    let needsAuthorization: Bool

    init(snapshot: NoteWidgetSnapshot?, couple: CoupleWidgetSnapshot? = nil, avatars: [String: Data] = [:],
         message: String, cached: Bool, expiresAt: Date?, needsAuthorization: Bool = false) {
        self.snapshot = snapshot; self.couple = couple; self.avatars = avatars
        self.message = message; self.cached = cached; self.expiresAt = expiresAt
        self.needsAuthorization = needsAuthorization
    }

    static func empty(_ message: String, needsAuthorization: Bool = false) -> Self {
        Self(snapshot: nil, message: message, cached: false, expiresAt: nil, needsAuthorization: needsAuthorization)
    }
}

private struct ServerWidgetNote: Decodable {
    let id: String
    let revision: UInt64
    let revisionHash: String
    let publishedAt: Date
    let authorDisplayName: String
    let imageSHA256: String
}

private struct ServerWidgetSnapshot: Decodable {
    let schemaVersion: Int
    let pairId: String
    let pairEpoch: UInt64
    let note: ServerWidgetNote?
    let generatedAt: Date
    let validUntil: Date?
    let credentialExpiresAt: Date?
    let latestGesture: CoupleGesture?
    let personalization: CouplePersonalization?
    let profiles: [CoupleProfile]?
    let startedOn: CoupleDate?
    let latestMessage: CoupleMessage?
    let distance: CoupleDistance?
}

private struct AuthorizedWidgetCache: Codable {
    let credentialHash: String
    let expiresAt: Date
    let snapshot: NoteWidgetSnapshot?
    let couple: CoupleWidgetSnapshot?
    let avatars: [String: Data]?
}

private final class WidgetNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The widget fetches the current recipient's snapshot before producing its
/// timeline. This actor coalesces simultaneous small/medium widget requests.
actor WidgetRemoteClient {
    static let shared = WidgetRemoteClient()
    private let session: URLSession
    private let authorizationProvider: @Sendable () -> WidgetAuthorization?
    private let authorizationSaver: @Sendable (WidgetAuthorization) throws -> Void
    private let directoryProvider: @Sendable () -> URL?
    private var inFlight: Task<WidgetRefreshResult, Never>?
    private var flightID: UUID?
    private var flightAuthorization: WidgetAuthorization?
    private var generation = 0
    private let maximumImageBytes = 4 * 1024 * 1024

    init(session: URLSession? = nil,
         authorization: @escaping @Sendable () -> WidgetAuthorization? = { WidgetAccessStore.load() },
         saveAuthorization: @escaping @Sendable (WidgetAuthorization) throws -> Void = { try WidgetAccessStore.save($0) },
         directory: @escaping @Sendable () -> URL? = { SharedWidgetContainer.directory() }) {
        authorizationProvider = authorization
        authorizationSaver = saveAuthorization
        directoryProvider = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: WidgetNoRedirects(), delegateQueue: nil)
    }

    func refresh() async -> WidgetRefreshResult {
        let authorization = authorizationProvider()
        if let inFlight, flightAuthorization == authorization { return await inFlight.value }
        inFlight?.cancel()
        generation += 1
        flightAuthorization = authorization
        let task = Task { await performRefresh() }
        let id = UUID()
        flightID = id
        inFlight = task
        let result = await task.value
        if flightID == id { inFlight = nil; flightID = nil; flightAuthorization = nil }
        return result
    }

    func clearCache() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        flightID = nil
        flightAuthorization = nil
        removeCache()
    }

    private var cacheURL: URL? {
        directoryProvider()?.appendingPathComponent("received-note.json")
    }

    private func removeCache() {
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    private func current(_ authorization: WidgetAuthorization, generation captured: Int) -> Bool {
        guard generation == captured, !Task.isCancelled, let latest = authorizationProvider() else { return false }
        return latest.hasSameCredential(as: authorization) && latest.isUsable()
    }

    private func request(_ name: String, authorization: WidgetAuthorization, noteID: String? = nil,
                         avatarUID: String? = nil, avatarID: String? = nil) throws -> URLRequest {
        guard authorization.isUsable() else { throw WidgetAccessError.invalidCredential }
        let url = authorization.baseURL.appendingPathComponent(name)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let noteID { components?.queryItems = [URLQueryItem(name: "noteId", value: noteID)] }
        if let avatarUID, let avatarID {
            components?.queryItems = [URLQueryItem(name: "uid", value: avatarUID), URLQueryItem(name: "avatarId", value: avatarID)]
        }
        guard let endpoint = components?.url else { throw WidgetAccessError.invalidCredential }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(authorization.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func cachedContent(for authorization: WidgetAuthorization) -> AuthorizedWidgetCache? {
        guard let url = cacheURL, let bytes = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(AuthorizedWidgetCache.self, from: bytes),
              cache.credentialHash == authorizationHash(authorization), cache.expiresAt > Date(),
              cacheIsValid(cache, for: authorization.uid) else { return nil }
        return cache
    }

    private func performRefresh() async -> WidgetRefreshResult {
        guard cacheURL != nil, let authorization = authorizationProvider(), authorization.isUsable() else {
            removeCache()
            return .empty("Tu espacio aparecerá al iniciar sesión y vincular sus cuentas.", needsAuthorization: true)
        }
        let captured = generation
        do {
            let (data, response) = try await session.data(for: request("widgetSnapshot", authorization: authorization))
            guard current(authorization, generation: captured) else { return .empty("Actualizando su espacio…") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                removeCache()
                return .empty("Actualizando su espacio…", needsAuthorization: true)
            }
            guard status == 200, data.count < 64 * 1024 else { throw URLError(.badServerResponse) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let remote = try decoder.decode(ServerWidgetSnapshot.self, from: data)
            guard remote.schemaVersion == 1, remote.pairId == authorization.pairID,
                  remote.pairEpoch == authorization.pairEpoch else {
                removeCache()
                return .empty("Actualizando su espacio…", needsAuthorization: true)
            }
            var couple: CoupleWidgetSnapshot?
            if let profiles = remote.profiles, let distance = remote.distance {
                let value = CoupleWidgetSnapshot(profiles: profiles, startedOn: remote.startedOn,
                                                  latestMessage: remote.latestMessage, distance: distance, personalization: remote.personalization, latestGesture: remote.latestGesture)
                do { try value.validate(for: authorization.uid) }
                catch { removeCache(); return .empty("Abrí PairNotes para actualizar el espacio compartido.") }
                couple = value
            }
            var snapshot: NoteWidgetSnapshot?
            if let note = remote.note {
                guard let noteID = UUID(uuidString: note.id) else { throw URLError(.cannotParseResponse) }
                let (png, imageResponse) = try await session.data(for: request("widgetImage", authorization: authorization, noteID: note.id))
                guard current(authorization, generation: captured) else { return .empty("Actualizando su espacio…") }
                let imageStatus = (imageResponse as? HTTPURLResponse)?.statusCode ?? 0
                if imageStatus == 401 || imageStatus == 403 {
                    removeCache()
                    return .empty("Actualizando su espacio…", needsAuthorization: true)
                }
                guard imageStatus == 200, !png.isEmpty, png.count <= maximumImageBytes,
                      ContentDigest.sha256(png) == note.imageSHA256 else { throw URLError(.cannotDecodeContentData) }
                let value = NoteWidgetSnapshot(noteID: noteID, revision: note.revision,
                    revisionHash: note.revisionHash, authorName: note.authorDisplayName,
                    updatedAt: note.publishedAt, pngData: png)
                try value.validate()
                snapshot = value
            }
            let previousCache = cachedContent(for: authorization)
            var avatars: [String: Data] = [:]
            for profile in couple?.profiles ?? [] {
                guard let avatar = profile.avatar else { continue }
                if let bytes = previousCache?.avatars?[profile.uid], ContentDigest.sha256(bytes) == avatar.sha256 {
                    avatars[profile.uid] = bytes
                    continue
                }
                // Replaced photos never reuse pixels from an older avatar.
                guard let (bytes, response) = try? await session.data(for: request("widgetAvatar", authorization: authorization,
                                                        avatarUID: profile.uid, avatarID: avatar.id)) else { continue }
                guard current(authorization, generation: captured) else { return .empty("Actualizando su espacio…") }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    removeCache(); return .empty("Actualizando su espacio…", needsAuthorization: true)
                }
                if status == 200, bytes.count <= 512 * 1024,
                   ContentDigest.sha256(bytes) == avatar.sha256,
                   bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { avatars[profile.uid] = bytes }
            }
            var cacheAuthorization = authorization
            if let renewed = remote.credentialExpiresAt, renewed > authorization.expiresAt {
                let updated = WidgetAuthorization(token: authorization.token, expiresAt: renewed,
                    baseURL: authorization.baseURL, uid: authorization.uid, pairID: authorization.pairID,
                    pairEpoch: authorization.pairEpoch, deviceID: authorization.deviceID,
                    apnsEnvironment: authorization.apnsEnvironment)
                guard current(authorization, generation: captured) else { return .empty("La sesión cambió.") }
                try authorizationSaver(updated)
                cacheAuthorization = updated
            }
            let expiration = min(cacheAuthorization.expiresAt, remote.validUntil ?? cacheAuthorization.expiresAt,
                                 Date().addingTimeInterval(24 * 60 * 60))
            guard expiration > Date() else { throw WidgetAccessError.invalidCredential }
            guard current(cacheAuthorization, generation: captured) else { return .empty("Actualizando su espacio…") }
            let cache = AuthorizedWidgetCache(credentialHash: authorizationHash(cacheAuthorization),
                                             expiresAt: expiration, snapshot: snapshot, couple: couple, avatars: avatars)
            if let url = cacheURL {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(cache).write(to: url, options: .atomic)
            }
            return WidgetRefreshResult(snapshot: snapshot, couple: couple, avatars: avatars,
                                       message: snapshot == nil ? "Tu próxima nota recibida aparecerá acá." : "",
                                       cached: false, expiresAt: expiration)
        } catch {
            guard current(authorization, generation: captured), let url = cacheURL,
                  let bytes = try? Data(contentsOf: url),
                  let cache = try? JSONDecoder().decode(AuthorizedWidgetCache.self, from: bytes),
                  cache.credentialHash == authorizationHash(authorization), cache.expiresAt > Date(),
                  cacheIsValid(cache, for: authorization.uid) else {
                return .empty("Esperando conexión para actualizar…")
            }
            return WidgetRefreshResult(snapshot: cache.snapshot, couple: cache.couple, avatars: cache.avatars ?? [:],
                                       message: "Datos guardados; sin conexión", cached: true, expiresAt: cache.expiresAt)
        }
    }

    private func authorizationHash(_ authorization: WidgetAuthorization) -> String {
        // Bind every private cache to the account, pair generation, endpoint and
        // credential, including locally changed configuration with the same token.
        guard let data = try? JSONEncoder().encode(authorization),
              var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        fields.removeValue(forKey: "expiresAt")
        return ContentDigest.sha256((try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)) ?? Data())
    }

    private func cacheIsValid(_ cache: AuthorizedWidgetCache, for uid: String) -> Bool {
        if let snapshot = cache.snapshot, (try? snapshot.validate()) == nil { return false }
        if let couple = cache.couple, (try? couple.validate(for: uid)) == nil { return false }
        for (uid, bytes) in cache.avatars ?? [:] {
            guard let avatar = cache.couple?.profiles.first(where: { $0.uid == uid })?.avatar,
                  bytes.count <= 512 * 1024, ContentDigest.sha256(bytes) == avatar.sha256 else { return false }
        }
        return true
    }

    /// WidgetKit delivers a token in the extension. Its scoped credential can
    /// register only this device's widget token, never an account session.
    func registerPushToken(_ token: Data, enabled: Bool) async {
        guard let authorization = authorizationProvider(), authorization.isUsable() else { return }
        do {
            var request = try request("widgetPushRegistration", authorization: authorization)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "token": token.map { String(format: "%02x", $0) }.joined(), "enabled": enabled,
                "environment": authorization.apnsEnvironment
            ])
            _ = try await session.data(for: request)
        } catch {
            // App foreground registration and future token callbacks retry;
            // tokens and credential contents must never be written to logs.
        }
    }
}
