import ActivityKit
import Foundation

/// Small, serializable state; the image stays in the private App Group instead
/// of exceeding ActivityKit's 4 KB state budget.
struct PairPhotoActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var authorName: String
        var caption: String
        var sentAt: Date
        var reactionKind: String?
        var imageFileName: String
        var expiresAt: Date
        var interactionMessage: String? = nil
    }

    let pairID: String
    let pairEpoch: UInt64
    let viewerID: String
    let photoID: String
    let assetID: String
}
