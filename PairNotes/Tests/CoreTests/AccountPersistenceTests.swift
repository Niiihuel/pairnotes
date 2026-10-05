import Foundation
import XCTest
@testable import PairNotesCore

private enum Fixtures {
    static func archive(id: UUID = UUID(), revision: UInt64 = 1) throws -> DraftArchive {
        try DraftArchive.make(id: id, revision: revision,
                              nativeData: Data("opaque-native-\(revision)".utf8),
                              finalPNG: Data([1, 2, 3]), widgetPNG: Data([4, 5, 6]), thumbnailPNG: Data([7, 8, 9]))
    }

    static func context(epoch: UInt64 = 1) -> PublicationContext {
        PublicationContext(authorID: "fictional-alex", pairID: "fictional-pair", pairEpoch: epoch,
                           recipientID: "fictional-sam")
    }

    static func note(for operation: OutboxOperation, revision: UInt64? = nil) -> RemoteNote {
        let prefix = "pairs/\(operation.context.pairID)/\(operation.context.pairEpoch)/\(operation.id.uuidString.lowercased())/"
        return RemoteNote(id: operation.id.uuidString.lowercased(), pairID: operation.context.pairID,
                   pairEpoch: operation.context.pairEpoch, authorID: operation.context.authorID,
                   recipientID: operation.context.recipientID,
                   revision: revision ?? operation.archive.document.revision,
                   revisionHash: operation.archive.document.revisionHash,
                   serverPublishedAt: Date(timeIntervalSince1970: 100),
                   assets: NoteAssetPaths(source: prefix + "source", final: prefix + "final",
                                          widget: prefix + "widget", thumbnail: prefix + "thumbnail"))
    }
}

