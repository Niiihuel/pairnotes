import Foundation
import PairNotesCore

struct WidgetRefreshResult: Sendable {
    let snapshot: NoteWidgetSnapshot?
    let couple: CoupleWidgetSnapshot?
    let avatars: [String: Data]
    let photoData: Data?
    let photoInteractionMessage: String?
    let message: String
    let cached: Bool
    let expiresAt: Date?
    let needsAuthorization: Bool
    let locationAccess: WidgetLocationAccess?

    init(snapshot: NoteWidgetSnapshot?, couple: CoupleWidgetSnapshot? = nil, avatars: [String: Data] = [:], photoData: Data? = nil,
         photoInteractionMessage: String? = nil,
         message: String, cached: Bool, expiresAt: Date?, needsAuthorization: Bool = false,
         locationAccess: WidgetLocationAccess? = nil) {
        self.snapshot = snapshot; self.couple = couple; self.avatars = avatars
        self.photoData = photoData
        self.photoInteractionMessage = photoInteractionMessage
        self.message = message; self.cached = cached; self.expiresAt = expiresAt
        self.needsAuthorization = needsAuthorization
        self.locationAccess = locationAccess
    }

    static func empty(_ message: String, needsAuthorization: Bool = false) -> Self {
        Self(snapshot: nil, message: message, cached: false, expiresAt: nil, needsAuthorization: needsAuthorization)
    }
}

struct WidgetLocationAccess: Decodable, Sendable {
    let consentVersion: UInt64
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
    let latestPhoto: CouplePhoto?
    let distance: CoupleDistance?
    let locationAccess: WidgetLocationAccess?
}

private struct AuthorizedWidgetCache: Codable {
    let credentialHash: String
    let expiresAt: Date
    let snapshot: NoteWidgetSnapshot?
    let couple: CoupleWidgetSnapshot?
    let avatars: [String: Data]?
    let photoData: Data?
    let photoFeedback: PhotoInteractionFeedback?
}

private struct PhotoInteractionFeedback: Codable {
    let photoID: String
    let message: String
    let expiresAt: Date
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
    private var authorizationGeneration = 0
    private let locationSampler: @Sendable () async -> WidgetLocationSample?
    private var distanceFlight: (id: UUID, authorization: WidgetAuthorization, task: Task<WidgetRefreshResult, Never>)?
    private var lastLocationAttempt: (authorization: WidgetAuthorization, date: Date)?
    private let maximumImageBytes = 4 * 1024 * 1024
    private let maximumPhotoBytes = 5 * 1024 * 1024

