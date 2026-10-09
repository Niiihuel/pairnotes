import Foundation

public enum ChatReactionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case heart, laugh, fire, tear, thumbsUp, surprised

    public var symbol: String {
        switch self {
        case .heart: return "❤️"
        case .laugh: return "😂"
        case .fire: return "🔥"
        case .tear: return "🥹"
        case .thumbsUp: return "👍"
        case .surprised: return "😮"
        }
    }

    public var title: String {
        switch self {
        case .heart: return "Me encanta"
        case .laugh: return "Me hace reír"
        case .fire: return "Es increíble"
        case .tear: return "Me emociona"
        case .thumbsUp: return "Me gusta"
        case .surprised: return "Me sorprende"
        }
    }

    public var accessibilityLabel: String { title }
}

public enum ChatReactionTargetType: String, Codable, CaseIterable, Hashable, Sendable {
    case message, photo, drawing, letter
}

public struct ChatReactionTarget: Codable, Hashable, Sendable {
    public let type: ChatReactionTargetType
    public let id: String
    public var key: String { type.rawValue + ":" + id }

    public init(type: ChatReactionTargetType, id: String) {
        self.type = type; self.id = id.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case type = "targetType", id = "targetId"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try values.decode(ChatReactionTargetType.self, forKey: .type),
                  id: try values.decode(String.self, forKey: .id))
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil else { throw AccountDomainError.invalidPublication }
    }
}

public struct ChatReaction: Codable, Equatable, Identifiable, Sendable {
    public let targetType: ChatReactionTargetType
    public let targetID: String
    public let authorID: String
    public let kind: ChatReactionKind
    public let updatedAt: Date
    public var target: ChatReactionTarget { ChatReactionTarget(type: targetType, id: targetID) }
    public var id: String { target.key + ":" + authorID }

    public init(targetType: ChatReactionTargetType, targetID: String, authorID: String,
                kind: ChatReactionKind, updatedAt: Date) {
        self.targetType = targetType; self.targetID = targetID.lowercased()
        self.authorID = authorID; self.kind = kind; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case targetType, targetID = "targetId", authorID = "authorId", kind, updatedAt
    }

    public static func validate(_ values: [ChatReaction], targets: Set<ChatReactionTarget>,
                                memberIDs: [String], at now: Date = Date()) throws {
        guard memberIDs.count == 2, Set(memberIDs).count == 2,
              values.count <= targets.count * 2 else { throw AccountDomainError.invalidPublication }
        for target in targets { try target.validate() }
        var seen: Set<String> = []
        for value in values {
            guard targets.contains(value.target), memberIDs.contains(value.authorID),
                  value.updatedAt.timeIntervalSince1970.isFinite,
                  value.updatedAt.timeIntervalSince1970 > 0,
                  value.updatedAt <= now.addingTimeInterval(60), seen.insert(value.id).inserted else {
                throw AccountDomainError.invalidPublication
            }
        }
    }
}

extension CoupleConversationItem {
    public var reactionTarget: ChatReactionTarget {
        switch self {
        case .message(let value): return ChatReactionTarget(type: .message, id: value.id)
        case .photo(let value): return ChatReactionTarget(type: .photo, id: value.id)
        case .drawing(let value): return ChatReactionTarget(type: .drawing, id: value.id)
        case .letter(let value): return ChatReactionTarget(type: .letter, id: value.id)
        }
    }
}
