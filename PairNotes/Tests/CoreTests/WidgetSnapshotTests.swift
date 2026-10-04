import Foundation
import XCTest
@testable import PairNotesCore

final class WidgetSnapshotTests: XCTestCase {
    private let image = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    )!

    private func fixture(noteID: UUID = UUID(), revision: UInt64 = 1, date: TimeInterval = 100) -> NoteWidgetSnapshot {
        NoteWidgetSnapshot(noteID: noteID, revision: revision,
                           revisionHash: ContentDigest.sha256(Data("opaque-source".utf8)),
                           authorName: "Sol (demo)", updatedAt: Date(timeIntervalSince1970: date),
                           pngData: image)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testWriterAndIndependentWidgetReaderSeeCoherentSnapshot() async throws {
        let directory = temporaryDirectory()
        let writer = WidgetSnapshotStore(directory: directory)
        let reader = WidgetSnapshotStore(directory: directory)
        let empty = try await reader.read()
        XCTAssertNil(empty)
        let snapshot = fixture()
        try await writer.write(snapshot)
        let first = try await reader.read()
        XCTAssertEqual(first, snapshot)
        let replacement = fixture(noteID: snapshot.noteID, revision: 2, date: 200)
        try await writer.write(replacement)
        let second = try await reader.read()
        XCTAssertEqual(second, replacement)
        try await writer.clear()
        let cleared = try await reader.read()
        XCTAssertNil(cleared)
    }

    func testDuplicateSnapshotIsIdempotentButOldRevisionCannotReplaceIt() async throws {
        let store = WidgetSnapshotStore(directory: temporaryDirectory())
        let snapshot = fixture(revision: 4)
        try await store.write(snapshot)
        try await store.write(snapshot)
        do {
            try await store.write(fixture(noteID: snapshot.noteID, revision: 3, date: 200))
            XCTFail("A late old render must not replace the current revision")
        } catch {
            XCTAssertEqual(error as? LocalStoreError, .obsoleteRevision)
        }
        let current = try await store.read()
        XCTAssertEqual(current, snapshot)
    }

    func testOlderDifferentNoteCannotReplaceLatestSnapshot() async throws {
        let store = WidgetSnapshotStore(directory: temporaryDirectory())
        let current = fixture(date: 500)
        try await store.write(current)
        do {
            try await store.write(fixture(date: 100))
            XCTFail("Out-of-order snapshots must preserve the latest note")
        } catch {
            XCTAssertEqual(error as? LocalStoreError, .obsoleteRevision)
        }
        let restored = try await store.read()
        XCTAssertEqual(restored, current)
    }

    func testCorruptImageAndFutureSnapshotSchemaAreRejected() async throws {
        for modification: (inout [String: Any]) -> Void in [
            { $0["pngData"] = Data([0, 1, 2]).base64EncodedString() },
            { $0["schemaVersion"] = 99 }
        ] {
            let directory = temporaryDirectory()
            let snapshot = fixture()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
            modification(&json)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bytes = try JSONSerialization.data(withJSONObject: json)
            let url = directory.appendingPathComponent("note-widget.json")
            try bytes.write(to: url)
            let store = WidgetSnapshotStore(directory: directory)
            do {
                _ = try await store.read()
                XCTFail("Unsupported/corrupt snapshots must not reach the widget")
            } catch let error as LocalStoreError {
                XCTAssertTrue([.corruptData, .unsupportedVersion].contains(error))
            }
            do {
                try await store.write(fixture(revision: 100, date: 1_000))
                XCTFail("Preserve an unrecognized existing envelope")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testMalformedSnapshotFailsWithoutFabricatingContent() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appendingPathComponent("note-widget.json"))
        do {
            _ = try await WidgetSnapshotStore(directory: directory).read()
            XCTFail("An incomplete envelope is not an empty snapshot")
        } catch {
            XCTAssertEqual(error as? LocalStoreError, .corruptData)
        }
    }

    func testMockProvidersUseFictitiousIdentityAndDoNotRequestLocation() async {
        let user = await MockIdentityProvider().currentUser()
        let notes = await MockNotesRepository().notes()
        let location = await MockLocationProvider().state()
        let signedOut = await MockIdentityProvider(user: nil).currentUser()
        XCTAssertEqual(user?.id, "demo-luna")
        XCTAssertTrue(notes.allSatisfy { $0.author.id.hasPrefix("demo-") })
        XCTAssertEqual(location, .notRequested)
        XCTAssertNil(signedOut)
    }
}