    init(session: URLSession? = nil,
         authorization: @escaping @Sendable () -> WidgetAuthorization? = { WidgetAccessStore.load() },
         saveAuthorization: @escaping @Sendable (WidgetAuthorization) throws -> Void = { try WidgetAccessStore.save($0) },
         sampleLocation: @escaping @Sendable () async -> WidgetLocationSample? = { await WidgetLocationSampler().sample() },
         directory: @escaping @Sendable () -> URL? = { SharedWidgetContainer.directory() }) {
        authorizationProvider = authorization
        authorizationSaver = saveAuthorization
        directoryProvider = directory
        locationSampler = sampleLocation
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

    /// Only the distance provider requests a measurement. Other widgets and the
    /// app keep their ordinary refresh path and never start Location Services.
    func refreshDistance() async -> WidgetRefreshResult {
        guard let authorization = authorizationProvider(), authorization.isUsable() else { return await refresh() }
        if let flight = distanceFlight, flight.authorization.hasSameCredential(as: authorization) {
            return await flight.task.value
        }
        distanceFlight?.task.cancel()
        let id = UUID()
        let task = Task { await performDistanceRefresh(authorization) }
        distanceFlight = (id, authorization, task)
        let result = await task.value
        if distanceFlight?.id == id { distanceFlight = nil }
        return result
    }

    private func performDistanceRefresh(_ authorization: WidgetAuthorization) async -> WidgetRefreshResult {
        let captured = authorizationGeneration
        let result = await refresh()
        func stillCurrent() -> Bool {
            guard authorizationGeneration == captured, !Task.isCancelled,
                  let latest = authorizationProvider(), latest.isUsable() else { return false }
            return latest.hasSameCredential(as: authorization)
        }
        guard stillCurrent() else { return .empty("Actualizando su espacio…") }
        guard !result.cached, !result.needsAuthorization, let access = result.locationAccess,
              access.consentVersion > 0, access.consentVersion <= 9_007_199_254_740_991 else { return result }
        if let previous = lastLocationAttempt, previous.authorization.hasSameCredential(as: authorization),
           Date().timeIntervalSince(previous.date) < 5 * 60 { return result }
        lastLocationAttempt = (authorization, Date())
        let measured = await locationSampler()
        guard stillCurrent() else { return .empty("Actualizando su espacio…") }
        guard let sample = measured, sample.isUsable() else { return result }
        do {
            // This narrow credential cannot enable sharing or choose a person,
            // pair or device. The server checks the consent again at write time.
            guard let latest = authorizationProvider() else { return .empty("Actualizando su espacio…") }
            var request = try request("widgetLocation", authorization: latest)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "consentVersion": access.consentVersion, "latitude": sample.latitude, "longitude": sample.longitude,
                "horizontalAccuracy": sample.horizontalAccuracy,
                "capturedAt": Int64(sample.capturedAt.timeIntervalSince1970 * 1_000)
            ])
            let (_, response) = try await session.data(for: request)
            guard stillCurrent() else { return .empty("Actualizando su espacio…") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                // A pause or replaced source must not leave a previous distance
                // on screen. Re-fetch the authorized snapshot without measuring.
                invalidateSnapshotFlight()
                removeCache()
                return await refresh()
            }
            guard status == 200 else { return result }
            return await refresh()
        } catch {
            return stillCurrent() ? result : .empty("Actualizando su espacio…")
        }
    }

    func clearCache() {
        invalidateSnapshotFlight()
        authorizationGeneration += 1
        distanceFlight?.task.cancel()
        distanceFlight = nil
        lastLocationAttempt = nil
        removeCache()
    }

    private func invalidateSnapshotFlight() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        flightID = nil
        flightAuthorization = nil
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
                         avatarUID: String? = nil, avatarID: String? = nil,
                         photoID: String? = nil, assetID: String? = nil) throws -> URLRequest {
        guard authorization.isUsable() else { throw WidgetAccessError.invalidCredential }
        let url = authorization.baseURL.appendingPathComponent(name)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let noteID { components?.queryItems = [URLQueryItem(name: "noteId", value: noteID)] }
        if let avatarUID, let avatarID {
            components?.queryItems = [URLQueryItem(name: "uid", value: avatarUID), URLQueryItem(name: "avatarId", value: avatarID)]
        }
        if let photoID, let assetID {
            components?.queryItems = [URLQueryItem(name: "photoId", value: photoID), URLQueryItem(name: "assetId", value: assetID)]
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
                                                  latestMessage: remote.latestMessage, distance: distance, personalization: remote.personalization, latestGesture: remote.latestGesture,
                                                  latestPhoto: remote.latestPhoto)
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
            var photoData: Data?
            if let photo = couple?.latestPhoto {
                if let bytes = previousCache?.photoData, ContentDigest.sha256(bytes) == photo.photo.sha256 {
                    photoData = bytes
                } else {
                    let (bytes, response) = try await session.data(for: request("widgetPhoto", authorization: authorization,
                                                                           photoID: photo.id, assetID: photo.photo.id))
                    guard current(authorization, generation: captured) else { return .empty("Actualizando su espacio…") }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 401 || status == 403 {
                        removeCache(); return .empty("Actualizando su espacio…", needsAuthorization: true)
                    }
                    guard status == 200, !bytes.isEmpty, bytes.count <= maximumPhotoBytes,
                          bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                          ContentDigest.sha256(bytes) == photo.photo.sha256 else {
                        removeCache()
                        return .empty("Abrí PairNotes para actualizar la foto recibida.")
                    }
                    photoData = bytes
                }
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
            let feedback = previousCache?.photoFeedback.flatMap {
                $0.expiresAt > Date() && $0.photoID == couple?.latestPhoto?.id ? $0 : nil
            }
            let cache = AuthorizedWidgetCache(credentialHash: authorizationHash(cacheAuthorization),
                                             expiresAt: expiration, snapshot: snapshot, couple: couple, avatars: avatars, photoData: photoData,
                                             photoFeedback: feedback)
            if let url = cacheURL {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(cache).write(to: url, options: .atomic)
            }
            return WidgetRefreshResult(snapshot: snapshot, couple: couple, avatars: avatars, photoData: photoData,
                                       photoInteractionMessage: feedback?.message,
                                       message: snapshot == nil ? "Tu próxima nota recibida aparecerá acá." : "",
                                       cached: false, expiresAt: expiration, locationAccess: remote.locationAccess)
        } catch {
            guard current(authorization, generation: captured), let url = cacheURL,
                  let bytes = try? Data(contentsOf: url),
                  let cache = try? JSONDecoder().decode(AuthorizedWidgetCache.self, from: bytes),
                  cache.credentialHash == authorizationHash(authorization), cache.expiresAt > Date(),
                  cacheIsValid(cache, for: authorization.uid) else {
                return .empty("Esperando conexión para actualizar…")
            }
            return WidgetRefreshResult(snapshot: cache.snapshot, couple: cache.couple, avatars: cache.avatars ?? [:], photoData: cache.photoData,
                                       photoInteractionMessage: cache.photoFeedback.flatMap { $0.expiresAt > Date() ? $0.message : nil },
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
        if let bytes = cache.photoData {
            guard let photo = cache.couple?.latestPhoto, !bytes.isEmpty, bytes.count <= maximumPhotoBytes,
                  bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  ContentDigest.sha256(bytes) == photo.photo.sha256 else { return false }
        }
        return true
    }

    /// A widget credential can react only to the current received photo. The
    /// server confirms the change before the widget shows a selected reaction.
    func reactToPhoto(photoID: String, assetID: String, kind: PhotoReactionKind) async throws -> PhotoReaction {
        guard UUID(uuidString: photoID) != nil, UUID(uuidString: assetID) != nil,
              let authorization = authorizationProvider(), authorization.isUsable() else {
            throw WidgetAccessError.invalidCredential
        }
        generation += 1
        inFlight?.cancel()
        inFlight = nil; flightID = nil; flightAuthorization = nil
        let captured = authorizationGeneration
        var request = try request("widgetPhotoReaction", authorization: authorization)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["photoId": photoID, "assetId": assetID, "kind": kind.rawValue])
        let (bytes, response) = try await session.data(for: request)
        guard !Task.isCancelled, captured == authorizationGeneration,
              let latest = authorizationProvider(), latest.hasSameCredential(as: authorization), latest.isUsable() else {
            throw WidgetAccessError.invalidCredential
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { removeCache(); throw WidgetAccessError.invalidCredential }
        guard status == 200, bytes.count <= 8 * 1024 else { throw URLError(.badServerResponse) }
        struct Response: Decodable { let reaction: PhotoReaction }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let reaction = try decoder.decode(Response.self, from: bytes).reaction
        guard reaction.photoId == photoID, reaction.authorId == authorization.uid, reaction.kind == kind,
              reaction.updatedAt.timeIntervalSince1970.isFinite,
              reaction.updatedAt <= Date().addingTimeInterval(60) else { throw URLError(.cannotParseResponse) }
        if let cache = cachedContent(for: authorization), let couple = cache.couple,
           let photo = couple.latestPhoto, photo.id == photoID, photo.photo.id == assetID {
            let updatedPhoto = CouplePhoto(id: photo.id, authorId: photo.authorId, recipientId: photo.recipientId,
                                          caption: photo.caption, photo: photo.photo, sentAt: photo.sentAt, reaction: reaction)
            let updated = CoupleWidgetSnapshot(profiles: couple.profiles, startedOn: couple.startedOn,
                                              latestMessage: couple.latestMessage, distance: couple.distance,
                                              personalization: couple.personalization, latestGesture: couple.latestGesture, latestPhoto: updatedPhoto)
            try updated.validate(for: authorization.uid)
            let cache = AuthorizedWidgetCache(credentialHash: cache.credentialHash, expiresAt: cache.expiresAt,
                                              snapshot: cache.snapshot, couple: updated, avatars: cache.avatars, photoData: cache.photoData, photoFeedback: nil)
            if let url = cacheURL { try JSONEncoder().encode(cache).write(to: url, options: .atomic) }
        }
        return reaction
    }

    func recordPhotoInteractionFailure(photoID: String) {
        guard let authorization = authorizationProvider(), authorization.isUsable(),
              let cache = cachedContent(for: authorization), cache.couple?.latestPhoto?.id == photoID,
              let url = cacheURL else { return }
        let feedback = PhotoInteractionFeedback(photoID: photoID, message: "No se envió. Tocá la reacción para reintentar.",
                                                expiresAt: Date().addingTimeInterval(5 * 60))
        let updated = AuthorizedWidgetCache(credentialHash: cache.credentialHash, expiresAt: cache.expiresAt,
                                            snapshot: cache.snapshot, couple: cache.couple, avatars: cache.avatars,
                                            photoData: cache.photoData, photoFeedback: feedback)
        try? JSONEncoder().encode(updated).write(to: url, options: .atomic)
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
