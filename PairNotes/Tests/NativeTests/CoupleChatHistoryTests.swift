import Combine
import Foundation
import PairNotesCore
import XCTest
@testable import PairNotes

final class CoupleChatHistoryTests: XCTestCase {
    @MainActor
    func testOldRequestCannotRepopulateHistoryAfterScopeReset() async throws {
        let history = CoupleChatHistory()
        var scope = "old-pair"
        let gate = ChatHistoryGate<ConversationMessagePage>("Old request started")
        let empty = ConversationMessagePage(messages: [], nextCursor: nil)
        let old = source(scope: { scope }, messages: { _ in await gate.value() })
        let request = Task { await history.refresh(source: old) }
        defer { gate.resolve(empty); request.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        history.reset(); scope = "new-pair"
        let fresh = message(2, at: 2)
        await history.refresh(source: source(scope: { scope }, messages: { _ in
            ConversationMessagePage(messages: [fresh], nextCursor: nil)
        }))
        gate.resolve(ConversationMessagePage(messages: [message(1, at: 1)], nextCursor: nil))
        await request.value
        XCTAssertEqual(history.loadedScope, "new-pair")
        XCTAssertEqual(history.messages, [fresh])
        XCTAssertFalse(history.loading)
    }

    @MainActor
    func testIndependentCursorsSurviveFirstPageRefreshWithoutLosingOlderItems() async throws {
        let history = CoupleChatHistory()
        let m1 = ConversationMessageCursor(sentAt: 300, messageId: id(1))
        let m2 = ConversationMessageCursor(sentAt: 100, messageId: id(2))
        let p1 = PhotoHistoryCursor(sentAt: 400, photoId: id(3))
        let p2 = PhotoHistoryCursor(sentAt: 200, photoId: id(4))
        let l1 = LetterHistoryCursor(sentAt: 500, letterId: id(5))
        let l2 = LetterHistoryCursor(sentAt: 250, letterId: id(6))
        let originalMessage = message(1, at: 300), olderMessage = message(2, at: 100), newest = message(7, at: 600)
        let originalPhoto = photo(3, at: 400), olderPhoto = photo(4, at: 200)
        let originalLetter = try letter(5, at: 500), olderLetter = try letter(6, at: 250)
        var refreshed = false
        var messageRequests: [ConversationMessageCursor?] = []
        var photoRequests: [PhotoHistoryCursor?] = []
        var letterRequests: [LetterHistoryCursor?] = []
        let source = ChatHistorySource(currentScope: { "pair" }, isAuthorized: { true }, messages: { cursor in
            messageRequests.append(cursor)
            if cursor == m1 { return ConversationMessagePage(messages: [olderMessage], nextCursor: m2) }
            if cursor == m2 { return ConversationMessagePage(messages: [], nextCursor: nil) }
            return ConversationMessagePage(messages: refreshed ? [newest, originalMessage] : [originalMessage], nextCursor: m1)
        }, photos: { cursor in
            photoRequests.append(cursor)
            if cursor == p1 { return PhotoHistoryPage(photos: [olderPhoto], nextCursor: p2) }
            if cursor == p2 { return PhotoHistoryPage(photos: [], nextCursor: nil) }
            return PhotoHistoryPage(photos: [originalPhoto], nextCursor: p1)
        }, letters: { cursor in
            letterRequests.append(cursor)
            if cursor == l1 { return LetterHistoryPage(letters: [olderLetter], nextCursor: l2) }
            if cursor == l2 { return LetterHistoryPage(letters: [], nextCursor: nil) }
            return LetterHistoryPage(letters: [originalLetter], nextCursor: l1)
        })
        await history.refresh(source: source)
        await history.refresh(source: source, older: true)
        refreshed = true
        await history.refresh(source: source)
        XCTAssertEqual(Set(history.messages.map(\.id)), Set([originalMessage.id, olderMessage.id, newest.id]))
        XCTAssertEqual(Set(history.photos.map(\.id)), Set([originalPhoto.id, olderPhoto.id]))
        XCTAssertEqual(Set(history.letters.map(\.id)), Set([originalLetter.id, olderLetter.id]))
        await history.refresh(source: source, older: true)
        XCTAssertEqual(messageRequests, [nil, m1, nil, m2])
        XCTAssertEqual(photoRequests, [nil, p1, nil, p2])
        XCTAssertEqual(letterRequests, [nil, l1, nil, l2])
        XCTAssertFalse(history.hasOlderMessages || history.hasOlderPhotos || history.hasOlderLetters)
    }

    @MainActor
    func testConfirmedSendSurvivesAnOlderFlightAndQueuesOneFreshFetch() async throws {
        let history = CoupleChatHistory()
        let first = ChatHistoryGate<ConversationMessagePage>("Pre-send fetch started")
        let second = ChatHistoryGate<ConversationMessagePage>("Queued fetch started")
        let old = message(1, at: 1), confirmed = message(2, at: 2)
        let empty = ConversationMessagePage(messages: [], nextCursor: nil)
        var calls = 0
        let source = source(scope: { "pair" }, messages: { _ in
            calls += 1
            if calls == 1 { return await first.value() }
            if calls == 2 { return await second.value() }
            XCTFail("A pending refresh must coalesce into exactly one follow-up")
            return empty
        })
        let request = Task { await history.refresh(source: source) }
        defer { first.resolve(empty); second.resolve(empty); request.cancel() }
        await fulfillment(of: [first.started], timeout: 2)
        history.accept(.message(confirmed), scope: "pair")
        await history.refresh(source: source)
        await history.refresh(source: source)
        first.resolve(ConversationMessagePage(messages: [old], nextCursor: nil))
        await request.value
        await fulfillment(of: [second.started], timeout: 2)
        XCTAssertEqual(Set(history.messages.map(\.id)), Set([old.id, confirmed.id]))
        let finished = expectation(description: "Queued fetch applied")
        let observation = history.$loading.sink { if !$0 { finished.fulfill() } }
        defer { observation.cancel() }
        second.resolve(ConversationMessagePage(messages: [confirmed, old], nextCursor: nil))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(history.messages, [old, confirmed])
        XCTAssertEqual(history.loadedScope, "pair")
    }

    @MainActor
    private func source(scope: @escaping () -> String,
                        messages: @escaping @MainActor (ConversationMessageCursor?) async throws -> ConversationMessagePage) -> ChatHistorySource {
        ChatHistorySource(currentScope: scope, isAuthorized: { true }, messages: messages,
            photos: { _ in PhotoHistoryPage(photos: [], nextCursor: nil) },
            letters: { _ in LetterHistoryPage(letters: [], nextCursor: nil) })
    }
    private func id(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", number) }
    private func message(_ number: Int, at seconds: Double) -> CoupleMessage {
        CoupleMessage(id: id(number), authorID: "a", recipientID: "b", text: "Message \(number)", sentAt: Date(timeIntervalSince1970: seconds))
    }
    private func photo(_ number: Int, at seconds: Double) -> CouplePhoto {
        CouplePhoto(id: id(number), authorId: "a", recipientId: "b", caption: "", photo: CoupleAvatar(id: id(100),
            sha256: String(repeating: "a", count: 64)), sentAt: Date(timeIntervalSince1970: seconds))
    }
    private func letter(_ number: Int, at seconds: Double) throws -> TimeCapsuleLetter {
        let value: [String: Any] = ["id": id(number), "authorId": "a", "recipientId": "b", "status": "sealed",
            "createdAt": seconds * 1_000, "sentAt": seconds * 1_000, "opensAt": 900_000, "canOpen": false]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TimeCapsuleLetter.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

@MainActor
private final class ChatHistoryGate<Value: Sendable> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolved: Value?
    init(_ description: String) { started = XCTestExpectation(description: description) }
    func value() async -> Value {
        if let resolved { return resolved }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func resolve(_ value: Value) {
        guard resolved == nil else { return }
        resolved = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
