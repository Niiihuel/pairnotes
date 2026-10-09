import Foundation

public enum CoupleConversationItem: Equatable, Identifiable, Sendable {
    case message(CoupleMessage)
    case photo(CouplePhoto)
    case drawing(RemoteNote)
    case letter(TimeCapsuleLetter)

    public var id: String {
        switch self {
        case .message(let value): return "message:" + value.id
        case .photo(let value): return "photo:" + value.id
        case .drawing(let value): return "drawing:" + value.id
        case .letter(let value): return "letter:" + value.id
        }
    }

    public var authorID: String {
        switch self {
        case .message(let value): return value.authorID
        case .photo(let value): return value.authorId
        case .drawing(let value): return value.authorID
        case .letter(let value): return value.authorId
        }
    }

    public var date: Date {
        switch self {
        case .message(let value): return value.sentAt
        case .photo(let value): return value.sentAt
        case .drawing(let value): return value.serverPublishedAt
        case .letter(let value): return value.sentAt ?? value.createdAt
        }
    }
}

public enum CoupleConversation {
    /// Each source keeps its own cursor. Reactions/opened letters can replace
    /// an earlier value without duplicating a message in the conversation.
    public static func items(messages: [CoupleMessage], photos: [CouplePhoto],
                             drawings: [RemoteNote], letters: [TimeCapsuleLetter]) -> [CoupleConversationItem] {
        let values = messages.map(CoupleConversationItem.message) + photos.map(CoupleConversationItem.photo) +
            drawings.map(CoupleConversationItem.drawing) +
            letters.filter { $0.status == "sealed" }.map(CoupleConversationItem.letter)
        var unique: [String: CoupleConversationItem] = [:]
        for value in values { unique[value.id] = value }
        return unique.values.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }
}
