import Foundation
import XCTest
@testable import PairNotesCore

final class DraftStoreTests: XCTestCase {
    // Opaque bytes are deliberately not claimed to be an Apple document.
    private let source = Data([0, 255, 80, 65, 80, 69, 82, 0, 128])
    private let image = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    )!

    private func fixture(id: UUID = UUID(), revision: UInt64 = 1) throws -> DraftArchive {
        try DraftArchive.make(id: id, revision: revision, nativeData: source,
                              finalPNG: image, widgetPNG: image, thumbnailPNG: image)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testOpaqueSourceAndAllDerivativesRoundTripAfterReopening() async throws {
        let directory = temporaryDirectory()
        let archive = try fixture()
        try await FileDraftStore(directory: directory).save(archive)
        let restored = try await FileDraftStore(directory: directory).load(id: archive.document.id)
        XCTAssertEqual(restored, archive)
        XCTAssertEqual(restored?.source.data, source)
        XCTAssertEqual(restored?.image(for: .widget)?.pngData, image)
    }

    func testOlderAndDuplicateRevisionsCannotOverwriteNewerSave() async throws {
        let directory = temporaryDirectory()
        let newer = try fixture(revision: 8)
        let store = FileDraftStore(directory: directory)
        try await store.save(newer)
        for revision: UInt64 in [7, 8] {
            do {
                try await store.save(fixture(id: newer.document.id, revision: revision))
                XCTFail("An obsolete serialization must not overwrite revision 8")
            } catch {
                XCTAssertEqual(error as? LocalStoreError, .obsoleteRevision)
            }
        }
        let restored = try await store.load(id: newer.document.id)
        XCTAssertEqual(restored, newer)
    }

    func testRevisionCheckSurvivesStoreRecreation() async throws {
        let directory = temporaryDirectory()
        let archive = try fixture(revision: 3)
        try await FileDraftStore(directory: directory).save(archive)
        do {
            try await FileDraftStore(directory: directory).save(fixture(id: archive.document.id))
            XCTFail("Reopening must not reset the revision guard")
        } catch {
            XCTAssertEqual(error as? LocalStoreError, .obsoleteRevision)
        }
    }

    func testConcurrentSerializationsKeepTheHighestCompletedRevision() async throws {
        let store = FileDraftStore(directory: temporaryDirectory())
        let id = UUID()
        let archives = try (1...12).map { try fixture(id: id, revision: UInt64($0)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for archive in archives.reversed() {
                group.addTask {
                    do {
                        try await store.save(archive)
                    } catch LocalStoreError.obsoleteRevision {
                        // An earlier serialization may legitimately arrive late.
                    }
                }
            }
            try await group.waitForAll()
        }
        let restored = try await store.load(id: id)
        XCTAssertEqual(restored?.document.revision, 12)
    }

    func testMissingFileReturnsNilAndMalformedFileIsPreserved() async throws {
        let directory = temporaryDirectory()
        let archive = try fixture()
        let store = FileDraftStore(directory: directory)
        let missing = try await store.load(id: archive.document.id)
        XCTAssertNil(missing)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(archive.document.id.uuidString + ".pairnote")
        let broken = Data("incomplete archive".utf8)
        try broken.write(to: url)
        do {
            try await store.save(archive)
            XCTFail("A corrupt existing document must not be silently replaced")
        } catch {
            XCTAssertEqual(error as? LocalStoreError, .corruptData)
        }
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testFutureSchemaEditorAndUnknownEngineAreReadOnly() async throws {
        for modification: (inout [String: Any]) -> Void in [
            { $0["schemaVersion"] = 99 },
            { $0["minimumEditorVersion"] = 99 },
            { $0["editorKind"] = "future-engine-v1" }
        ] {
            let directory = temporaryDirectory()
            let archive = try fixture()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
            var document = try XCTUnwrap(json["document"] as? [String: Any])
            modification(&document)
            json["document"] = document
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(archive.document.id.uuidString + ".pairnote")
            try bytes.write(to: url)
            let store = FileDraftStore(directory: directory)
            let restored = try await store.load(id: archive.document.id)
            XCTAssertEqual(restored?.document.isEditable, false)
            XCTAssertEqual(restored?.image(for: .final)?.pngData, image)
            do {
                try await store.save(fixture(id: archive.document.id, revision: 100))
                XCTFail("An older editor must preserve a newer source")
            } catch {
                XCTAssertEqual(error as? LocalStoreError, .unsupportedVersion)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testMixedRenderRevisionsAndMissingDerivativesAreRejected() throws {
        let archive = try fixture()
        let newer = try fixture(id: archive.document.id, revision: 2)
        let mixed = DraftArchive(document: archive.document, source: archive.source, renders: newer.renders)
        XCTAssertThrowsError(try mixed.validateIntegrity()) {
            XCTAssertEqual($0 as? LocalStoreError, .inconsistentRevision)
        }
        let missing = DraftArchive(document: archive.document, source: archive.source,
                                   renders: Array(archive.renders.dropLast()))
        XCTAssertThrowsError(try missing.validateIntegrity()) {
            XCTAssertEqual($0 as? LocalStoreError, .missingRender)
        }
    }

    func testChangedSourceBytesCannotKeepTheOldHash() throws {
        let archive = try fixture()
        let altered = NativeSource(documentID: archive.document.id, revision: 1,
                                   revisionHash: archive.document.revisionHash, data: Data([1, 2, 3]))
        let broken = DraftArchive(document: archive.document, source: altered, renders: archive.renders)
        XCTAssertThrowsError(try broken.validateIntegrity()) {
            XCTAssertEqual($0 as? LocalStoreError, .inconsistentRevision)
        }
    }

    func testPortableSHA256AgainstStandardKnownVectors() {
        XCTAssertEqual(ContentDigest.sha256(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ContentDigest.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ContentDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}
