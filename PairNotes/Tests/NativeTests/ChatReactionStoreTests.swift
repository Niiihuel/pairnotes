import Combine
import Foundation
import PairNotesCore
import XCTest
@testable import PairNotes

final class ChatReactionStoreTests: XCTestCase {
    @MainActor
    func testSelectionAndFeedbackWaitForConfirmedPostAndFailedRemovalPreservesIt() async {
        let store = ChatReactionStore(), target = target(1)
        let gate = ChatReactionGate<[ChatReaction]>("POST started")
        let confirmed = reaction(target, .heart, at: 2)
        var fail = false
        let source = source(load: { _ in [] }, set: { _, _ in
            if fail { throw URLError(.notConnectedToInternet) }
            return await gate.value()
        })
        await store.refresh(source: source, targets: [target])
        let sending = Task { await store.setReaction(.heart, for: target, source: source, expectedScope: "pair") }
        defer { gate.resolve([]); sending.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        XCTAssertTrue(store.isReacting(target))
        XCTAssertNil(store.myReaction(for: target))
        XCTAssertEqual(store.confirmationRevision(target), 0)
        gate.resolve([confirmed]); await sending.value
        XCTAssertEqual(store.myReaction(for: target), confirmed)
        XCTAssertFalse(store.isReacting(target))
        XCTAssertEqual(store.confirmationRevision(target), 1)
        fail = true
        await store.setReaction(nil, for: target, source: source, expectedScope: "pair")
        XCTAssertEqual(store.myReaction(for: target), confirmed)
        XCTAssertNotNil(store.error(for: target))
        XCTAssertEqual(store.confirmationRevision(target), 1)
    }

    @MainActor
    func testGetsBeforeAndDuringPostCannotOverwriteConfirmationOrResurrectRemoval() async {
        let store = ChatReactionStore(), target = target(1)
        let before = ChatReactionGate<[ChatReaction]>("Old GET started")
        let during = ChatReactionGate<[ChatReaction]>("GET during POST started")
        let removal = ChatReactionGate<[ChatReaction]>("Removal started")
        var loadingBefore = true
        var removing = false
        let old = reaction(target, .laugh, at: 1), heart = reaction(target, .heart, at: 2)
        let source = source(load: { _ in
            loadingBefore ? await before.value() : await during.value()
        }, set: { _, _ in removing ? await removal.value() : [heart] })
        let first = Task { await store.refresh(source: source, targets: [target]) }
        defer { before.resolve([]); during.resolve([]); removal.resolve([]); first.cancel() }
        await fulfillment(of: [before.started], timeout: 2)
        await store.setReaction(.heart, for: target, source: source, expectedScope: "pair")
        before.resolve([old]); await first.value
        XCTAssertEqual(store.myReaction(for: target), heart)
        loadingBefore = false; removing = true
        let post = Task { await store.setReaction(nil, for: target, source: source, expectedScope: "pair") }
        defer { post.cancel() }
        await fulfillment(of: [removal.started], timeout: 2)
        let second = Task { await store.refresh(source: source, targets: [target]) }
        defer { second.cancel() }
        await fulfillment(of: [during.started], timeout: 2)
        removal.resolve([]); await post.value
        XCTAssertNil(store.myReaction(for: target))
        during.resolve([heart]); await second.value
        XCTAssertTrue(store.reactions(for: target).isEmpty)
        XCTAssertEqual(store.confirmationRevision(target), 2)
    }

    @MainActor
    func testScopeChangesHideOldStateImmediatelyAndRejectOldPostBeforeRPC() async {
        let store = ChatReactionStore(), target = target(1)
        var scope = "old-pair", writes = 0
        let gate = ChatReactionGate<[ChatReaction]>("GET started")
        var waiting = false
        let source = source(scope: { scope }, load: { _ in waiting ? await gate.value() : [self.reaction(target, .heart, at: 1)] },
                            set: { _, _ in writes += 1; return [] })
        await store.refresh(source: source, targets: [target])
        XCTAssertNotNil(store.myReaction(for: target))
        waiting = true
        let old = Task { await store.refresh(source: source, targets: [target]) }
        defer { gate.resolve([]); old.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        scope = "new-pair"
        XCTAssertTrue(store.reactions(for: target).isEmpty, "Reads must hide stale data before the view resets")
        XCTAssertNil(store.myReaction(for: target))
        await store.setReaction(.heart, for: target, source: source, expectedScope: "old-pair")
        XCTAssertEqual(writes, 0)
        store.reset()
        await store.refresh(source: self.source(scope: { scope }, load: { _ in [] }), targets: [target])
        gate.resolve([reaction(target, .heart, at: 1)]); await old.value
        XCTAssertEqual(store.loadedScope, "new-pair")
        XCTAssertTrue(store.reactions(for: target).isEmpty)
        XCTAssertFalse(store.loading)
    }

    @MainActor
    func testCancelledPostNeverShowsFeedbackAndOldPostCannotClearNewScopeBusyState() async {
        let store = ChatReactionStore(), target = target(1)
        let first = ChatReactionGate<[ChatReaction]>("Old POST started")
        let second = ChatReactionGate<[ChatReaction]>("New POST started")
        var scope = "first"
        let oldSource = source(scope: { scope }, set: { _, _ in await first.value() })
        await store.refresh(source: oldSource, targets: [target])
        let old = Task { await store.setReaction(.heart, for: target, source: oldSource, expectedScope: "first") }
        defer { first.resolve([]); second.resolve([]); old.cancel() }
        await fulfillment(of: [first.started], timeout: 2)
        old.cancel(); store.reset(); scope = "second"
        let newSource = source(scope: { scope }, set: { _, _ in await second.value() })
        await store.refresh(source: newSource, targets: [target])
        let new = Task { await store.setReaction(.fire, for: target, source: newSource, expectedScope: "second") }
        defer { new.cancel() }
        await fulfillment(of: [second.started], timeout: 2)
        first.resolve([reaction(target, .heart, at: 1)]); await old.value
        XCTAssertTrue(store.isReacting(target))
        XCTAssertEqual(store.confirmationRevision(target), 0)
        second.resolve([reaction(target, .fire, at: 2)]); await new.value
        XCTAssertEqual(store.myReaction(for: target)?.kind, .fire)
        XCTAssertEqual(store.confirmationRevision(target), 1)
        XCTAssertFalse(store.isReacting(target))
    }

    @MainActor
    func testRefreshBatchesOverOneHundredTargetsAndKeepsNewerActorValuesWithoutFeedback() async {
        let store = ChatReactionStore()
        let targets = (1...205).map(target)
        var batches: [[ChatReactionTarget]] = [], newer = true
        let source = source(load: { batch in
            batches.append(batch)
            return batch.map { self.reaction($0, newer ? .heart : .laugh, at: newer ? 2 : 1) }
        })
        await store.refresh(source: source, targets: targets + [targets[0]])
        XCTAssertEqual(batches.map(\.count), [100, 100, 5])
        XCTAssertEqual(Set(batches.flatMap { $0 }), Set(targets))
        newer = false
        await store.refresh(source: source, targets: [targets[0]])
        XCTAssertEqual(store.myReaction(for: targets[0])?.kind, .heart)
        XCTAssertEqual(store.confirmationRevision(targets[0]), 0)
    }

    @MainActor
    func testConcurrentRefreshesCoalesceIntoOneLatestTargetFetch() async {
        let store = ChatReactionStore(), firstTarget = target(1), latestTarget = target(3)
        let gate = ChatReactionGate<[ChatReaction]>("First GET started")
        let followUp = expectation(description: "Latest targets fetched")
        var requests: [[ChatReactionTarget]] = []
        let source = source(load: { targets in
            requests.append(targets)
            if requests.count == 1 { return await gate.value() }
            followUp.fulfill()
            return [self.reaction(latestTarget, .heart, at: 1)]
        })
        let first = Task { await store.refresh(source: source, targets: [firstTarget]) }
        defer { gate.resolve([]); first.cancel() }
        await fulfillment(of: [gate.started], timeout: 2)
        await store.refresh(source: source, targets: [target(2)])
        await store.refresh(source: source, targets: [latestTarget])
        gate.resolve([]); await first.value
        await fulfillment(of: [followUp], timeout: 2)
        XCTAssertEqual(requests, [[firstTarget], [latestTarget]])
        XCTAssertEqual(store.myReaction(for: latestTarget)?.kind, .heart)
        XCTAssertEqual(store.confirmationRevision(latestTarget), 0)
    }

    @MainActor
    private func source(scope: @escaping () -> String = { "pair" },
                        load: @escaping @MainActor ([ChatReactionTarget]) async throws -> [ChatReaction] = { _ in [] },
                        set: @escaping @MainActor (ChatReactionTarget, ChatReactionKind?) async throws -> [ChatReaction] = { _, _ in [] }) -> ChatReactionSource {
        ChatReactionSource(currentScope: scope, ownUID: { "alice" }, isAuthorized: { true },
                           reactions: load, setReaction: set)
    }
    private func target(_ number: Int) -> ChatReactionTarget {
        ChatReactionTarget(type: .message, id: String(format: "00000000-0000-4000-8000-%012d", number))
    }
    private func reaction(_ target: ChatReactionTarget, _ kind: ChatReactionKind, at seconds: Double) -> ChatReaction {
        ChatReaction(targetType: target.type, targetID: target.id, authorID: "alice", kind: kind,
                     updatedAt: Date(timeIntervalSince1970: seconds))
    }
}

@MainActor
private final class ChatReactionGate<Value: Sendable> {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Value, Never>?
    private var resolved: Value?
    init(_ description: String) { started = XCTestExpectation(description: description) }
    func value() async -> Value {
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func resolve(_ value: Value) {
        guard resolved == nil else { return }
        resolved = value; continuation?.resume(returning: value); continuation = nil
    }
}
