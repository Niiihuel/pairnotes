import Foundation
import PairNotesCore

struct PhotoHistoryCursor: Codable, Equatable, Sendable {
    let sentAt: Int64
    let photoId: String

    fileprivate var isValid: Bool {
        sentAt > 0 && sentAt <= 9_007_199_254_740_991 && UUID(uuidString: photoId) != nil
    }
}

struct PhotoHistoryPage: Decodable, Equatable, Sendable {
    let photos: [CouplePhoto]
    let nextCursor: PhotoHistoryCursor?
}

extension AppServices {
    /// Both directions, newest first. The cursor matches the backend's stable
    /// descending (sentAt, photoId) order; image bytes remain separately scoped.
    func photos(cursor: PhotoHistoryCursor? = nil, limit: Int = 30) async throws -> PhotoHistoryPage {
        let uid = try requireUID(), pair = try requirePair()
        guard (1...50).contains(limit), cursor?.isValid ?? true else { throw ServiceError.invalidResponse }
        var payload: [String: Any] = ["pairId": pair.id, "pairEpoch": pair.pairEpoch, "limit": limit]
        if let cursor { payload["cursor"] = ["sentAt": cursor.sentAt, "photoId": cursor.photoId] }
        let response = try await call("photos", payload)
        try checkSpaceContext(uid: uid, pair: pair)
        let page: PhotoHistoryPage = try decodeSpace(response)
        guard page.photos.count <= limit, Set(page.photos.map { $0.id.lowercased() }).count == page.photos.count else {
            throw ServiceError.invalidResponse
        }
        var previous = cursor
        for photo in page.photos {
            try photo.validate(memberIDs: pair.memberIDs)
            let current = PhotoHistoryCursor(sentAt: try RailwayClient.milliseconds(photo.sentAt), photoId: photo.id)
            guard current.isValid else { throw ServiceError.invalidResponse }
            if let previous {
                guard current.sentAt < previous.sentAt ||
                      (current.sentAt == previous.sentAt && current.photoId.lowercased() < previous.photoId.lowercased()) else {
                    throw ServiceError.invalidResponse
                }
            }
            previous = current
        }
        if let next = page.nextCursor {
            guard next.isValid, let last = page.photos.last,
                  next.sentAt == (try RailwayClient.milliseconds(last.sentAt)), next.photoId == last.id else {
                throw ServiceError.invalidResponse
            }
        }
        return page
    }
}
