import Foundation
import PairNotesCore

struct ConversationMessageCursor: Codable, Equatable, Sendable {
    let sentAt: Int64
    let messageId: String
}

struct ConversationMessagePage: Decodable, Sendable {
    let messages: [CoupleMessage]
    let nextCursor: ConversationMessageCursor?
}

struct LetterHistoryCursor: Codable, Equatable, Sendable {
    let sentAt: Int64
    let letterId: String
}

struct LetterHistoryPage: Decodable, Sendable {
    let letters: [TimeCapsuleLetter]
    let nextCursor: LetterHistoryCursor?
}

extension AppServices {
    func letterHistory(cursor: LetterHistoryCursor? = nil) async throws -> LetterHistoryPage {
        let uid = try requireUID(), pair = try requirePair()
        var fields: [String: Any] = ["limit": 30]
        if let cursor { fields["cursor"] = ["sentAt": cursor.sentAt, "letterId": cursor.letterId] }
        let response = try await affectionCall("letterHistory", fields)
        let page: LetterHistoryPage = try decodeSpace(response)
        guard page.letters.count <= 30, Set(page.letters.map(\.id)).count == page.letters.count else {
            throw ServiceError.invalidResponse
        }
        var previous = cursor
        for letter in page.letters {
            try letter.validate(uid: uid, memberIDs: pair.memberIDs)
            guard letter.status == "sealed" else { throw ServiceError.invalidResponse }
            let current = LetterHistoryCursor(sentAt: try RailwayClient.milliseconds(letter.sentAt ?? letter.createdAt),
                                              letterId: letter.id)
            if let previous {
                guard current.sentAt < previous.sentAt ||
                      (current.sentAt == previous.sentAt && current.letterId < previous.letterId) else {
                    throw ServiceError.invalidResponse
                }
            }
            previous = current
        }
        if let next = page.nextCursor {
            guard next.sentAt > 0, next == previous else {
                throw ServiceError.invalidResponse
            }
        }
        try checkSpaceContext(uid: uid, pair: pair)
        return page
    }

    func conversationMessages(cursor: ConversationMessageCursor? = nil) async throws -> ConversationMessagePage {
        let uid = try requireUID(), pair = try requirePair()
        var fields: [String: Any] = ["limit": 30]
        if let cursor {
            fields["cursor"] = ["sentAt": cursor.sentAt, "messageId": cursor.messageId]
        }
        let response = try await affectionCall("messages", fields)
        let page: ConversationMessagePage = try decodeSpace(response)
        guard page.messages.count <= 30, Set(page.messages.map(\.id)).count == page.messages.count,
              page.messages.allSatisfy({
            UUID(uuidString: $0.id) != nil && pair.memberIDs.contains($0.authorID) &&
            pair.memberIDs.contains($0.recipientID) && $0.authorID != $0.recipientID &&
            !$0.text.isEmpty && $0.text.utf16.count <= 500 && $0.sentAt.timeIntervalSince1970.isFinite
        }), page.nextCursor.map({ $0.sentAt > 0 && UUID(uuidString: $0.messageId) != nil }) ?? true else {
            throw ServiceError.invalidResponse
        }
        var previous = cursor
        for message in page.messages {
            let current = ConversationMessageCursor(sentAt: try RailwayClient.milliseconds(message.sentAt), messageId: message.id)
            if let previous {
                guard current.sentAt < previous.sentAt ||
                      (current.sentAt == previous.sentAt && current.messageId < previous.messageId) else {
                    throw ServiceError.invalidResponse
                }
            }
            previous = current
        }
        if let next = page.nextCursor {
            guard let last = page.messages.last, next.messageId == last.id,
                  next.sentAt == (try RailwayClient.milliseconds(last.sentAt)) else { throw ServiceError.invalidResponse }
        }
        try checkSpaceContext(uid: uid, pair: pair)
        return page
    }
}
