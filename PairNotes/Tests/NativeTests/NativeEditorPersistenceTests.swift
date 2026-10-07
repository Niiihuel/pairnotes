import XCTest
import PaperKit
import PencilKit
import PairNotesCore
import UIKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import PairNotes

final class NativeEditorPersistenceTests: XCTestCase {
    @MainActor
    func testEyedropperAndAlignmentUseTopLeftPixelCoordinates() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 10, y: 20, width: 30, height: 40))
        }
        let cg = try XCTUnwrap(image.cgImage)
        let bounds = try XCTUnwrap(PaperPixelSampler.contentBounds(cg))
        XCTAssertEqual(bounds.minX, 0.1, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 0.2, accuracy: 0.01)
        XCTAssertEqual(bounds.width, 0.3, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 0.4, accuracy: 0.01)
        let sampled = try XCTUnwrap(PaperPixelSampler.color(cg, at: CGPoint(x: 0.2, y: 0.3)))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        sampled.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.01); XCTAssertEqual(g, 0, accuracy: 0.01)
        XCTAssertNil(PaperPixelSampler.color(cg, at: CGPoint(x: 0.8, y: 0.8)))
    }

    func testLetterDraftKeepsVoiceAndPrivateDrawingWhenTextChanges() throws {
        let storage = MemoryCompositionStorage(key: "letter-test:" + UUID().uuidString)
        let other = MemoryCompositionStorage(key: "other-letter:" + UUID().uuidString)
        defer { storage.clear(); other.clear() }
        var draft = LetterComposition(id: UUID().uuidString, title: "Para mañana", body: "Te quiero",
            opensAt: Date().addingTimeInterval(86400), noteID: "")
        try storage.saveValue(draft)
        let audio = Data("voice fixture".utf8), drawing = Data("private drawing fixture".utf8)
        try storage.saveAudio(audio); try storage.saveDrawing(drawing)
        draft.body += " mucho"; draft.sealAttempted = true
        try storage.saveValue(draft)
        let restored: LetterComposition? = storage.loadValue()
        XCTAssertEqual(restored, draft)
        XCTAssertEqual(storage.audio(), audio); XCTAssertEqual(storage.drawing(), drawing)
        XCTAssertNil(other.audio()); XCTAssertNil(other.drawing())
        storage.clear()
        XCTAssertNil(storage.audio()); XCTAssertNil(storage.drawing())
    }

    func testCompositionDraftSurvivesReopeningAndSeparatesAccountAndPair() throws {
        let key = UUID().uuidString
        let storage = MemoryCompositionStorage(key: "account-a:pair-a:" + key)
        let other = MemoryCompositionStorage(key: "account-b:pair-a:" + key)
        let nextPair = MemoryCompositionStorage(key: "account-a:pair-b:" + key)
        defer { storage.clear(); other.clear(); nextPair.clear() }
        var draft = MemoryCompositionDraft(id: "draft", title: "Nuestro viaje", date: Date(timeIntervalSince1970: 100),
            body: "Todavía estoy escribiendo", recursYearly: false, noteID: "", removePhoto: false,
            decoration: MemoryDecoration(layout: .journal, sticker: .flower))
        try storage.save(draft)
        let bytes = Data("private photo fixture".utf8)
        try storage.savePhoto(bytes)
        XCTAssertEqual(MemoryCompositionStorage(key: storage.key).load(), draft)
        XCTAssertEqual(storage.photo(), bytes)
        XCTAssertNil(other.load()); XCTAssertNil(other.photo()); XCTAssertNil(nextPair.load())
        draft.body += " más palabras"
        try storage.save(draft)
        XCTAssertEqual(storage.photo(), bytes, "Typing never rewrites or removes the photo")
        XCTAssertEqual(storage.load()?.body, draft.body)
        storage.clear()
        XCTAssertNil(storage.load()); XCTAssertNil(storage.photo())
    }

    @MainActor
    func testSharedThemeOnlyChangesNewPaperAndGuidesDoNotChangeSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let editor = NativePaperSession(store: store, draft: nil, theme: .night)
        await editor.load()
        XCTAssertEqual(editor.paperBackground, .charcoal)
        editor.controller.showsAlignmentGuides = true
        let saved = await editor.save()
        let archive = try XCTUnwrap(saved)
        let source = try PaperProbeDocument.decode(archive.source.data, editorVersion: archive.document.minimumEditorVersion)
        XCTAssertEqual(source.background, .charcoal)
        let summaries = try await store.list()
        let reopened = NativePaperSession(store: store, draft: try XCTUnwrap(summaries.first), theme: .cream)
        await reopened.load()
        XCTAssertEqual(reopened.paperBackground, .charcoal)
        XCTAssertFalse(reopened.controller.showsAlignmentGuides)
    }

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

    @MainActor
    func testPaperColorIsOpaqueSurvivesReopeningAndMatchesEveryPublishedRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let editor = NativePaperSession(store: store, draft: nil)
        await editor.load()
        editor.controller.loadViewIfNeeded()
        XCTAssertEqual(editor.paperBackground, .white)
        XCTAssertEqual(editor.controller.canvas.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(editor.controller.paperBackground, .white)

        let initial = await editor.save()
        let white = try XCTUnwrap(initial)
        try assertPaperPixels(white.image(for: .final)?.pngData, background: .white)
        editor.controller.canvas.markup = PaperProbeDocument.fixture()
        editor.paperBackground = .cream
        editor.changed()
        let saved = await editor.save()
        let colored = try XCTUnwrap(saved)
        try colored.validateIntegrity()
        XCTAssertEqual(colored.document.minimumEditorVersion, 3)
        for kind in RenderKind.allCases {
            try assertPaperPixels(colored.image(for: kind)?.pngData, background: .cream)
        }

        let summaries = try await store.list()
        let reopened = NativePaperSession(store: store, draft: try XCTUnwrap(summaries.first))
        await reopened.load()
        XCTAssertFalse(reopened.readOnly)
        XCTAssertEqual(reopened.paperBackground, .cream)
        XCTAssertEqual(reopened.controller.paperBackground, .cream)
        let text = await reopened.controller.canvas.markup?.indexableContent
        XCTAssertTrue(text?.contains("Un recuerdo inventado") == true)

        // A color-only edit belongs to the immutable source, not to transient UI
        // state. It must change the revision identity used by outbox and widgets.
        reopened.paperBackground = .rose
        let savedAgain = await reopened.save()
        let recolored = try XCTUnwrap(savedAgain, reopened.status)
        XCTAssertNotEqual(colored.document.revisionHash, recolored.document.revisionHash)
        XCTAssertGreaterThan(recolored.document.revision, colored.document.revision)
        try assertPaperPixels(recolored.image(for: .widget)?.pngData, background: .rose)
        try assertPaperPixels(colored.image(for: .widget)?.pngData, background: .cream)
        let opacityIgnored = PaperBackground(color: UIColor.red.withAlphaComponent(0.2))
        XCTAssertEqual(opacityIgnored, PaperBackground(red: 255, green: 0, blue: 0))
        XCTAssertEqual(PaperBackground.white.contrastingInkColor, UIColor.black)
        XCTAssertEqual(PaperBackground.charcoal.contrastingInkColor, UIColor.white)
    }

    @MainActor
    func testConcurrentSaveWaitsForNewestEditAndCancellingOneCallerPreservesTheWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = DraftCatalogStore(directory: directory, account: .guest)
        let writeStarted = expectation(description: "First immutable capture reached persistence")
        let store = PausingNativeDraftStore(catalog: catalog) { writeStarted.fulfill() }
        let editor = NativePaperSession(store: store, draft: nil)
        await editor.load()
        editor.title = "Primera captura"
        editor.paperBackground = .cream
        let firstFinished = expectation(description: "Cancelled caller stops waiting")
        let first = Task { @MainActor in
            let result = await editor.save()
            firstFinished.fulfill()
            return result
        }
        await fulfillment(of: [writeStarted], timeout: 10)
        let captured = await store.firstCapture
        guard let captured else {
            await store.release()
            _ = await first.value
            XCTFail("No capture reached persistence: \(editor.status)")
            return
        }
        XCTAssertFalse(editor.busy, "Recovery saves must leave the editor interactive")
        editor.controller.replaceMarkup(PaperProbeDocument.fixture(), actionName: "Editar mientras se guarda")
        editor.title = "Edición durante el guardado"
        editor.paperBackground = .rose
        let secondStarted = expectation(description: "Explicit Save joins active persistence")
        let second = Task { @MainActor in
            secondStarted.fulfill()
            return await editor.save()
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        first.cancel()
        // A cancelled waiter must return even while the shared write is gated.
        await fulfillment(of: [firstFinished], timeout: 2)
        XCTAssertFalse(editor.busy, "Waiting for persistence must not interrupt editing")
        await store.release()
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        let secondResult = await second.value
        let saved = try XCTUnwrap(secondResult, editor.status)
        XCTAssertFalse(editor.busy)
        XCTAssertGreaterThan(saved.document.revision, captured.document.revision)
        XCTAssertEqual(try PaperProbeDocument.decode(captured.source.data, editorVersion: 2).background, .cream)
        XCTAssertEqual(try PaperProbeDocument.decode(saved.source.data, editorVersion: 2).background, .rose)
        for kind in RenderKind.allCases {
            try assertPaperPixels(saved.image(for: kind)?.pngData, background: .rose)
        }
        let summaries = try await catalog.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.title, "Edición durante el guardado")
        let persisted = try await catalog.load(id: saved.document.id)
        XCTAssertEqual(persisted, saved)
        let newest = try PaperProbeDocument.decode(saved.source.data, editorVersion: saved.document.minimumEditorVersion)
        let newestText = await newest.markup.indexableContent
        XCTAssertTrue(newestText?.contains("Un recuerdo inventado") == true,
                      "Edits made while autosave is suspended at disk must survive in the next capture")
        try captured.validateIntegrity()
        try saved.validateIntegrity()
        editor.suspendAutosave()
    }

    @MainActor
    func testLegacyNativeDraftReopensOnWhiteAndMigratesOnlyWhenEdited() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let markup = PaperProbeDocument.fixture()
        let nativeBytes = try await markup.dataRepresentation()
        let png = try await PaperProbeDocument.render(markup, side: 384)
        let legacy = try DraftArchive.make(revision: 1, nativeData: nativeBytes,
                                           finalPNG: png, widgetPNG: png, thumbnailPNG: png)
        XCTAssertEqual(legacy.document.minimumEditorVersion, 1)
        let summary = try await store.save(legacy, title: "Antes del color")
        let editor = NativePaperSession(store: store, draft: summary)
        editor.controller.loadViewIfNeeded()
        await editor.load()
        XCTAssertFalse(editor.readOnly)
        XCTAssertEqual(editor.paperBackground, .white)
        await Task.yield()
        await Task.yield()
        let unmodified = await editor.save()
        XCTAssertEqual(unmodified, legacy, "Opening a legacy draft must not rewrite its source")
        editor.paperBackground = .sky
        let saved = await editor.save()
        let migrated = try XCTUnwrap(saved)
        XCTAssertEqual(migrated.document.minimumEditorVersion, 3)
        let restored = try PaperProbeDocument.decode(migrated.source.data, editorVersion: 2)
        XCTAssertEqual(restored.background, .sky)
        let text = await restored.markup.indexableContent
        XCTAssertTrue(text?.contains("Un recuerdo inventado") == true)
        XCTAssertEqual(legacy.source.data, nativeBytes)
    }

    @MainActor
    func testUnknownPaperEnvelopeAndInvalidColorAreRejectedInsteadOfLosingData() async throws {
        let source = try await PaperProbeDocument.encode(PaperProbeDocument.fixture(), background: .white)
        XCTAssertThrowsError(try PaperProbeDocument.decode(source, editorVersion: 99))
        let value = try PropertyListSerialization.propertyList(from: source, format: nil)
        let envelope = try XCTUnwrap(value as? [String: Any])
        let mutations: [([String: Any]) -> [String: Any]] = [
            { original in var changed = original; changed["version"] = 99; return changed },
            { original in var changed = original; changed["background"] = ["red": 300, "green": 0, "blue": 0]; return changed },
            { original in var changed = original; changed["nativeData"] = Data(); return changed }
        ]
        for mutation in mutations {
            let invalid = try PropertyListSerialization.data(fromPropertyList: mutation(envelope),
                                                             format: .binary, options: 0)
            XCTAssertThrowsError(try PaperProbeDocument.decode(invalid, editorVersion: 2))
        }
    }

    @MainActor
    func testLayerOrderSurvivesSaveAndReopenWithAllLayersEditable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let editor = NativePaperSession(store: store, draft: nil)
        await editor.load()
        editor.controller.loadViewIfNeeded()
        func layer(_ name: String, _ color: UIColor) throws -> PaperLayer {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            var markup = PaperMarkup(bounds: PaperProbeDocument.bounds)
            markup.insertNewImage(try XCTUnwrap(image.cgImage), frame: PaperProbeDocument.bounds)
            return PaperLayer(name: name, markup: markup)
        }
        let red = try layer("Rojo", .red), blue = try layer("Azul", .blue)
        // Imported images pass through PaperKit's image/color pipeline. Compare
        // against the same layer rendered alone, not exact opaque-paper RGB bytes.
        let redReference = try await PaperProbeDocument.render(red.markup, side: 64)
        let blueReference = try await PaperProbeDocument.render(blue.markup, side: 64)
        XCTAssertNotEqual(redReference, blueReference)
        editor.controller.restoreLayers([red, blue])
        editor.changed()
        let first = try await PaperProbeDocument.render(editor.controller.composedMarkup(), side: 64)
        try assertLayerPixels(first, matching: blueReference)
        editor.controller.moveLayer(red.id, by: 1)
        let reordered = try await PaperProbeDocument.render(editor.controller.composedMarkup(), side: 64)
        try assertLayerPixels(reordered, matching: redReference)
        let saved = await editor.save()
        let archive = try XCTUnwrap(saved)
        let restored = try PaperProbeDocument.decode(archive.source.data, editorVersion: archive.document.minimumEditorVersion)
        XCTAssertEqual(restored.layers?.map(\.id), [blue.id, red.id])
        XCTAssertEqual(restored.layers?.map(\.name), ["Azul", "Rojo"])
        let summaries = try await store.list()
        let reopened = NativePaperSession(store: store, draft: try XCTUnwrap(summaries.first))
        await reopened.load()
        XCTAssertEqual(reopened.controller.capturedLayers().map(\.id), [blue.id, red.id])
        reopened.controller.selectLayer(blue.id)
        XCTAssertEqual(reopened.controller.activeLayerID, blue.id)
        reopened.controller.removeLayer(red.id)
        let remaining = try await PaperProbeDocument.render(reopened.controller.composedMarkup(), side: 64)
        try assertLayerPixels(remaining, matching: blueReference)
    }

    @MainActor
    func testPickerAndCanvasUseLiteralColorsForEverySheetInDarkAppearance() {
        let controller = PaperProbeController()
        controller.overrideUserInterfaceStyle = .dark
        controller.loadViewIfNeeded()
        for background in [PaperBackground.white, .cream, .rose, .sky, .mint, .charcoal] {
            controller.paperBackground = background
            XCTAssertEqual(controller.canvas.overrideUserInterfaceStyle, .light)
            XCTAssertEqual(controller.canvas.pencilKitResponderState.activeToolPicker?.colorUserInterfaceStyle, .light)
            XCTAssertEqual(controller.canvas.pencilKitResponderState.activeToolPicker?.overrideUserInterfaceStyle, .light)
        }
    }

    @MainActor
    func testCanvasReceivesTouchesAndRecoversInputAfterToolsAndTemporaryBlocking() async throws {
        let controller = PaperProbeController()
        XCTAssertEqual(controller.canvas.directTouchMode, .drawing,
                       "A new session must accept finger drawing before loading its view")
        controller.selectionMode = true
        XCTAssertEqual(controller.canvas.directTouchMode, .selection)
        controller.selectionMode = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        controller.view.layoutIfNeeded()
        controller.resumeCanvasInput()

        XCTAssertTrue(controller.canvas.isEditable)
        XCTAssertEqual(controller.canvas.directTouchMode, .drawing)
        XCTAssertFalse(controller.canvas.directTouchAutomaticallyDraws)
        XCTAssertTrue(controller.canvas.isFirstResponder)
        XCTAssertNotNil(controller.canvas.pencilKitResponderState.activeToolPicker)
        XCTAssertNil(controller.pencilKitResponderState.activeToolPicker,
                     "The container must not compete with its input canvas for palette ownership")
        for fraction: CGFloat in [0.25, 0.5, 0.75] {
            let point = CGPoint(x: controller.view.bounds.width * fraction, y: controller.view.bounds.height * 0.5)
            let target = try XCTUnwrap(controller.view.hitTest(point, with: nil))
            XCTAssertTrue(target === controller.canvas.view || target.isDescendant(of: controller.canvas.view),
                          "Read-only layer previews and guides must never intercept an editable canvas touch. " +
                          "Point: \(point); target: \(target); canvas: \(String(describing: controller.canvas.view)); " +
                          "canvas interaction: \(controller.canvas.view.isUserInteractionEnabled)")
        }

        controller.setPaletteVisible(false)
        controller.canvas.resignFirstResponder()
        controller.setPaletteVisible(true) // Cancelling a picker/crop/tool.
        controller.resumeCanvasInput() // Dismiss completion or scene activation.
        XCTAssertTrue(controller.canvas.isFirstResponder)
        XCTAssertTrue(controller.isPaletteRequestedVisible)
        controller.setEditingEnabled(false)
        XCTAssertFalse(controller.canvas.isEditable)
        XCTAssertNil(controller.view.hitTest(CGPoint(x: controller.view.bounds.midX, y: controller.view.bounds.midY), with: nil))
        controller.setEditingEnabled(true)
        XCTAssertTrue(controller.canvas.isEditable)
        XCTAssertTrue(controller.canvas.isFirstResponder)
        XCTAssertEqual(controller.canvas.directTouchMode, .drawing)

        controller.selectionMode = true
        controller.setPaletteVisible(false)
        controller.setEditingEnabled(false)
        controller.setEditingEnabled(true)
        XCTAssertEqual(controller.canvas.directTouchMode, .selection)
        XCTAssertFalse(controller.isPaletteRequestedVisible, "Recovery must preserve explicit selection mode")
        controller.selectionMode = false
        controller.setPaletteVisible(true)
        XCTAssertEqual(controller.canvas.directTouchMode, .drawing)
        XCTAssertTrue(controller.canvas.drawingTool is PKInkingTool)

        let field = UITextField(frame: CGRect(x: 20, y: 20, width: 180, height: 44))
        controller.view.addSubview(field)
        XCTAssertTrue(field.becomeFirstResponder())
        controller.setEditingEnabled(true) // SwiftUI status/preview refresh.
        XCTAssertTrue(field.isFirstResponder, "An unchanged enabled value must not interrupt native text editing")
    }

    @MainActor
    func testLayoutFitsPaperWhenTheWholeDocumentIsAlreadyVisible() throws {
        let controller = PaperProbeController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let bounds = PaperProbeDocument.bounds
        controller.canvas.contentVisibleFrame = bounds.insetBy(dx: -bounds.width, dy: -bounds.height)
        let zoomedOut = controller.canvas.contentVisibleFrame
        XCTAssertGreaterThan(zoomedOut.width, bounds.width * 2)

        // A new layout must fit the sheet even when it was already visible at
        // a smaller scale. Merely ensuring visibility leaves it zoomed out.
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 420)
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let fitted = controller.canvas.contentVisibleFrame
        XCTAssertLessThan(fitted.width, zoomedOut.width * 0.6)
        XCTAssertLessThan(fitted.height, zoomedOut.height * 0.6)
        XCTAssertTrue(fitted.insetBy(dx: -2, dy: -2).contains(bounds),
                      "Fitting must preserve the whole sheet while respecting the viewport's aspect ratio")
    }

    @MainActor
    func testPhotoFileImportDownsamplesAndPersistsVisiblePhotoWithoutLeavingDrawingBlocked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 1200, y: 0, width: 1200, height: 1200))
        }
        let file = directory.appendingPathComponent("photo.png")
        try XCTUnwrap(source.pngData()).write(to: file)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        let editor = NativePaperSession(store: DraftCatalogStore(directory: directory.appendingPathComponent("drafts"), account: .guest), draft: nil)
        await editor.load()
        let imported = await editor.loadPhoto(provider)
        let photo = try XCTUnwrap(imported)
        XCTAssertEqual(photo.cgImage?.width, 1536)
        XCTAssertEqual(photo.cgImage?.height, 768)
        XCTAssertEqual(photo.imageOrientation, .up)
        XCTAssertFalse(editor.busy, "Both successful and failed imports must release the editing lock")
        XCTAssertFalse(editor.hasChanges, "Picking and cropping alone must not mutate a draft")
        let blank = try await PaperProbeDocument.render(editor.controller.composedMarkup(), side: 384)
        XCTAssertTrue(editor.insertPhoto(photo))
        XCTAssertTrue(editor.selecting)
        editor.selecting = false
        XCTAssertEqual(editor.controller.canvas.directTouchMode, .drawing)
        let saved = await editor.save()
        let archive = try XCTUnwrap(saved)
        let restored = try PaperProbeDocument.decode(archive.source.data, editorVersion: archive.document.minimumEditorVersion)
        let result = try await PaperProbeDocument.render(restored.markup, side: 384)
        XCTAssertNotEqual(try rgbaPixels(result), try rgbaPixels(blank), "Imported photo pixels must survive persistence")
        XCTAssertEqual(restored.layers?.count, 2)

        let failure = await editor.loadPhoto(NSItemProvider())
        XCTAssertNil(failure)
        XCTAssertFalse(editor.busy)
        XCTAssertFalse(editor.readOnly)
        XCTAssertEqual(editor.controller.canvas.directTouchMode, .drawing)
    }

    @MainActor
    func testPhotoDecoderAppliesEXIFOrientationAndRejectsInvalidData() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            UIColor.blue.setFill(); context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(source.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let corrected = try PaperPhotoImport.decode(data as Data)
        XCTAssertEqual(corrected.cgImage?.width, 80)
        XCTAssertEqual(corrected.cgImage?.height, 120)
        XCTAssertEqual(corrected.imageOrientation, .up)
        let top = try XCTUnwrap(PaperPixelSampler.color(try XCTUnwrap(corrected.cgImage), at: CGPoint(x: 0.5, y: 0.25)))
        var red: CGFloat = 0, blue: CGFloat = 0, green: CGFloat = 0, alpha: CGFloat = 0
        top.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertGreaterThan(red, 0.9)
        XCTAssertLessThan(blue, 0.1)
        XCTAssertThrowsError(try PaperPhotoImport.decode(Data("invalid photo".utf8)))
        XCTAssertThrowsError(try PaperPhotoImport.decode(Data()))
        let scaled = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 2, orientation: .right)
        let normalized = PhotoCropGeometry.normalized(scaled)
        XCTAssertEqual(normalized.cgImage?.width, 80, "Normalization must preserve the original pixel resolution")
        XCTAssertEqual(normalized.cgImage?.height, 120)
    }

    @MainActor
    func testCancellingSlowPhotoImportReleasesEditorWithoutWaitingForProviderCallback() async throws {
        let started = expectation(description: "Photo provider begins downloading")
        let returned = expectation(description: "Cancelled import releases its waiter")
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { _ in
            started.fulfill()
            // Deliberately never call the provider completion: cancellation
            // must release the editor even with an unresponsive cloud asset.
            return Progress(totalUnitCount: 1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = NativePaperSession(store: DraftCatalogStore(directory: directory, account: .guest), draft: nil)
        await editor.load()
        let task = Task { @MainActor in
            let image = await editor.loadPhoto(provider)
            returned.fulfill()
            return image
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(editor.busy)
        task.cancel()
        await fulfillment(of: [returned], timeout: 2)
        let image = await task.value
        XCTAssertNil(image)
        XCTAssertFalse(editor.busy)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertEqual(editor.controller.canvas.directTouchMode, .drawing)
    }

    @MainActor
    func testCancellingPhotoImportPreservesExplicitSelectionBeforeLoadingTheCanvasView() async throws {
        let started = expectation(description: "Photo download starts while selecting")
        let returned = expectation(description: "Cancelled selection import releases its waiter")
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { _ in
            started.fulfill()
            return Progress(totalUnitCount: 1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = NativePaperSession(store: DraftCatalogStore(directory: directory, account: .guest), draft: nil)
        await editor.load()
        editor.selecting = true
        XCTAssertFalse(editor.controller.isViewLoaded)
        XCTAssertEqual(editor.controller.canvas.directTouchMode, .selection)
        let task = Task { @MainActor in
            let image = await editor.loadPhoto(provider)
            returned.fulfill()
            return image
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await fulfillment(of: [returned], timeout: 2)
        let image = await task.value

        XCTAssertNil(image)
        XCTAssertFalse(editor.busy)
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(editor.selecting)
        XCTAssertEqual(editor.controller.canvas.directTouchMode, .selection,
                       "Cancelling a photo must retain a person's explicitly chosen input mode")
    }

    @MainActor
    func testLetterComposerLayoutInLightAndDarkAppearance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let host = UIHostingController(rootView: LetterComposer(services: AppServices(), notes: []))
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = appearance
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn)
            let attachment = XCTAttachment(image: image)
            attachment.name = appearance == .dark ? "letter-composer-dark" : "letter-composer-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// These capture the hosting window's navigation and paper layout, not any
    /// floating tool-picker windows. Device interaction is checked separately.
    @MainActor
    func testEditorLayoutInLightAndDarkAppearance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let editor = NativePaperEditorView(store: store, draft: nil, onSaved: {}, onSend: { _ in false })
            let host = UIHostingController(rootView: editor)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = appearance
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                previousKeyWindow?.makeKeyAndVisible()
            }
            // Allow SwiftUI's task and the native tool picker presentation to
            // settle in the simulator before capturing the visible hierarchy.
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            var drawn = false
            let image = renderer.image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drawn)
            let attachment = XCTAttachment(image: image)
            attachment.name = appearance == .dark ? "editor-dark" : "editor-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testDiscardRestoresOriginalDraftAfterAutosaveUsingANewerRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let initialEditor = NativePaperSession(store: store, draft: nil)
        await initialEditor.load()
        initialEditor.title = "Título original"
        initialEditor.paperBackground = .cream
        initialEditor.controller.replaceMarkup(PaperProbeDocument.fixture(), actionName: "Contenido inicial")
        let initialCapture = await initialEditor.save()
        let original = try XCTUnwrap(initialCapture)
        initialEditor.commit(original)
        initialEditor.suspendAutosave()
        let originalSummaries = try await store.list()
        let editor = NativePaperSession(store: store, draft: try XCTUnwrap(originalSummaries.first))
        await editor.load()
        editor.title = "Cambio que se descarta"
        editor.paperBackground = .rose
        let autosave = await editor.save()
        let publicationCapture = try XCTUnwrap(autosave)
        XCTAssertTrue(editor.hasChanges, "Autosave is recovery, not an explicit acceptance of edits")
        let discarded = await editor.discardChanges()
        XCTAssertTrue(discarded)
        let restored = try await store.load(id: original.document.id)
        let archive = try XCTUnwrap(restored)
        XCTAssertGreaterThan(archive.document.revision, publicationCapture.document.revision)
        XCTAssertEqual(archive.source.data, original.source.data)
        XCTAssertEqual(archive.document.revisionHash, original.document.revisionHash)
        for kind in RenderKind.allCases {
            XCTAssertEqual(archive.image(for: kind)?.pngData, original.image(for: kind)?.pngData)
        }
        let summaries = try await store.list()
        XCTAssertEqual(summaries.first?.title, "Título original")
        try publicationCapture.validateIntegrity()
        XCTAssertNotEqual(publicationCapture.document.revisionHash, archive.document.revisionHash,
                          "Discard cannot mutate an already captured publication")
        editor.changed()
        let savedAfterDiscard = await editor.save()
        XCTAssertNil(savedAfterDiscard, "A late native callback cannot autosave a discarded session")
    }

    @MainActor
    func testDiscardRemovesOnlyNewDraftAndExplicitCommitAdvancesItsBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftCatalogStore(directory: directory, account: .guest)
        let editor = NativePaperSession(store: store, draft: nil)
        await editor.load()
        editor.title = "Recuperación temporal"
        let autosaved = await editor.save()
        let temporary = try XCTUnwrap(autosaved)
        let firstDiscard = await editor.discardChanges()
        XCTAssertTrue(firstDiscard)
        let missing = try await store.load(id: temporary.document.id)
        XCTAssertNil(missing)

        let acceptedEditor = NativePaperSession(store: store, draft: nil)
        await acceptedEditor.load()
        acceptedEditor.title = "Guardado explícito"
        let acceptedSave = await acceptedEditor.save()
        let accepted = try XCTUnwrap(acceptedSave)
        acceptedEditor.commit(accepted)
        XCTAssertFalse(acceptedEditor.hasChanges)
        acceptedEditor.title = "Cambio posterior"
        acceptedEditor.paperBackground = .sky
        _ = await acceptedEditor.save()
        let secondDiscard = await acceptedEditor.discardChanges()
        XCTAssertTrue(secondDiscard)
        let restored = try await store.load(id: accepted.document.id)
        XCTAssertEqual(restored?.source.data, accepted.source.data)
        let summaries = try await store.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.title, "Guardado explícito")
    }

    @MainActor
    func testPhotoCropPreservesChosenPixelsAndRotationAndClampsGestures() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        }
        let left = try XCTUnwrap(PhotoCropGeometry.cropped(source, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertEqual(left.cgImage?.width, 60)
        XCTAssertEqual(left.cgImage?.height, 80)
        try assertPaperPixels(left.pngData(), background: PaperBackground(red: 255, green: 0, blue: 0))
        let rotated = PhotoCropGeometry.rotated(source)
        XCTAssertEqual(rotated.cgImage?.width, 80)
        XCTAssertEqual(rotated.cgImage?.height, 120)
        let top = try XCTUnwrap(PhotoCropGeometry.cropped(rotated, rect: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        try assertPaperPixels(top.pngData(), background: PaperBackground(red: 255, green: 0, blue: 0))
        XCTAssertNil(PhotoCropGeometry.cropped(source, rect: CGRect(x: 2, y: 2, width: 0.5, height: 0.5)))
        let rect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let moved = PhotoCropGeometry.moved(rect, by: CGSize(width: 10, height: -10))
        XCTAssertEqual(moved, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let resized = PhotoCropGeometry.resized(rect, by: CGSize(width: -10, height: -10), topLeft: false)
        XCTAssertEqual(resized.width, 0.08, accuracy: 0.001)
        XCTAssertEqual(resized.height, 0.08, accuracy: 0.001)
        let square = PhotoCropGeometry.square(for: source.size)
        XCTAssertEqual(square.width * source.size.width, square.height * source.size.height, accuracy: 0.001)
    }

    @MainActor
    func testPhotoInsertionCanUndoAndRedoThroughPaperKitHistory() async throws {
        let controller = PaperProbeController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
        controller.loadViewIfNeeded()
        let original = try XCTUnwrap(controller.canvas.markup)
        let blankRender = try await PaperProbeDocument.render(original, side: 384)
        let blankPixels = try rgbaPixels(blankRender)
        let manager = try XCTUnwrap(controller.canvas.undoManager)
        manager.removeAllActions()
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        var fixture = original
        fixture.insertNewImage(try XCTUnwrap(photo.cgImage), frame: CGRect(x: 100, y: 100, width: 300, height: 300))
        controller.replaceMarkup(fixture, actionName: "Agregar foto")
        let inserted = try XCTUnwrap(controller.canvas.markup)
        let insertedRender = try await PaperProbeDocument.render(inserted, side: 384)
        let insertedPixels = try rgbaPixels(insertedRender)
        XCTAssertNotEqual(insertedPixels, blankPixels, "The photo must actually appear before testing its history")
        XCTAssertTrue(manager.canUndo)
        controller.undo()
        let undone = try XCTUnwrap(controller.canvas.markup)
        let undoneRender = try await PaperProbeDocument.render(undone, side: 384)
        // The undo contract is the complete visible result; internal Coherence
        // model equality is not sufficient evidence of restored photo content.
        XCTAssertEqual(try rgbaPixels(undoneRender), blankPixels, "Undo must remove every photo pixel")
        XCTAssertTrue(manager.canRedo)
        controller.redo()
        let redone = try XCTUnwrap(controller.canvas.markup)
        let redoneRender = try await PaperProbeDocument.render(redone, side: 384)
        XCTAssertEqual(try rgbaPixels(redoneRender), insertedPixels, "Redo must restore the same photo pixels")
    }

    @MainActor
    private func rgbaPixels(_ png: Data) throws -> Data {
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                                  CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    @MainActor
    private func assertLayerPixels(_ png: Data, matching reference: Data,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(UIImage(data: png)?.cgImage, file: file, line: line)
        let expected = try XCTUnwrap(UIImage(data: reference)?.cgImage, file: file, line: line)
        // Sample the interior so native image-edge interpolation is not mistaken
        // for the visible stacking order. Paper opacity/color has separate tests.
        for x: CGFloat in [0.2, 0.5, 0.8] {
            for y: CGFloat in [0.2, 0.5, 0.8] {
                let point = CGPoint(x: x, y: y)
                let color = try XCTUnwrap(PaperPixelSampler.color(actual, at: point), file: file, line: line)
                let referenceColor = try XCTUnwrap(PaperPixelSampler.color(expected, at: point), file: file, line: line)
                XCTAssertEqual(color, referenceColor, file: file, line: line)
            }
        }
    }

    private func assertPaperPixels(_ png: Data?, background: PaperBackground,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try XCTUnwrap(png, file: file, line: line)
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage, file: file, line: line)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                                  CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThanOrEqual(abs(Int(pixels[0]) - Int(background.red)), 1, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(pixels[1]) - Int(background.green)), 1, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(pixels[2]) - Int(background.blue)), 1, file: file, line: line)
        XCTAssertTrue(stride(from: 3, to: image.width * image.height * 4, by: 4).allSatisfy { pixels[$0] == 255 },
                      "Paper and every exported pixel must stay opaque", file: file, line: line)
    }
}

/// Gates only the first catalog write. Real source encoding, rendering, archive
/// validation and disk persistence remain in the regression test.
private actor PausingNativeDraftStore: NativePaperDraftStore {
    let catalog: DraftCatalogStore
    let onFirstCapture: @Sendable () -> Void
    private(set) var firstCapture: DraftArchive?
    private var pause: CheckedContinuation<Void, Never>?
    private var released = false

    init(catalog: DraftCatalogStore, onFirstCapture: @escaping @Sendable () -> Void) {
        self.catalog = catalog
        self.onFirstCapture = onFirstCapture
    }

    func load(id: UUID) async throws -> DraftArchive? { try await catalog.load(id: id) }
    func remove(id: UUID) async throws { try await catalog.remove(id: id) }

    func save(_ archive: DraftArchive, title: String, at date: Date) async throws -> DraftSummary {
        if firstCapture == nil {
            firstCapture = archive
            onFirstCapture()
            if !released { await withCheckedContinuation { pause = $0 } }
        }
        return try await catalog.save(archive, title: title, at: date)
    }

    func release() {
        released = true
        pause?.resume()
        pause = nil
    }
}
