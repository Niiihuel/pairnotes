import Foundation
import XCTest
@testable import PairNotesCore

final class ChatReactionTests: XCTestCase {
    private let target = ChatReactionTarget(type: .message, id: "00000000-0000-4000-8000-000000000001")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSixKindsAndTargetWireKeysRoundTripWithoutChangingLegacyPhotoKinds() throws {
        XCTAssertEqual(ChatReactionKind.allCases.count, 6)
        XCTAssertEqual(PhotoReactionKind.allCases.count, 4)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for kind in ChatReactionKind.allCases {
            XCTAssertEqual(try decoder.decode(ChatReactionKind.self, from: encoder.encode(kind)), kind)
            XCTAssertFalse(kind.symbol.isEmpty)
            XCTAssertFalse(kind.accessibilityLabel.isEmpty)
        }
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(target)) as? [String: String])
        XCTAssertEqual(fields, ["targetType": "message", "targetId": target.id])
        XCTAssertThrowsError(try decoder.decode(ChatReactionKind.self, from: Data("\"unknown\"".utf8)))
        let uppercase = ChatReactionTarget(type: .photo, id: "A0000000-0000-4000-8000-000000000001")
        XCTAssertEqual(try decoder.decode(ChatReactionTarget.self, from: encoder.encode(uppercase)), uppercase)
        XCTAssertEqual(uppercase.id.first, "a")
    }

    func testServerMillisecondsDecodeAndBothActorsRemainDistinctForEveryTargetType() throws {
        let payload: [String: Any] = ["targetType": "message", "targetId": target.id,
            "authorId": "alice", "kind": "thumbsUp", "updatedAt": 1_800_000_000_000 as Int64]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(ChatReaction.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(value.authorID, "alice")
        XCTAssertEqual(value.updatedAt, now)
        let targets = Set(ChatReactionTargetType.allCases.map { ChatReactionTarget(type: $0, id: target.id) })
        XCTAssertEqual(targets.count, 4)
        let reactions = targets.flatMap { target in
            [reaction(target, author: "alice"), reaction(target, author: "bob")]
        }
        try ChatReaction.validate(reactions, targets: targets, memberIDs: ["alice", "bob"], at: now)
        XCTAssertEqual(Set(reactions.map(\.id)).count, 8)
    }

    func testResponseRejectsOutsidersUnrequestedTargetsDuplicatesAndInvalidDates() throws {
        let allowed: Set<ChatReactionTarget> = [target]
        let good = reaction(target, author: "alice")
        for invalid in [reaction(target, author: "outsider"),
                        reaction(ChatReactionTarget(type: .photo, id: target.id), author: "alice"),
                        reaction(target, author: "alice", date: .distantFuture),
                        reaction(target, author: "alice", date: Date(timeIntervalSince1970: .nan)),
                        reaction(target, author: "alice", date: Date(timeIntervalSince1970: 0))] {
            XCTAssertThrowsError(try ChatReaction.validate([invalid], targets: allowed,
                                                           memberIDs: ["alice", "bob"], at: now))
        }
        XCTAssertThrowsError(try ChatReaction.validate([good, good], targets: allowed,
                                                       memberIDs: ["alice", "bob"], at: now))
        XCTAssertThrowsError(try ChatReaction.validate([], targets: [ChatReactionTarget(type: .drawing, id: "bad")],
                                                       memberIDs: ["alice", "bob"], at: now))
        try ChatReaction.validate([], targets: allowed, memberIDs: ["alice", "bob"], at: now)
    }

    func testMessageTargetUsesPublicationIDAndCannotCollideWithAnotherContentType() {
        let message = CoupleMessage(id: target.id, authorID: "alice", recipientID: "bob", text: "Hola", sentAt: now)
        XCTAssertEqual(CoupleConversationItem.message(message).reactionTarget, target)
        XCTAssertNotEqual(target, ChatReactionTarget(type: .letter, id: target.id))
    }

    private func reaction(_ target: ChatReactionTarget, author: String, date: Date? = nil) -> ChatReaction {
        ChatReaction(targetType: target.type, targetID: target.id, authorID: author,
                     kind: .heart, updatedAt: date ?? now)
    }
}
