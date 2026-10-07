import Foundation
import XCTest
@testable import PairNotesCore

final class CouplePhotoTests: XCTestCase {
    private let author = "fictional-author"
    private let recipient = "fictional-recipient"
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func photo(recipient: String = "fictional-recipient", reactionAuthor: String? = nil,
                       reactionPhoto: String? = nil, reactionTime: Date? = nil) -> CouplePhoto {
        let id = "3e109269-279f-4c6f-9c3d-87019f4be0b5"
        return CouplePhoto(id: id, authorId: author, recipientId: recipient, caption: "Un momento para vos",
            photo: CoupleAvatar(id: "fc5e3e02-e6d6-4b7b-8a6f-66a811fd7740", sha256: String(repeating: "a", count: 64)),
            sentAt: now, reaction: reactionAuthor.map {
                PhotoReaction(authorId: $0, photoId: reactionPhoto ?? id, kind: .heart, updatedAt: reactionTime ?? now)
            })
    }

    func testPhotoAndReactionValidateOnlyTheCurrentMembersAndRecipient() throws {
        XCTAssertNoThrow(try photo().validate(memberIDs: [author, recipient], at: now))
        XCTAssertNoThrow(try photo(reactionAuthor: recipient).validate(memberIDs: [author, recipient], at: now))
        XCTAssertThrowsError(try photo(recipient: "outsider").validate(memberIDs: [author, recipient], at: now))
        XCTAssertThrowsError(try photo(reactionAuthor: author).validate(memberIDs: [author, recipient], at: now))
        XCTAssertThrowsError(try photo(reactionAuthor: recipient, reactionPhoto: UUID().uuidString).validate(memberIDs: [author, recipient], at: now))
        XCTAssertThrowsError(try photo(reactionAuthor: recipient, reactionTime: now.addingTimeInterval(-1)).validate(memberIDs: [author, recipient], at: now))
        XCTAssertThrowsError(try photo(reactionAuthor: recipient, reactionTime: now.addingTimeInterval(61)).validate(memberIDs: [author, recipient], at: now))
    }

    func testWidgetNeverAcceptsASentPhotoAsLatestReceived() throws {
        let snapshot = CoupleWidgetSnapshot(profiles: [CoupleProfile(uid: author, displayName: "Alex"),
            CoupleProfile(uid: recipient, displayName: "Sam")], startedOn: nil, latestMessage: nil,
            distance: CoupleDistance(status: .disabled), latestPhoto: photo())
        XCTAssertNoThrow(try snapshot.validate(for: recipient, at: now))
        XCTAssertThrowsError(try snapshot.validate(for: author, at: now))
    }

    func testExistingSnapshotsDecodeWithoutPhotoAndNewPhotosRoundTrip() throws {
        let decoder = JSONDecoder()
        let oldJSON = Data("""
        {"profiles":[{"uid":"fictional-author","displayName":"Alex"},{"uid":"fictional-recipient","displayName":"Sam"}],"distance":{"status":"disabled"}}
        """.utf8)
        let old = try decoder.decode(CoupleWidgetSnapshot.self, from: oldJSON)
        XCTAssertNil(old.latestPhoto)
        let expected = photo(reactionAuthor: recipient)
        XCTAssertEqual(try decoder.decode(CouplePhoto.self, from: JSONEncoder().encode(expected)), expected)
        XCTAssertEqual(PhotoReactionKind.allCases.map(\.symbol), ["❤️", "😂", "🔥", "🥹"])
    }
}
