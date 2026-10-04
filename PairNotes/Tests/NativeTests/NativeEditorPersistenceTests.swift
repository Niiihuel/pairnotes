import XCTest
import PaperKit
import PairNotesCore
import UIKit
import SwiftUI
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
        let visiblePaperColor = try XCTUnwrap(editor.controller.canvas.contentView?.backgroundColor)
        XCTAssertEqual(PaperBackground(color: visiblePaperColor), .white)

        let initial = await editor.save()
        let white = try XCTUnwrap(initial)
        try assertPaperPixels(white.image(for: .final)?.pngData, background: .white)
        editor.controller.canvas.markup = PaperProbeDocument.fixture()
        editor.paperBackground = .cream
        editor.changed()
        let saved = await editor.save()
        let colored = try XCTUnwrap(saved)
        try colored.validateIntegrity()
        XCTAssertEqual(colored.document.minimumEditorVersion, 2)
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
        let recolored = try XCTUnwrap(savedAgain)
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
        await editor.load()
        XCTAssertFalse(editor.readOnly)
        XCTAssertEqual(editor.paperBackground, .white)
        let unmodified = await editor.save()
        XCTAssertEqual(unmodified, legacy, "Opening a legacy draft must not rewrite its source")
        editor.paperBackground = .sky
        let saved = await editor.save()
        let migrated = try XCTUnwrap(saved)
        XCTAssertEqual(migrated.document.minimumEditorVersion, 2)
        let restored = try PaperProbeDocument.decode(migrated.source.data, editorVersion: 2)
        XCTAssertEqual(restored.background, .sky)
        let text = await restored.markup.indexableContent
        XCTAssertTrue(text?.contains("Un recuerdo inventado") == true)
        XCTAssertEqual(legacy.source.data, nativeBytes)
    }

    @MainActor
    func testUnknownPaperEnvelopeAndInvalidColorAreRejectedInsteadOfLosingData() async throws {
        let source = try await PaperProbeDocument.encode(PaperProbeDocument.fixture(), background: .white)
        XCTAssertThrowsError(try PaperProbeDocument.decode(source, editorVersion: 3))
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

    /// The screenshots are evidence of navigation and palette layout; document
    /// fidelity is checked independently against actual PaperKit raster output.
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
