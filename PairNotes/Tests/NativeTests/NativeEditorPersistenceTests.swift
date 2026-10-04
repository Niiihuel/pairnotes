import XCTest
import PaperKit
import PairNotesCore
@testable import PairNotes

final class NativeEditorPersistenceTests: XCTestCase {
    @MainActor
    func testNewCanvasIsBlankAndSavedMixedDraftReopensWithoutChangingPublicationCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let editor = NativePaperSession(store: store, draft: nil)
        await editor.load()
        let blank = try XCTUnwrap(editor.controller.canvas.markup)
        let blankText = await blank.indexableContent
        XCTAssertFalse(blankText?.contains("Un recuerdo inventado") == true)
        editor.controller.canvas.markup = PaperProbeDocument.fixture()
        editor.title = "Recuerdo ficticio"
        editor.changed()
        let captured = await editor.save()
        let archive = try XCTUnwrap(captured)
        try archive.validateIntegrity()
        XCTAssertEqual(archive.renders.count, 3)
        let summaries = try await store.list()
        let summary = try XCTUnwrap(summaries.first)
        let reopened = NativePaperSession(store: store, draft: summary)
        await reopened.load()
        XCTAssertFalse(reopened.readOnly)
        XCTAssertEqual(reopened.title, "Recuerdo ficticio")
        let restored = try XCTUnwrap(reopened.controller.canvas.markup)
        let restoredText = await restored.indexableContent
        XCTAssertTrue(restoredText?.contains("Un recuerdo inventado") == true)
        reopened.title = "Otro título local"
        let savedAgain = await reopened.save()
        let newer = try XCTUnwrap(savedAgain)
        XCTAssertGreaterThan(newer.document.revision, archive.document.revision)
        XCTAssertEqual(archive.document.revision, 1, "Previously captured publication stays immutable")
        let another = NativePaperSession(store: store, draft: nil)
        await another.load()
        let anotherSaved = await another.save()
        let other = try XCTUnwrap(anotherSaved)
        XCTAssertNotEqual(other.document.id, archive.document.id)
        let all = try await store.list()
        XCTAssertEqual(all.count, 2)
    }
}
