import Foundation
import PairNotesCore

struct WidgetRefreshResult: Sendable {
    let snapshot: NoteWidgetSnapshot?
    let message: String
    let cached: Bool
    let expiresAt: Date?

    static func empty(_ message: String) -> Self {
        Self(snapshot: nil, message: message, cached: false, expiresAt: nil)
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
}

private struct AuthorizedWidgetCache: Codable {
    let credentialHash: String
    let expiresAt: Date
    let snapshot: NoteWidgetSnapshot
}

/// The widget fetches the current recipient's snapshot before producing its
/// timeline. This actor coalesces simultaneous small/medium widget requests.
actor WidgetRemoteClient {
    static let shared = WidgetRemoteClient()
    private let session: URLSession
    private let authorizationProvider: @Sendable () -> WidgetAuthorization?
    private let directoryProvider: @Sendable () -> URL?
    private var inFlight: Task<WidgetRefreshResult, Never>?
    private var flightID: UUID?
    private var generation = 0
    private let maximumImageBytes = 4 * 1024 * 1024

    init(session: URLSession? = nil,
         authorization: @escaping @Sendable () -> WidgetAuthorization? = { WidgetAccessStore.load() },
         directory: @escaping @Sendable () -> URL? = { SharedWidgetContainer.directory() }) {
        authorizationProvider = authorization
        directoryProvider = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
    }

    func refresh() async -> WidgetRefreshResult {
        if let inFlight { return await inFlight.value }
        let task = Task { await performRefresh() }
        let id = UUID()
        flightID = id
        inFlight = task
        let result = await task.value
        if flightID == id { inFlight = nil; flightID = nil }
        return result
    }

    func clearCache() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        flightID = nil
        removeCache()
    }

    private var cacheURL: URL? {
        directoryProvider()?.appendingPathComponent("received-note.json")
    }

    private func removeCache() {
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    private func current(_ authorization: WidgetAuthorization, generation captured: Int) -> Bool {
        generation == captured && !Task.isCancelled && authorizationProvider() == authorization && authorization.isUsable()
    }

    private func request(_ name: String, authorization: WidgetAuthorization, noteID: String? = nil) throws -> URLRequest {
        guard authorization.isUsable() else { throw WidgetAccessError.invalidCredential }
        let url = authorization.baseURL.appendingPathComponent(name)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let noteID { components?.queryItems = [URLQueryItem(name: "noteId", value: noteID)] }
        guard let endpoint = components?.url else { throw WidgetAccessError.invalidCredential }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(authorization.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func performRefresh() async -> WidgetRefreshResult {
        guard cacheURL != nil, let authorization = authorizationProvider(), authorization.isUsable() else {
            removeCache()
            return .empty("Abrí PairNotes para conectar el widget.")
        }
        let captured = generation
        do {
            let (data, response) = try await session.data(for: request("widgetSnapshot", authorization: authorization))
            guard current(authorization, generation: captured) else { return .empty("Abrí PairNotes para actualizar la sesión.") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                removeCache()
                return .empty("Abrí PairNotes para volver a conectar el widget.")
            }
            guard status == 200, data.count < 64 * 1024 else { throw URLError(.badServerResponse) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let remote = try decoder.decode(ServerWidgetSnapshot.self, from: data)
            guard remote.schemaVersion == 1, remote.pairId == authorization.pairID,
                  remote.pairEpoch == authorization.pairEpoch else {
                removeCache()
                return .empty("La pareja cambió. Abrí PairNotes para reconectar.")
            }
            guard let note = remote.note else {
                removeCache()
                return .empty("Tu próxima nota recibida aparecerá acá.")
            }
            guard let noteID = UUID(uuidString: note.id) else {
                throw URLError(.cannotParseResponse)
            }
            let (png, imageResponse) = try await session.data(for: request("widgetImage", authorization: authorization, noteID: note.id))
            guard current(authorization, generation: captured) else { return .empty("La sesión cambió. Abrí PairNotes.") }
            let imageStatus = (imageResponse as? HTTPURLResponse)?.statusCode ?? 0
            if imageStatus == 401 || imageStatus == 403 {
                removeCache()
                return .empty("Abrí PairNotes para volver a conectar el widget.")
            }
            guard imageStatus == 200, !png.isEmpty, png.count <= maximumImageBytes,
                  ContentDigest.sha256(png) == note.imageSHA256 else { throw URLError(.cannotDecodeContentData) }
            let snapshot = NoteWidgetSnapshot(noteID: noteID, revision: note.revision,
                revisionHash: note.revisionHash, authorName: note.authorDisplayName,
                updatedAt: note.publishedAt, pngData: png)
            try snapshot.validate()
            let expiration = min(authorization.expiresAt, remote.validUntil ?? authorization.expiresAt)
            guard expiration > Date() else { throw WidgetAccessError.invalidCredential }
            let cache = AuthorizedWidgetCache(credentialHash: ContentDigest.sha256(Data(authorization.token.utf8)),
                                             expiresAt: expiration, snapshot: snapshot)
            if let url = cacheURL {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(cache).write(to: url, options: .atomic)
            }
            return WidgetRefreshResult(snapshot: snapshot, message: "", cached: false, expiresAt: expiration)
        } catch {
            guard current(authorization, generation: captured), let url = cacheURL,
                  let bytes = try? Data(contentsOf: url),
                  let cache = try? JSONDecoder().decode(AuthorizedWidgetCache.self, from: bytes),
                  cache.credentialHash == ContentDigest.sha256(Data(authorization.token.utf8)), cache.expiresAt > Date(),
                  (try? cache.snapshot.validate()) != nil else {
                return .empty("No se pudo actualizar. Abrí PairNotes para reintentar.")
            }
            return WidgetRefreshResult(snapshot: cache.snapshot, message: "Última nota guardada", cached: true, expiresAt: cache.expiresAt)
        }
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