private extension XCTestCase {
    func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

final class AccountPersistenceTests: XCTestCase {
    func testStickersAreDeduplicatedScopedAndDigestChecked() async throws {
        let root = directory()
        let alice = DraftCatalogStore(directory: root, account: .user(uid: "alice"))
        let bob = DraftCatalogStore(directory: root, account: .user(uid: "bob"))
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        let id = try await alice.saveSticker(png)
        let duplicate = try await alice.saveSticker(png)
        XCTAssertEqual(id, duplicate)
        let ids = try await alice.stickerIDs(), other = try await bob.stickerIDs()
        XCTAssertEqual(ids, [id]); XCTAssertTrue(other.isEmpty)
        let restored = try await alice.sticker(id)
        XCTAssertEqual(restored, png)
        do { _ = try await alice.sticker("../outside"); XCTFail("Reject path traversal") } catch {}
        do { _ = try await alice.saveSticker(Data("not an image".utf8)); XCTFail("Reject invalid signature") } catch {}
        try await alice.removeSticker(id)
        let remaining = try await alice.stickerIDs()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUndoDeletionRestoresExactSourceAndNeverOverwritesNewerDraft() async throws {
        let store = DraftCatalogStore(directory: directory(), account: .user(uid: "fictional-alex"))
        let archive = try Fixtures.archive(revision: 3)
        let summary = try await store.save(archive, title: "Nuestro dibujo")
        try await store.remove(id: summary.id)
        try await store.restoreRemoved(archive, summary: summary)
        let restored = try await store.load(id: summary.id)
        let listing = try await store.list()
        XCTAssertEqual(restored, archive)
        XCTAssertEqual(listing, [summary])
        let newer = try Fixtures.archive(id: summary.id, revision: 4)
        try await store.save(newer)
        do { try await store.restoreRemoved(archive, summary: summary); XCTFail("Undo must not overwrite new edits") }
        catch { XCTAssertEqual(error as? LocalStoreError, .obsoleteRevision) }
        let latest = try await store.load(id: summary.id)
        XCTAssertEqual(latest, newer)
    }

    func testUndoRejectsArchiveFromAnotherDocument() async throws {
        let store = DraftCatalogStore(directory: directory(), account: .guest)
        let archive = try Fixtures.archive()
        let summary = try await store.save(archive)
        try await store.remove(id: summary.id)
        do { try await store.restoreRemoved(Fixtures.archive(), summary: summary); XCTFail("Mismatched source must not be restored") }
        catch { XCTAssertEqual(error as? LocalStoreError, .inconsistentRevision) }
        let listing = try await store.list()
        XCTAssertTrue(listing.isEmpty)
    }

    func testGuestAndAccountsHaveSeparateCatalogsEvenForHostileUID() async throws {
        let root = directory()
        let guest = DraftCatalogStore(directory: root, account: .guest)
        let alice = DraftCatalogStore(directory: root, account: .user(uid: "../../fictional-alex"))
        let bob = DraftCatalogStore(directory: root, account: .user(uid: "fictional-sam"))
        let guestArchive = try Fixtures.archive()
        let aliceArchive = try Fixtures.archive()
        try await guest.save(guestArchive)
        try await alice.save(aliceArchive)
        let aliceList = try await alice.list()
        let bobList = try await bob.list()
        let guestFromAlice = try await alice.load(id: guestArchive.document.id)
        let aliceFromGuest = try await guest.load(id: aliceArchive.document.id)
        XCTAssertEqual(aliceList.map(\.id), [aliceArchive.document.id])
        XCTAssertTrue(bobList.isEmpty)
        XCTAssertNil(guestFromAlice)
        XCTAssertNil(aliceFromGuest)
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(folders.allSatisfy { $0 == "guest" || ($0.hasPrefix("account-") && $0.count == 72) })
    }

    func testCatalogReopensMultipleDraftsAndRejectsDelayedOlderSave() async throws {
        let root = directory()
        let first = try Fixtures.archive(revision: 4)
        let second = try Fixtures.archive()
        let initial = DraftCatalogStore(directory: root, account: .user(uid: "fictional-alex"))
        try await initial.save(first, title: "Primero", at: Date(timeIntervalSince1970: 10))
        try await initial.save(second, title: "Segundo", at: Date(timeIntervalSince1970: 20))
        let reopened = DraftCatalogStore(directory: root, account: .user(uid: "fictional-alex"))
        let summaries = try await reopened.list()
        XCTAssertEqual(summaries.map(\.id), [second.document.id, first.document.id])
        do {
            try await reopened.save(Fixtures.archive(id: first.document.id, revision: 3))
            XCTFail("Older captures cannot overwrite a committed revision")
        } catch { XCTAssertEqual(error as? LocalStoreError, .obsoleteRevision) }
        let restored = try await reopened.load(id: first.document.id)
        XCTAssertEqual(restored, first)
    }

    func testCorruptIndexIsNotSilentlyReplacedBySave() async throws {
        let root = directory()
        let scope = DraftAccountScope.user(uid: "fictional-alex")
        let store = DraftCatalogStore(directory: root, account: scope)
        try await store.save(Fixtures.archive())
        let index = root.appendingPathComponent(scope.directoryName).appendingPathComponent("index.json")
        let corrupt = Data("unfinished-index".utf8)
        try corrupt.write(to: index)
        do {
            try await store.save(Fixtures.archive())
            XCTFail("Corrupt metadata must require recovery, not truncate other drafts")
        } catch { XCTAssertEqual(error as? LocalStoreError, .corruptData) }
        XCTAssertEqual(try Data(contentsOf: index), corrupt)
    }

    func testBrokenReferencedArchiveCannotBeOverwrittenWithNewRevision() async throws {
        let root = directory()
        let archive = try Fixtures.archive()
        let store = DraftCatalogStore(directory: root, account: .guest)
        try await store.save(archive)
        let path = root.appendingPathComponent("guest/\(archive.document.id.uuidString)-1.pairnote")
        let damaged = Data([0, 1, 2])
        try damaged.write(to: path)
        do {
            try await store.save(Fixtures.archive(id: archive.document.id, revision: 2))
            XCTFail("Preserve evidence of corruption")
        } catch { XCTAssertEqual(error as? LocalStoreError, .corruptData) }
        XCTAssertEqual(try Data(contentsOf: path), damaged)
    }

    func testExplicitCopyPreservesSourceAndCreatesIndependentIdentity() async throws {
        let archive = try Fixtures.archive(revision: 8)
        let store = DraftCatalogStore(directory: directory(), account: .user(uid: "fictional-alex"))
        let copied = try await store.importCopy(archive, title: "Copia recibida")
        XCTAssertNotEqual(copied.document.id, archive.document.id)
        XCTAssertEqual(copied.document.revision, 1)
        XCTAssertEqual(copied.source.data, archive.source.data)
        XCTAssertEqual(copied.image(for: .final)?.pngData, archive.image(for: .final)?.pngData)
        let summaries = try await store.list()
        XCTAssertEqual(summaries.first?.title, "Copia recibida")
    }

    func testDeleteOneDraftLeavesAnotherAvailable() async throws {
        let first = try Fixtures.archive()
        let second = try Fixtures.archive()
        let store = DraftCatalogStore(directory: directory(), account: .guest)
        try await store.save(first)
        try await store.save(second)
        try await store.remove(id: first.document.id)
        let removed = try await store.load(id: first.document.id)
        let retained = try await store.load(id: second.document.id)
        XCTAssertNil(removed)
        XCTAssertEqual(retained, second)
    }

    func testUncommittedRevisionIsInvisibleUntilIndexCommitAndCanBeRetried() async throws {
        let root = directory()
        let archive = try Fixtures.archive()
        let folder = root.appendingPathComponent("guest")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("\(archive.document.id.uuidString)-1.pairnote")
        try JSONEncoder().encode(archive).write(to: path, options: .atomic)
        let store = DraftCatalogStore(directory: root, account: .guest)
        let beforeCommit = try await store.list()
        XCTAssertTrue(beforeCommit.isEmpty)
        try await store.save(archive)
        let afterCommit = try await store.load(id: archive.document.id)
        XCTAssertEqual(afterCommit, archive)
    }
}

final class DurableOutboxTests: XCTestCase {
    func testRetryAndRestartRetainImmutableBytesAndIdempotencyKey() async throws {
        let root = directory()
        let context = Fixtures.context()
        let archive = try Fixtures.archive()
        let key = UUID()
        let store = DurableOutbox(directory: root, accountUID: context.authorID)
        let queued = try await store.enqueue(archive: archive, context: context, idempotencyKey: key)
        let firstAttempt = try await store.markSending(id: key, context: context)
        XCTAssertEqual(firstAttempt.attempts, 1)
        let reopened = DurableOutbox(directory: root, accountUID: context.authorID)
        try await reopened.recoverInterrupted()
        let pending = try await reopened.pending(context: context)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.archive, queued.archive)
        XCTAssertEqual(pending.first?.idempotencyKey, key)
        let retry = try await reopened.markSending(id: key, context: context)
        XCTAssertEqual(retry.attempts, 2)
        try await reopened.markFailed(id: key, context: context, code: "network-unavailable")
        let noAutomaticRetry = try await reopened.pending(context: context)
        XCTAssertTrue(noAutomaticRetry.isEmpty)
        try await reopened.retry(id: key, context: context)
        let retried = try await reopened.pending(context: context)
        XCTAssertEqual(retried.first?.id, key)
        XCTAssertEqual(retried.first?.archive.source.data, archive.source.data)
    }

