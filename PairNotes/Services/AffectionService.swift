import Foundation
import PairNotesCore
import WidgetKit

extension AppServices {
    func affectionCall(_ name: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
        let uid = try requireUID(), pair = try requirePair()
        var payload = fields
        payload["pairId"] = pair.id; payload["pairEpoch"] = pair.pairEpoch
        let response = try await call(name, payload)
        try checkSpaceContext(uid: uid, pair: pair)
        return response
    }
    func sendGesture(id: UUID, kind: AffectionKind, replyTo: String?) async throws {
        struct Response: Decodable { let gesture: CoupleGesture }
        let response = try await affectionCall("sendGesture", ["gestureId": id.uuidString.lowercased(), "kind": kind.rawValue,
            "replyTo": replyTo ?? (NSNull() as Any)])
        let value: Response = try decodeSpace(response)
        try value.gesture.validate(memberIDs: try requirePair().memberIDs)
        coupleSpace?.latestGesture = value.gesture
        WidgetCenter.shared.reloadAllTimelines()
    }
    func reactions(noteID: String) async throws -> [DrawingReaction] {
        let response = try await affectionCall("reactions", ["noteId": noteID])
        return try decodeReactions(response, noteID: noteID)
    }
    func setReaction(noteID: String, kind: String, reply: String) async throws -> [DrawingReaction] {
        let response = try await affectionCall("setReaction", ["noteId": noteID, "kind": kind, "reply": reply])
        return try decodeReactions(response, noteID: noteID)
    }
    private func decodeReactions(_ response: [String: Any], noteID: String) throws -> [DrawingReaction] {
        struct Response: Decodable { let reactions: [DrawingReaction] }
        let value: Response = try decodeSpace(response), pair = try requirePair()
        guard value.reactions.count <= 2, value.reactions.allSatisfy({ pair.memberIDs.contains($0.authorId) && $0.noteId == noteID &&
            ["", "heart", "hug", "sparkles"].contains($0.kind) && $0.reply.utf16.count <= 280 }) else { throw ServiceError.invalidResponse }
        return value.reactions
    }

    func setPhotoReaction(photoID: String, assetID: String, kind: PhotoReactionKind) async throws -> CouplePhoto {
        let uid = try requireUID(), pair = try requirePair()
        let response = try await affectionCall("setPhotoReaction", ["photoId": photoID, "assetId": assetID, "kind": kind.rawValue])
        struct Response: Decodable { let reaction: PhotoReaction; let photo: CouplePhoto }
        let value: Response = try decodeSpace(response)
        try value.photo.validate(memberIDs: pair.memberIDs)
        guard value.reaction.authorId == uid, value.reaction.photoId == photoID, value.reaction.kind == kind,
              value.photo.id == photoID, value.photo.photo.id == assetID, value.photo.reaction == value.reaction,
              value.reaction.updatedAt.timeIntervalSince1970.isFinite else { throw ServiceError.invalidResponse }
        if let current = coupleSpace?.latestPhoto, current.id == photoID {
            coupleSpace?.latestPhoto = value.photo
        }
        try checkSpaceContext(uid: uid, pair: pair)
        WidgetCenter.shared.reloadAllTimelines()
        return value.photo
    }
    func letters() async throws -> [TimeCapsuleLetter] {
        struct Response: Decodable { let letters: [TimeCapsuleLetter] }
        let response = try await affectionCall("letters")
        let value: Response = try decodeSpace(response), uid = try requireUID(), pair = try requirePair()
        for letter in value.letters { try letter.validate(uid: uid, memberIDs: pair.memberIDs) }
        return value.letters
    }
    func letterResponse(_ response: [String: Any]) throws -> TimeCapsuleLetter {
        struct Response: Decodable { let letter: TimeCapsuleLetter }
        let value: Response = try decodeSpace(response)
        try value.letter.validate(uid: try requireUID(), memberIDs: try requirePair().memberIDs)
        return value.letter
    }
    func openLetter(id: String) async throws -> TimeCapsuleLetter {
        try letterResponse(await affectionCall("openLetter", ["letterId": id]))
    }
    func saveLetterDraft(id: String, title: String, body: String, opensAt: Date, noteID: String?) async throws -> TimeCapsuleLetter {
        try letterResponse(await affectionCall("saveLetterDraft", ["letterId": id, "title": title, "body": body,
            "opensAt": try RailwayClient.milliseconds(opensAt), "noteId": noteID ?? (NSNull() as Any)]))
    }
    func sealLetter(id: String, immediate: Bool = false) async throws -> TimeCapsuleLetter {
        try letterResponse(await affectionCall("sealLetter", ["letterId": id, "immediate": immediate]))
    }
    func deleteLetterDraft(id: String) async throws { _ = try await affectionCall("deleteLetterDraft", ["letterId": id]) }
    func removeLetterAsset(id: String, role: String) async throws {
        _ = try await affectionCall("removeLetterAsset", ["letterId": id, "role": role])
    }
    func uploadLetterAsset(id: String, role: String, data: Data) async throws {
        let uid = try requireUID(), pair = try requirePair()
        guard ["photo", "drawing", "audio"].contains(role) else { throw ServiceError.invalidResponse }
        _ = try await requireClient().authenticatedData(path: role == "photo" ? "letterPhoto" : (role == "drawing" ? "letterDrawing" : "letterAudio"), method: "PUT",
            query: letterQuery(id: id, pair: pair), body: data, headers: ["Content-Type": role == "photo" ? "image/jpeg" : (role == "drawing" ? "image/png" : "audio/wav")])
        try checkSpaceContext(uid: uid, pair: pair)
    }
    func letterAsset(_ letter: TimeCapsuleLetter, role: String) async throws -> Data {
        let uid = try requireUID(), pair = try requirePair()
        try letter.validate(uid: uid, memberIDs: pair.memberIDs)
        guard letter.authorId == uid || letter.canOpen, ["photo", "drawing", "audio"].contains(role),
              let asset = role == "photo" ? letter.photo : (role == "drawing" ? letter.drawing : letter.audio) else { throw ServiceError.invalidResponse }
        let query = letterQuery(id: letter.id, pair: pair) + [URLQueryItem(name: "assetId", value: asset.id)]
        let client = try requireClient()
        let bytes = try await privateImages.data(key: privateImageKey("letter:\(letter.id):\(role):\(asset.id)"), expectedSHA256: asset.sha256) {
            try await client.authenticatedData(path: role == "photo" ? "letterPhoto" : (role == "drawing" ? "letterDrawing" : "letterAudio"), query: query)
        }
        try checkSpaceContext(uid: uid, pair: pair)
        return bytes
    }
    private func letterQuery(id: String, pair: PairMembership) -> [URLQueryItem] {
        [URLQueryItem(name: "pairId", value: pair.id), URLQueryItem(name: "pairEpoch", value: String(pair.pairEpoch)), URLQueryItem(name: "letterId", value: id)]
    }
}
