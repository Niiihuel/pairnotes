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
    let memories: [SharedMemory]
    let location: CoupleLocationState
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
            latestMessage: value.latestMessage, distance: value.location.distance).validate(for: uid)
        coupleSpace = value
        spaceError = nil
        await MonthlyReminderService.shared.synchronize(services: self)
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
        let bytes = try await requireClient().authenticatedData(path: "profileAvatar", query: [
            URLQueryItem(name: "uid", value: uid), URLQueryItem(name: "avatarId", value: reference.id)
        ])
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

    func sendMessage(id: UUID, text: String) async throws {
        let uid = try requireUID(), pair = try requirePair()
        var payload = pairPayload(pair)
        payload["messageId"] = id.uuidString.lowercased()
        payload["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await call("sendMessage", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        // Delivery has already been confirmed. A later refresh failure must not
        // turn the Send button into another publication.
        try? await refreshCoupleSpace()
    }

    func saveMemory(id: String, title: String, date: CoupleDate, body: String, recursYearly: Bool,
                    noteID: String?, photo: Data?, removePhoto: Bool) async throws {
        let uid = try requireUID(), pair = try requirePair()
        var payload = pairPayload(pair)
        payload.merge(["memoryId": id, "title": title, "date": date.rawValue, "body": body,
                       "kind": recursYearly ? "date" : "memory", "recursYearly": recursYearly,
                       "noteId": noteID ?? (NSNull() as Any)]) { _, new in new }
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
    }

    func deleteMemory(_ memory: SharedMemory) async throws {
        let uid = try requireUID(), pair = try requirePair()
        try memory.validate(for: pair)
        var payload = pairPayload(pair); payload["memoryId"] = memory.id
        _ = try await call("deleteMemory", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        try await refreshCoupleSpace()
    }

    func memoryPhoto(_ memory: SharedMemory) async throws -> Data {
        let uid = try requireUID(), pair = try requirePair()
        try memory.validate(for: pair)
        guard let photo = memory.photo else { throw ServiceError.invalidResponse }
        let bytes = try await requireClient().authenticatedData(path: "memoryPhoto",
            query: memoryQuery(id: memory.id, pair: pair) + [URLQueryItem(name: "photoId", value: photo.id)])
        try checkSpaceContext(uid: uid, pair: pair)
        guard bytes.count <= 5 * 1_024 * 1_024, ContentDigest.sha256(bytes) == photo.sha256 else { throw ServiceError.invalidResponse }
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
    func decodeSpace<T: Decodable>(_ object: [String: Any]) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
