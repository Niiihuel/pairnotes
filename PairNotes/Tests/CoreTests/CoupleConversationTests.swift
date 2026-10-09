import Foundation
import XCTest
@testable import PairNotesCore

final class CoupleConversationTests: XCTestCase {
    func testLetterCreatedAsAnOldDraftAppearsAtItsServerSealingTime() throws {
        let envelope = try letter(id: id(4), createdAt: 1_000, sentAt: 5_000)
        let values = CoupleConversation.items(messages: [message(id: id(1), at: 2_000)],
            photos: [photo(id: id(2), at: 3_000)], drawings: [drawing(id: id(3), at: 4_000)], letters: [envelope])
        XCTAssertEqual(values.map(\.id), ["message:" + id(1), "photo:" + id(2), "drawing:" + id(3), "letter:" + id(4)])
        XCTAssertEqual(values.last?.date, date(5_000))
        XCTAssertNotEqual(values.last?.date, envelope.createdAt)
        XCTAssertNotEqual(values.last?.date, envelope.opensAt, "A scheduled opening is not a publication timestamp")
    }

    func testLegacyLettersWithoutSealingTimeKeepTheirCreationTime() throws {
        let legacy = try letter(id: id(2), createdAt: 2_000)
        XCTAssertNil(legacy.sentAt, "The fixture must exercise a legacy payload with no sentAt field")
        let values = CoupleConversation.items(messages: [message(id: id(1), at: 1_000)], photos: [],
            drawings: [drawing(id: id(3), at: 3_000)], letters: [legacy])
        XCTAssertEqual(values.map(\.id), ["message:" + id(1), "letter:" + id(2), "drawing:" + id(3)])
        XCTAssertEqual(values[1].date, legacy.createdAt)
    }

    func testAnIdenticalUUIDInDifferentSourcesDoesNotHideAnyEvent() throws {
        let sharedID = id(1)
        let values = CoupleConversation.items(messages: [message(id: sharedID, at: 1_000)],
            photos: [photo(id: sharedID, at: 1_000)], drawings: [drawing(id: sharedID, at: 1_000)],
            letters: [try letter(id: sharedID, createdAt: 1_000)])
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(Set(values.map(\.id)), Set(["message:", "photo:", "drawing:", "letter:"].map { $0 + sharedID }))
        XCTAssertEqual(values.first(where: { $0.id == "message:" + sharedID })?.authorID, "a")
        XCTAssertEqual(values.first(where: { $0.id == "photo:" + sharedID })?.authorID, "b")
        XCTAssertEqual(values.first(where: { $0.id == "drawing:" + sharedID })?.authorID, "a")
        XCTAssertEqual(values.first(where: { $0.id == "letter:" + sharedID })?.authorID, "b")
    }

    func testUnsentLetterDraftsNeverBecomeChatEvents() throws {
        let draft = try letter(id: id(1), createdAt: 1_000, status: "draft")
        let sent = try letter(id: id(2), createdAt: 2_000, sentAt: 3_000)
        let values = CoupleConversation.items(messages: [], photos: [], drawings: [], letters: [draft, sent])
        XCTAssertEqual(values, [.letter(sent)])
        XCTAssertTrue(CoupleConversation.items(messages: [], photos: [], drawings: [], letters: [draft]).isEmpty)
    }

    func testConfirmedReactionAndOpenedLetterReplaceEarlierVersionsWithoutDuplicates() throws {
        let originalPhoto = photo(id: id(1), at: 1_000,
            reaction: PhotoReaction(authorId: "a", photoId: id(1), kind: .heart, updatedAt: date(2_000)))
        let updatedPhoto = photo(id: id(1), at: 1_000,
            reaction: PhotoReaction(authorId: "a", photoId: id(1), kind: .tear, updatedAt: date(3_000)))
        let closed = try letter(id: id(2), createdAt: 500, sentAt: 1_500)
        let opened = try letter(id: id(2), createdAt: 500, sentAt: 1_500,
            canOpen: true, openedAt: 10_000, title: "Ya podés leerme")
        let values = CoupleConversation.items(messages: [], photos: [originalPhoto, updatedPhoto], drawings: [], letters: [closed, opened])
        XCTAssertEqual(values, [.photo(updatedPhoto), .letter(opened)])
        XCTAssertEqual(values.map(\.date), [date(1_000), date(1_500)],
            "A later reaction or opening updates the card without moving its publication in the chat")
    }

    func testEqualTimestampsHaveStableOrderingAcrossSourcesAndInputOrders() throws {
        let messages = [message(id: id(2), at: 1_000), message(id: id(1), at: 1_000)]
        let photos = [photo(id: id(2), at: 1_000), photo(id: id(1), at: 1_000)]
        let drawings = [drawing(id: id(2), at: 1_000), drawing(id: id(1), at: 1_000)]
        let letters = [try letter(id: id(2), createdAt: 1_000), try letter(id: id(1), createdAt: 1_000)]
        let expected = ["drawing:" + id(1), "drawing:" + id(2), "letter:" + id(1), "letter:" + id(2),
                        "message:" + id(1), "message:" + id(2), "photo:" + id(1), "photo:" + id(2)]
        let first = CoupleConversation.items(messages: messages, photos: photos, drawings: drawings, letters: letters)
        let reversed = CoupleConversation.items(messages: messages.reversed(), photos: photos.reversed(),
            drawings: drawings.reversed(), letters: letters.reversed())
        XCTAssertEqual(first.map(\.id), expected)
        XCTAssertEqual(reversed, first)
    }

    private func id(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", number) }
    private func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1_000) }
    private func message(id: String, at milliseconds: Double) -> CoupleMessage {
        CoupleMessage(id: id, authorID: "a", recipientID: "b", text: "Mensaje de prueba", sentAt: date(milliseconds))
    }
    private func photo(id: String, at milliseconds: Double, reaction: PhotoReaction? = nil) -> CouplePhoto {
        CouplePhoto(id: id, authorId: "b", recipientId: "a", caption: "Foto de prueba",
            photo: CoupleAvatar(id: self.id(100), sha256: String(repeating: "a", count: 64)),
            sentAt: date(milliseconds), reaction: reaction)
    }
    private func drawing(id: String, at milliseconds: Double) -> RemoteNote {
        let prefix = "pairs/pair-test/1/\(id)/"
        return RemoteNote(id: id, pairID: "pair-test", pairEpoch: 1, authorID: "a", recipientID: "b", revision: 1,
            revisionHash: String(repeating: "a", count: 64), serverPublishedAt: date(milliseconds),
            assets: NoteAssetPaths(source: prefix + "source", final: prefix + "final", widget: prefix + "widget", thumbnail: prefix + "thumbnail"))
    }
    private func letter(id: String, createdAt: Double, sentAt: Double? = nil, status: String = "sealed",
                        canOpen: Bool = false, openedAt: Double? = nil, title: String? = nil) throws -> TimeCapsuleLetter {
        var value: [String: Any] = ["id": id, "authorId": "b", "recipientId": "a", "status": status,
            "opensAt": 9_000, "createdAt": createdAt, "canOpen": canOpen]
        if let sentAt { value["sentAt"] = sentAt }
        if let openedAt { value["openedAt"] = openedAt }
        if let title { value["title"] = title }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TimeCapsuleLetter.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
