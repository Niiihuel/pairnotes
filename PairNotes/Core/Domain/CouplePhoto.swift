import Foundation

public enum PhotoReactionKind: String, Codable, CaseIterable, Sendable {
    case heart, laugh, fire, tear

    public var symbol: String {
        switch self {
        case .heart: return "❤️"
        case .laugh: return "😂"
        case .fire: return "🔥"
        case .tear: return "🥹"
        }
    }

    public var title: String {
        switch self {
        case .heart: return "Me encanta"
        case .laugh: return "Me hace reír"
        case .fire: return "Es increíble"
        case .tear: return "Me emociona"
        }
    }
}

public struct PhotoReaction: Codable, Equatable, Sendable {
    public let authorId: String
    public let photoId: String
    public let kind: PhotoReactionKind
    public let updatedAt: Date

    public init(authorId: String, photoId: String, kind: PhotoReactionKind, updatedAt: Date) {
        self.authorId = authorId; self.photoId = photoId; self.kind = kind; self.updatedAt = updatedAt
    }
}

/// A photo sent directly to the partner; storage keys and source metadata stay private.
public struct CouplePhoto: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let authorId: String
    public let recipientId: String
    public let caption: String
    public let photo: CoupleAvatar
    public let sentAt: Date
    public let reaction: PhotoReaction?

    public init(id: String, authorId: String, recipientId: String, caption: String,
                photo: CoupleAvatar, sentAt: Date, reaction: PhotoReaction? = nil) {
        self.id = id; self.authorId = authorId; self.recipientId = recipientId
        self.caption = caption; self.photo = photo; self.sentAt = sentAt; self.reaction = reaction
    }

    public func validate(memberIDs: [String], at date: Date = Date()) throws {
        guard UUID(uuidString: id) != nil, memberIDs.contains(authorId), memberIDs.contains(recipientId),
              authorId != recipientId, caption.utf16.count <= 500,
              UUID(uuidString: photo.id) != nil, photo.sha256.utf8.count == 64,
              photo.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              sentAt.timeIntervalSince1970.isFinite, sentAt <= date.addingTimeInterval(60) else {
            throw AccountDomainError.invalidPublication
        }
        if let reaction {
            guard reaction.authorId == recipientId, reaction.photoId == id,
                  reaction.updatedAt.timeIntervalSince1970.isFinite,
                  reaction.updatedAt >= sentAt, reaction.updatedAt <= date.addingTimeInterval(60) else {
                throw AccountDomainError.invalidPublication
            }
        }
    }
}
