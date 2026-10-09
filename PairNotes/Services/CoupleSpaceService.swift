import Foundation
import PairNotesCore
import WidgetKit

struct CoupleLocationState: Decodable, Equatable {
    let sharingEnabled: Bool
    let sourceDeviceId: String?
    let consentVersion: UInt64
    let distance: CoupleDistance
}

struct CoupleSpaceState: Decodable, Equatable {
    let profiles: [CoupleProfile]
    let startedOn: CoupleDate?
    let latestMessage: CoupleMessage?
    var memories: [SharedMemory]
    let location: CoupleLocationState
    var latestGesture: CoupleGesture?
    var personalization: CouplePersonalization?
    var latestPhoto: CouplePhoto?
}

extension AppServices {
    func refreshCoupleSpace() async throws {
        let uid = try requireUID()
        guard let pair = membership else { coupleSpace = nil; return }
        spaceSequence &+= 1
        let sequence = spaceSequence
        let response = try await call("getCoupleSpace", pairPayload(pair))
        try checkSpaceContext(uid: uid, pair: pair)
        guard sequence == spaceSequence else { return }
        let value: CoupleSpaceState = try decodeSpace(response)
        guard value.profiles.count == 2, Set(value.profiles.map(\.uid)) == Set(pair.memberIDs) else {
            throw ServiceError.invalidResponse
        }
        for memory in value.memories { try memory.validate(for: pair) }
        try CoupleWidgetSnapshot(profiles: value.profiles, startedOn: value.startedOn,
            latestMessage: value.latestMessage, distance: value.location.distance, personalization: value.personalization, latestGesture: value.latestGesture, latestPhoto: value.latestPhoto).validate(for: uid)
        coupleSpace = value
        rememberTheme(value.personalization?.theme ?? .rose)
        // Warm both portraits once; subsequent views and foreground refreshes
        // reuse the same content hash and coalesced request.
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for profile in value.profiles {
                    guard let avatar = profile.avatar else { continue }
                    group.addTask { _ = try? await self.avatar(uid: profile.uid, reference: avatar) }
                }
            }
        }
        spaceError = nil
        await MonthlyReminderService.shared.synchronize(services: self)
    }

    var partnerNickname: String {
        guard let partner = membership?.partner else { return "tu pareja" }
        return personalization.name(for: partner.uid, fallback: partner.displayName)
    }

    // Read the account-scoped appearance synchronously, before the first network refresh.
    // Only the theme is cached here; names and other private content stay out of defaults.
    private var themePreference: CoupleThemePreference? {
        guard let uid = identity?.uid, let url = widgetBaseURL else { return nil }
        return CoupleThemePreference(baseURL: url.absoluteString, uid: uid)
    }
    var savedTheme: CoupleTheme? { themePreference?.load() }
    func rememberTheme(_ theme: CoupleTheme) { themePreference?.save(theme) }
    func forgetTheme() { themePreference?.clear() }
    var personalization: CouplePersonalization {
        coupleSpace?.personalization ?? CouplePersonalization(theme: savedTheme ?? .rose)
    }

    func updatePersonalization(_ value: CouplePersonalization) async throws {
        let uid = try requireUID(), pair = try requirePair()
        try value.validate(memberIDs: pair.memberIDs)
        guard var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw ServiceError.invalidResponse
        }
        payload["coverMemoryId"] = value.coverMemoryId ?? (NSNull() as Any)
        payload.merge(pairPayload(pair)) { _, new in new }
        let response = try await call("updatePersonalization", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        struct Response: Decodable { let personalization: CouplePersonalization }
        let saved: Response = try decodeSpace(response)
        // A failed subsequent refresh must not turn an acknowledged save into a conflict.
        coupleSpace?.personalization = saved.personalization
        rememberTheme(saved.personalization.theme)
        try? await refreshCoupleSpace()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func restoreMemory(_ memory: SharedMemory) async throws {
        let uid = try requireUID(), pair = try requirePair()
        try memory.validate(for: pair)
        var payload = pairPayload(pair); payload["memoryId"] = memory.id
        let response = try await call("restoreMemory", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        struct Response: Decodable { let memory: SharedMemory }
        let value: Response = try decodeSpace(response)
        try value.memory.validate(for: pair)
        coupleSpace?.memories.removeAll { $0.id == memory.id }
        coupleSpace?.memories.append(value.memory)
        try? await refreshCoupleSpace()
    }

    func updateProfile(name: String, photo: Data?, removePhoto: Bool) async throws {
        let uid = try requireUID()
        try await updateDisplayName(name)
        try checkUID(uid)
        if let photo {
            _ = try await requireClient().authenticatedData(path: "profileAvatar", method: "PUT",
                body: photo, headers: ["Content-Type": "image/jpeg"])
        } else if removePhoto { _ = try await call("deleteProfileAvatar") }
        try checkUID(uid)
        try await refreshMembership()
        if membership != nil { try await refreshCoupleSpace() }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func avatar(uid: String, reference: CoupleAvatar) async throws -> Data {
        let ownUID = try requireUID()
        let pair = membership
        guard uid == ownUID || uid == pair?.partner.uid else { throw ServiceError.invalidResponse }
        let client = try requireClient()
        let key = privateImageKey("avatar:\(uid):\(reference.id)")
        let bytes = try await privateImages.data(key: key, expectedSHA256: reference.sha256) {
            try await client.authenticatedData(path: "profileAvatar", query: [
                URLQueryItem(name: "uid", value: uid), URLQueryItem(name: "avatarId", value: reference.id)
            ])
        }
        try checkUID(ownUID)
        if uid != ownUID {
            guard membership?.id == pair?.id, membership?.pairEpoch == pair?.pairEpoch else { throw ServiceError.sessionChanged }
        }
        guard bytes.count <= 5 * 1_024 * 1_024, ContentDigest.sha256(bytes) == reference.sha256 else {
            throw ServiceError.invalidResponse
        }
        return bytes
    }

    func updateStartedOn(_ date: CoupleDate?) async throws {
        let uid = try requireUID(), pair = try requirePair()
        var payload = pairPayload(pair)
        payload["startedOn"] = date?.rawValue ?? (NSNull() as Any)
        payload["timeZone"] = TimeZone.current.identifier
        _ = try await call("updatePairDetails", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        try await refreshCoupleSpace()
        WidgetCenter.shared.reloadAllTimelines()
    }

    @discardableResult
    func sendMessage(id: UUID, text: String) async throws -> CoupleMessage {
        let uid = try requireUID(), pair = try requirePair()
        var payload = pairPayload(pair)
        payload["messageId"] = id.uuidString.lowercased()
        payload["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let response = try await call("sendMessage", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        struct Response: Decodable { let message: CoupleMessage }
        let value: Response = try decodeSpace(response)
        guard value.message.id == id.uuidString.lowercased(), value.message.authorID == uid,
              value.message.recipientID == pair.partner.uid,
              value.message.text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              value.message.sentAt.timeIntervalSince1970.isFinite else { throw ServiceError.invalidResponse }
        // Delivery has already been confirmed. A later refresh failure must not
        // turn the Send button into another publication.
        try? await refreshCoupleSpace()
        return value.message
    }

    func saveMemory(id: String, title: String, date: CoupleDate, body: String, recursYearly: Bool,
                    noteID: String?, photo: Data?, removePhoto: Bool, decoration: MemoryDecoration = MemoryDecoration()) async throws {
        let uid = try requireUID(), pair = try requirePair()
        var payload = pairPayload(pair)
        payload.merge(["memoryId": id, "title": title, "date": date.rawValue, "body": body,
                       "kind": recursYearly ? "date" : "memory", "recursYearly": recursYearly,
                       "noteId": noteID ?? (NSNull() as Any)]) { _, new in new }
        payload["decoration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoration))
        _ = try await call("upsertMemory", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        if let photo {
            _ = try await requireClient().authenticatedData(path: "memoryPhoto", method: "PUT",
                query: memoryQuery(id: id, pair: pair), body: photo, headers: ["Content-Type": "image/jpeg"])
        } else if removePhoto {
            var removal = pairPayload(pair); removal["memoryId"] = id
            _ = try await call("deleteMemoryPhoto", removal)
        }
        try checkSpaceContext(uid: uid, pair: pair)
        try await refreshCoupleSpace()
        if let memory = coupleSpace?.memories.first(where: { $0.id == id && $0.photo != nil }) {
            _ = try? await memoryPhoto(memory)
        }
    }

    func deleteMemory(_ memory: SharedMemory) async throws {
        let uid = try requireUID(), pair = try requirePair()
        try memory.validate(for: pair)
        var payload = pairPayload(pair); payload["memoryId"] = memory.id
        _ = try await call("deleteMemory", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        coupleSpace?.memories.removeAll { $0.id == memory.id }
        try? await refreshCoupleSpace()
    }

    func memoryPhoto(_ memory: SharedMemory) async throws -> Data {
        let uid = try requireUID(), pair = try requirePair()
        try memory.validate(for: pair)
        guard let photo = memory.photo else { throw ServiceError.invalidResponse }
        let client = try requireClient()
        let query = memoryQuery(id: memory.id, pair: pair) + [URLQueryItem(name: "photoId", value: photo.id)]
        let bytes = try await privateImages.data(key: privateImageKey("memory:\(memory.id):\(photo.id)"), expectedSHA256: photo.sha256) {
            try await client.authenticatedData(path: "memoryPhoto", query: query)
        }
        try checkSpaceContext(uid: uid, pair: pair)
        guard bytes.count <= 5 * 1_024 * 1_024, ContentDigest.sha256(bytes) == photo.sha256 else { throw ServiceError.invalidResponse }
        return bytes
    }

    /// The caller keeps the same ID and bytes for retries after an uncertain response.
    @discardableResult
    func sendPhoto(id: UUID, data: Data, caption: String = "") async throws -> CouplePhoto {
        let uid = try requireUID(), pair = try requirePair()
        guard !data.isEmpty, data.count <= 5 * 1_024 * 1_024, caption.utf16.count <= 500 else { throw ServiceError.invalidResponse }
        let bytes = try await requireClient().authenticatedData(path: "couplePhoto", method: "PUT",
            query: photoQuery(id: id.uuidString.lowercased(), pair: pair) + [URLQueryItem(name: "caption", value: caption)],
            body: data, headers: ["Content-Type": "image/jpeg"])
        try checkSpaceContext(uid: uid, pair: pair)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ServiceError.invalidResponse }
        struct Response: Decodable { let photo: CouplePhoto }
        let value: Response = try decodeSpace(object)
        try value.photo.validate(memberIDs: pair.memberIDs)
        guard value.photo.id == id.uuidString.lowercased(), value.photo.authorId == uid else { throw ServiceError.invalidResponse }
        // Publication is confirmed even if a later foreground refresh fails.
        try? await refreshCoupleSpace()
        WidgetCenter.shared.reloadAllTimelines()
        return value.photo
    }

    func photo(id: String) async throws -> CouplePhoto {
        let uid = try requireUID(), pair = try requirePair()
        var payload = pairPayload(pair); payload["photoId"] = id
        let response = try await call("getPhoto", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        struct Response: Decodable { let photo: CouplePhoto }
        let value: Response = try decodeSpace(response)
        try value.photo.validate(memberIDs: pair.memberIDs)
        guard value.photo.id.caseInsensitiveCompare(id) == .orderedSame else { throw ServiceError.invalidResponse }
        return value.photo
    }

    func photoImage(_ photo: CouplePhoto) async throws -> Data {
        let uid = try requireUID(), pair = try requirePair()
        try photo.validate(memberIDs: pair.memberIDs)
        let client = try requireClient()
        let query = photoQuery(id: photo.id, pair: pair) + [URLQueryItem(name: "assetId", value: photo.photo.id)]
        let bytes = try await privateImages.data(key: privateImageKey("photo:\(photo.id):\(photo.photo.id)"), expectedSHA256: photo.photo.sha256) {
            try await client.authenticatedData(path: "couplePhoto", query: query)
        }
        try checkSpaceContext(uid: uid, pair: pair)
        guard bytes.count <= 5 * 1_024 * 1_024, ContentDigest.sha256(bytes) == photo.photo.sha256 else { throw ServiceError.invalidResponse }
        return bytes
    }

    func setLocationConsent(_ enabled: Bool) async throws {
        let uid = try requireUID(), pair = try requirePair()
        var payload = pairPayload(pair); payload["enabled"] = enabled
        if enabled {
            _ = try await call("registerDevice", ["deviceId": deviceID])
            try checkSpaceContext(uid: uid, pair: pair)
            payload["deviceId"] = deviceID
        }
        _ = try await call("setLocationConsent", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        try await refreshCoupleSpace()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func sendLocation(_ sample: LocationSample, for pair: PairMembership, uid: String, consentVersion: UInt64, sequence: Int64) async throws {
        try checkSpaceContext(uid: uid, pair: pair)
        var payload = pairPayload(pair)
        payload.merge(["latitude": sample.latitude, "longitude": sample.longitude,
                       "horizontalAccuracy": sample.accuracy,
                       "deviceId": deviceID, "consentVersion": consentVersion, "sequence": sequence,
                       "capturedAt": try RailwayClient.milliseconds(sample.date)]) { _, new in new }
        _ = try await call("updateLocation", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        try await refreshCoupleSpace()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func privateImageKey(_ resource: String) -> String {
        [widgetBaseURL?.absoluteString ?? "", identity?.uid ?? "", membership?.id ?? "",
         String(membership?.pairEpoch ?? 0), resource].joined(separator: ":")
    }

    func requirePair() throws -> PairMembership {
        guard membershipResolved, let pair = membership else { throw ServiceError.noPair }
        return pair
    }

    func checkSpaceContext(uid: String, pair: PairMembership) throws {
        try checkUID(uid)
        guard membership?.id == pair.id, membership?.pairEpoch == pair.pairEpoch else { throw ServiceError.sessionChanged }
    }

    private func pairPayload(_ pair: PairMembership) -> [String: Any] { ["pairId": pair.id, "pairEpoch": pair.pairEpoch] }
    private func memoryQuery(id: String, pair: PairMembership) -> [URLQueryItem] {
        [URLQueryItem(name: "pairId", value: pair.id), URLQueryItem(name: "pairEpoch", value: String(pair.pairEpoch)),
         URLQueryItem(name: "memoryId", value: id)]
    }
    private func photoQuery(id: String, pair: PairMembership) -> [URLQueryItem] {
        [URLQueryItem(name: "pairId", value: pair.id), URLQueryItem(name: "pairEpoch", value: String(pair.pairEpoch)),
         URLQueryItem(name: "photoId", value: id)]
    }
    func decodeSpace<T: Decodable>(_ object: [String: Any]) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

/// Synchronous first-frame preference; stores no profiles, letters or credentials.
struct CoupleThemePreference {
    let key: String
    let defaults: UserDefaults
    init(baseURL: String, uid: String, defaults: UserDefaults = .standard) {
        key = "couple-theme:" + ContentDigest.sha256(Data((baseURL + ":" + uid).utf8))
        self.defaults = defaults
    }
    func load() -> CoupleTheme? { defaults.string(forKey: key).flatMap(CoupleTheme.init(rawValue:)) }
    func save(_ theme: CoupleTheme) { defaults.set(theme.rawValue, forKey: key) }
    func clear() { defaults.removeObject(forKey: key) }
}