    func testDuplicateEnqueueWithSameKeyIsIdempotentButDifferentCaptureFails() async throws {
        let context = Fixtures.context()
        let archive = try Fixtures.archive()
        let store = DurableOutbox(directory: directory(), accountUID: context.authorID)
        let key = UUID()
        let first = try await store.enqueue(archive: archive, context: context, idempotencyKey: key)
        let second = try await store.enqueue(archive: archive, context: context, idempotencyKey: key)
        XCTAssertEqual(first, second)
        do {
            try await store.enqueue(archive: Fixtures.archive(id: archive.document.id, revision: 2),
                                    context: context, idempotencyKey: key)
            XCTFail("An idempotency key cannot identify different bytes")
        } catch { XCTAssertEqual(error as? AccountDomainError, .conflictingOperation) }
        let stored = try await store.list()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.archive, archive)
    }

    func testOldEpochIsCancelledAndNeverRetargeted() async throws {
        let context = Fixtures.context()
        let newerContext = Fixtures.context(epoch: 2)
        let store = DurableOutbox(directory: directory(), accountUID: context.authorID)
        let queued = try await store.enqueue(archive: Fixtures.archive(), context: context)
        do {
            try await store.markSending(id: queued.id, context: newerContext)
            XCTFail("A captured operation belongs to its original relationship epoch")
        } catch { XCTAssertEqual(error as? AccountDomainError, .staleContext) }
        try await store.cancelPending(except: newerContext)
        let stored = try await store.list()
        XCTAssertEqual(stored.first?.status, .cancelled)
        XCTAssertEqual(stored.first?.context, context)
        do {
            try await store.markSending(id: queued.id, context: context)
            XCTFail("Cancelled work cannot restart after a delayed callback")
        } catch { XCTAssertEqual(error as? AccountDomainError, .invalidTransition) }
    }

