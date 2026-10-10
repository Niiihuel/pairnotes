import Foundation
import PairNotesCore
import UIKit

extension AppServices {
    /// The server returns the complete bounded list. No private wish data is cached across scopes.
    func wishes() async throws -> [CoupleWish] {
        let uid = try requireUID(), pair = try requirePair()
        let response = try await call("wishes", wishPayload(pair))
        try checkSpaceContext(uid: uid, pair: pair)
        try Task.checkCancellation()
        struct Response: Decodable { let wishes: [CoupleWish]; let limit: Int }
        let value: Response = try decodeSpace(response)
        guard value.limit == 200, value.wishes.count <= value.limit,
              Set(value.wishes.map { $0.id.lowercased() }).count == value.wishes.count else {
            throw ServiceError.invalidResponse
        }
        for wish in value.wishes { try wish.validate(for: pair) }
        return value.wishes
    }

    func wish(id: String) async throws -> CoupleWish {
        let uid = try requireUID(), pair = try requirePair()
        guard UUID(uuidString: id) != nil else { throw ServiceError.invalidResponse }
        var payload = wishPayload(pair); payload["id"] = id.lowercased()
        let response = try await call("getWish", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        try Task.checkCancellation()
        return try decodeWish(response, id: id, pair: pair)
    }

    /// Keep requestID, expectedRevision, and the full payload unchanged while retrying an uncertain response.
    /// A confirmed retry may return a newer version already edited by the other partner.
    @discardableResult
    func saveWish(id: String, title: String, category: CoupleWishCategory, notes: String,
                  priceAmount: String?, currencyCode: String?, fulfilled: Bool,
                  expectedRevision: Int, requestID: UUID,
                  linkURL: String? = nil, targetDate: CoupleDate? = nil, location: String = "",
                  savedAmount: String? = nil, recipient: String = "", occasion: String = "",
                  foodKind: CoupleWishFoodKind? = nil, ingredients: String = "", instructions: String = "") async throws -> CoupleWish {
        let uid = try requireUID(), pair = try requirePair()
        guard (0..<9_007_199_254_740_991).contains(expectedRevision) else { throw ServiceError.invalidResponse }
        if priceAmount != nil && currencyCode == nil { throw CoupleWishPriceError.currencyRequired }
        if priceAmount == nil && currencyCode != nil { throw CoupleWishPriceError.invalidAmount }
        if let currencyCode, !CoupleWishPrice.isCurrencyCode(currencyCode) { throw CoupleWishPriceError.invalidCurrency }
        let cleanLink = linkURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let candidate = CoupleWish(id: id.lowercased(), pairId: pair.id, pairEpoch: pair.pairEpoch,
            authorId: uid, title: title.trimmingCharacters(in: .whitespacesAndNewlines), category: category,
            notes: notes, priceAmount: try priceAmount.map(CoupleWishPrice.canonical), currencyCode: currencyCode,
            fulfilled: fulfilled, createdAt: now, updatedAt: now, revision: expectedRevision + 1,
            linkURL: cleanLink?.isEmpty == true ? nil : cleanLink, targetDate: targetDate, location: location,
            savedAmount: category == .travel ? try savedAmount.map(CoupleWishPrice.canonical) : nil,
            recipient: category == .gifts ? recipient : "", occasion: category == .gifts ? occasion : "",
            foodKind: category == .food ? foodKind : nil,
            ingredients: category == .food && foodKind == .recipe ? ingredients : "",
            instructions: category == .food && foodKind == .recipe ? instructions : "")
        try candidate.validate(for: pair)
        var payload = wishPayload(pair)
        payload.merge([
            "id": candidate.id, "requestId": requestID.uuidString.lowercased(), "expectedRevision": expectedRevision,
            "title": candidate.title, "category": candidate.category.rawValue, "notes": candidate.notes,
            "priceAmount": candidate.priceAmount ?? (NSNull() as Any),
            "currencyCode": candidate.currencyCode ?? (NSNull() as Any), "fulfilled": candidate.fulfilled,
            "linkURL": candidate.linkURL ?? (NSNull() as Any), "targetDate": candidate.targetDate?.rawValue ?? (NSNull() as Any),
            "location": candidate.location, "savedAmount": candidate.savedAmount ?? (NSNull() as Any),
            "recipient": candidate.recipient, "occasion": candidate.occasion,
            "foodKind": candidate.foodKind?.rawValue ?? (NSNull() as Any),
            "ingredients": candidate.ingredients, "instructions": candidate.instructions
        ]) { _, new in new }
        try Task.checkCancellation()
        let response = try await call("saveWish", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        let saved = try decodeWish(response, id: id, pair: pair)
        guard saved.revision > expectedRevision else { throw ServiceError.invalidResponse }
        return saved
    }

    func deleteWish(_ wish: CoupleWish, requestID: UUID) async throws {
        let uid = try requireUID(), pair = try requirePair()
        try wish.validate(for: pair)
        try Task.checkCancellation()
        _ = try await call("deleteWish", wishMutation(wish, pair: pair, requestID: requestID))
        try checkSpaceContext(uid: uid, pair: pair)
    }

    @discardableResult
    func removeWishPhoto(_ wish: CoupleWish, requestID: UUID) async throws -> CoupleWish {
        let uid = try requireUID(), pair = try requirePair()
        try wish.validate(for: pair)
        try Task.checkCancellation()
        let response = try await call("deleteWishPhoto", wishMutation(wish, pair: pair, requestID: requestID))
        try checkSpaceContext(uid: uid, pair: pair)
        let saved = try decodeWish(response, id: wish.id, pair: pair)
        guard saved.revision > wish.revision else { throw ServiceError.invalidResponse }
        return saved
    }

    @discardableResult
    func uploadWishPhoto(_ data: Data, to wish: CoupleWish, requestID: UUID) async throws -> CoupleWish {
        let uid = try requireUID(), pair = try requirePair()
        try wish.validate(for: pair)
        // Reuse the bounded decoder; re-encoding strips EXIF/GPS metadata and fixes orientation.
        let jpeg = try SelectedPhoto.jpeg(data)
        try Task.checkCancellation()
        let response = try await requireClient().authenticatedData(path: "wishPhoto", method: "PUT",
            query: wishQuery(id: wish.id, pair: pair) + [
                URLQueryItem(name: "requestId", value: requestID.uuidString.lowercased()),
                URLQueryItem(name: "expectedRevision", value: String(wish.revision))
            ], body: jpeg, headers: ["Content-Type": "image/jpeg"])
        try checkSpaceContext(uid: uid, pair: pair)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw ServiceError.invalidResponse
        }
        let saved = try decodeWish(object, id: wish.id, pair: pair)
        guard saved.revision > wish.revision else { throw ServiceError.invalidResponse }
        return saved
    }

    func wishPhoto(_ wish: CoupleWish) async throws -> UIImage? {
        let uid = try requireUID(), pair = try requirePair()
        try wish.validate(for: pair)
        guard let photo = wish.photo else { return nil }
        let client = try requireClient()
        let query = wishQuery(id: wish.id, pair: pair) + [URLQueryItem(name: "photoId", value: photo.id)]
        let bytes = try await privateImages.data(key: privateImageKey("wish:\(wish.id):\(photo.id)"), expectedSHA256: photo.sha256) {
            try await client.authenticatedData(path: "wishPhoto", query: query)
        }
        try checkSpaceContext(uid: uid, pair: pair)
        try Task.checkCancellation()
        guard bytes.count <= 5 * 1_024 * 1_024, ContentDigest.sha256(bytes) == photo.sha256,
              let image = UIImage(data: bytes) else { throw ServiceError.invalidResponse }
        return image
    }

    private func decodeWish(_ object: [String: Any], id: String, pair: PairMembership) throws -> CoupleWish {
        struct Response: Decodable { let wish: CoupleWish }
        let value: Response = try decodeSpace(object)
        try value.wish.validate(for: pair)
        guard value.wish.id.lowercased() == id.lowercased() else { throw ServiceError.invalidResponse }
        return value.wish
    }

    private func wishPayload(_ pair: PairMembership) -> [String: Any] {
        ["pairId": pair.id, "pairEpoch": pair.pairEpoch]
    }

    private func wishMutation(_ wish: CoupleWish, pair: PairMembership, requestID: UUID) -> [String: Any] {
        var payload = wishPayload(pair)
        payload["id"] = wish.id.lowercased(); payload["expectedRevision"] = wish.revision
        payload["requestId"] = requestID.uuidString.lowercased()
        return payload
    }

    private func wishQuery(id: String, pair: PairMembership) -> [URLQueryItem] {
        [URLQueryItem(name: "pairId", value: pair.id), URLQueryItem(name: "pairEpoch", value: String(pair.pairEpoch)),
         URLQueryItem(name: "id", value: id.lowercased())]
    }
}