    func testAccountSwitchCannotReadOrSendOtherAccountsQueue() async throws {
        let root = directory()
        let context = Fixtures.context()
        let alice = DurableOutbox(directory: root, accountUID: context.authorID)
        let queued = try await alice.enqueue(archive: Fixtures.archive(), context: context)
        let bob = DurableOutbox(directory: root, accountUID: context.recipientID)
        let bobList = try await bob.list()
        XCTAssertTrue(bobList.isEmpty)
        do {
            try await bob.markSending(id: queued.id, context: context)
            XCTFail("No sending under an unrelated identity")
        } catch { XCTAssertEqual(error as? AccountDomainError, .accountMismatch) }
        try await alice.cancelPending(except: nil)
        let aliceList = try await alice.list()
        XCTAssertEqual(aliceList.first?.status, .cancelled)
    }

    func testOnlyMatchingServerConfirmationMarksSent() async throws {
        let context = Fixtures.context()
        let store = DurableOutbox(directory: directory(), accountUID: context.authorID)
        let operation = try await store.enqueue(archive: Fixtures.archive(), context: context)
        try await store.markSending(id: operation.id, context: context)
        do {
            try await store.markSent(id: operation.id, context: context, note: Fixtures.note(for: operation, revision: 99))
            XCTFail("An upload response with a different revision is not publication confirmation")
        } catch { XCTAssertEqual(error as? AccountDomainError, .invalidPublication) }
        let beforeConfirmation = try await store.list()
        XCTAssertEqual(beforeConfirmation.first?.status, .sending)
        let note = Fixtures.note(for: operation)
        try await store.markSent(id: operation.id, context: context, note: note)
        try await store.markSent(id: operation.id, context: context, note: note)
        let confirmed = try await store.list()
        XCTAssertEqual(confirmed.first?.status, .sent)
        XCTAssertEqual(confirmed.first?.publishedNote, note)
    }

    func testCorruptQueueFileIsPreservedAndBlocksSilentRecovery() async throws {
        let root = directory()
        let context = Fixtures.context()
        let store = DurableOutbox(directory: root, accountUID: context.authorID)
        let operation = try await store.enqueue(archive: Fixtures.archive(), context: context)
        let namespace = "account-" + ContentDigest.sha256(Data(context.authorID.utf8))
        let path = root.appendingPathComponent(namespace).appendingPathComponent(operation.id.uuidString + ".outbox")
        let corrupt = Data("broken-operation".utf8)
        try corrupt.write(to: path)
        do {
            try await store.recoverInterrupted()
            XCTFail("Do not silently drop an unconfirmed note")
        } catch { XCTAssertEqual(error as? LocalStoreError, .corruptData) }
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
    }

    func testMixedRevisionsCannotEnterQueue() async throws {
        let context = Fixtures.context()
        let store = DurableOutbox(directory: directory(), accountUID: context.authorID)
        let old = try Fixtures.archive()
        let newer = try Fixtures.archive(id: old.document.id, revision: 2)
        let inconsistent = DraftArchive(document: old.document, source: old.source, renders: newer.renders)
        do {
            try await store.enqueue(archive: inconsistent, context: context)
            XCTFail("Every outgoing derivative must belong to the captured source revision")
        } catch { XCTAssertEqual(error as? LocalStoreError, .inconsistentRevision) }
        let stored = try await store.list()
        XCTAssertTrue(stored.isEmpty)
    }

    func testCancellingAnObsoleteCaptureLeavesNewSessionWorkQueued() async throws {
        let context = Fixtures.context()
        let store = DurableOutbox(directory: directory(), accountUID: context.authorID)
        let old = try await store.enqueue(archive: Fixtures.archive(), context: context)
        let new = try await store.enqueue(archive: Fixtures.archive(), context: context)
        try await store.cancel(id: old.id, context: context)
        let queued = try await store.pending(context: context)
        XCTAssertEqual(queued.map(\.id), [new.id])
        let entries = try await store.list()
        XCTAssertEqual(entries.first { $0.id == old.id }?.status, .cancelled)
    }
}
