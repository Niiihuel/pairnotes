import XCTest
import UIKit

/// Runs out of process and sends real finger gestures to the launched app.
/// Native model/render tests cannot establish that UIKit receives these touches.
final class EditorInteractionTests: XCTestCase {
    @MainActor
    func testGuestNavigationSeparatesCollectionsFromDrawingAndAccountSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_AR"]
        app.launch()
        let tabs = app.tabBars
        for title in ["Inicio", "Dibujos", "Recuerdos", "Para vos", "Nosotros"] {
            XCTAssertTrue(tabs.buttons[title].waitForExistence(timeout: 15), "Missing destination: \(title)")
        }
        tabs.buttons["Para vos"].tap()
        XCTAssertTrue(app.navigationBars["Para vos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Vincular"].exists)
        XCTAssertFalse(app.buttons["Nuevo dibujo"].exists)
        tabs.buttons["Dibujos"].tap()
        XCTAssertTrue(app.buttons["Nuevo dibujo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["affection.cartas"].exists)
        tabs.buttons["Recuerdos"].tap()
        XCTAssertTrue(app.navigationBars["Recuerdos"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["affection.cartas"].exists)
        XCTAssertTrue(tabs.buttons["Para vos"].exists, "The tab bar stays visible in each collection")
        tabs.buttons["Nosotros"].tap()
        XCTAssertTrue(app.navigationBars["Nosotros"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Mensajes"].exists)
        attach(app.screenshot(), name: "separated-guest-navigation")
    }

    @MainActor
    func testFingerDrawingSurvivesModesPhotoCancellationAndSaveReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_AR"]
        app.launch()
        let create = app.tabBars.buttons["Dibujos"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        let newDrawing = app.buttons["Nuevo dibujo"]
        XCTAssertTrue(newDrawing.waitForExistence(timeout: 10))
        waitUntilEnabled(newDrawing)
        newDrawing.tap()
        let paper = app.descendants(matching: .any)["editor.paper"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 10))

        let title = "Gesto UI " + String(UUID().uuidString.prefix(8))
        app.buttons["editor.rename"].tap()
        let rename = app.alerts["Renombrar dibujo"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        let field = rename.textFields.firstMatch
        field.tap()
        field.typeText(title)
        rename.buttons["Guardar"].tap()
        app.buttons["editor.background"].tap()
        let white = app.buttons["Blanco"]
        XCTAssertTrue(white.waitForExistence(timeout: 5))
        white.tap()
        app.buttons["Listo"].tap()

        let baseline = paper.screenshot()
        attach(baseline, name: "editor-touch-blank")
        let blankInk = try darkPixelCount(baseline.image)
        // PaperKit leaves workspace around the sheet when its palette is open.
        // Start each finger gesture inside the visible sheet, not that margin.
        draw(on: paper, from: CGVector(dx: 0.35, dy: 0.4), to: CGVector(dx: 0.65, dy: 0.42))
        waitUntilEnabled(app.buttons["editor.undo"])
        waitForInk(on: paper, in: app, above: blankInk + 100)
        let first = paper.screenshot()
        attach(first, name: "editor-touch-first-stroke")
        let firstInk = try darkPixelCount(first.image)

        let mode = app.segmentedControls["editor.selection"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons["Seleccionar"].tap()
        mode.buttons["Dibujar"].tap()
        draw(on: paper, from: CGVector(dx: 0.35, dy: 0.5), to: CGVector(dx: 0.65, dy: 0.52))
        waitForInk(on: paper, in: app, above: firstInk + 100)
        let secondInk = try darkPixelCount(paper.screenshot().image)

        app.buttons["editor.photo"].tap()
        // The loading sheet and loaded PHPicker can expose different cancel
        // labels/identifiers. Ignore unavailable AX placeholders (infinite frames)
        // and editor.cancel beneath the sheet; never ask the placeholder isHittable.
        // Application itself need not have a frame; use the actual main window.
        let window = app.windows.firstMatch
        let cancelVisible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            visiblePickerCancelFrame(in: app, window: window) != nil
        }, object: nil)
        let cancelResult = XCTWaiter.wait(for: [cancelVisible], timeout: 10)
        if cancelResult != .completed {
            attach(app.screenshot(), name: "editor-photo-picker-cancel-timeout")
            let geometry = "Application frame: \(app.frame)\nMain window frame: \(window.frame)\n\n"
            let hierarchy = XCTAttachment(string: geometry + app.debugDescription)
            hierarchy.name = "editor-photo-picker-cancel-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(cancelResult, .completed, "The presented photo picker must have a visible cancel control")
        let cancelFrame = try XCTUnwrap(visiblePickerCancelFrame(in: app, window: window))
        let windowFrame = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: cancelFrame.midX - windowFrame.minX,
                                 dy: cancelFrame.midY - windowFrame.minY)).tap()
        let pickerDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            visiblePickerCancelFrame(in: app, window: window) == nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pickerDismissed], timeout: 10), .completed)
        draw(on: paper, from: CGVector(dx: 0.38, dy: 0.6), to: CGVector(dx: 0.62, dy: 0.62))
        waitForInk(on: paper, in: app, above: secondInk + 100)
        attach(paper.screenshot(), name: "editor-touch-after-cancel-photo")

        app.buttons["editor.done"].tap()
        waitForLibraryAfterClosingEditor(in: app)
        // The editor's title button also contains the draft title. Resolve a
        // library row only after that presentation has actually disappeared.
        let saved = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND identifier != %@", title, "editor.rename")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 20), "A drawn draft must be saved and shown in the library")
        waitUntilHittable(saved)
        saved.tap()
        // Resolve the newly presented editor instead of reusing the first
        // presentation's AX element, which can survive with an empty frame.
        let reopenedPaper = try waitForVisiblePaper(in: app)
        waitForInk(on: reopenedPaper, in: app, above: blankInk + 200)
        attach(reopenedPaper.screenshot(), name: "editor-touch-saved-and-reopened")
        app.buttons["editor.cancel"].tap()
    }

    @MainActor
    private func draw(on paper: XCUIElement, from start: CGVector, to end: CGVector) {
        waitUntilHittable(paper)
        paper.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: paper.coordinate(withNormalizedOffset: end))
    }

    private func visiblePickerCancelFrame(in app: XCUIApplication, window: XCUIElement) -> CGRect? {
        guard window.exists else { return nil }
        let viewport = window.frame
        guard viewport.origin.x.isFinite, viewport.origin.y.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              !viewport.isEmpty else { return nil }
        let names = ["Cancel", "Cancelar", "Close", "Cerrar"]
        let candidates = app.buttons.matching(NSPredicate(
            format: "(identifier IN %@ OR label IN %@) AND identifier != %@",
            argumentArray: [names, names, "editor.cancel"])).allElementsBoundByIndex
        for candidate in candidates {
            guard let frame = visibleFrame(of: candidate, inside: viewport),
                  frame.midX < viewport.minX + viewport.width * 0.25,
                  frame.midY < viewport.minY + viewport.height * 0.25 else { continue }
            return frame
        }
        return nil
    }

    private func visibleFrame(of element: XCUIElement, inside viewport: CGRect) -> CGRect? {
        guard element.exists,
              viewport.origin.x.isFinite, viewport.origin.y.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              !viewport.isEmpty else { return nil }
        let frame = element.frame
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              !frame.isEmpty, viewport.contains(frame) else { return nil }
        return frame
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor
    private func waitForLibraryAfterClosingEditor(in app: XCUIApplication) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            !app.buttons["editor.done"].exists && paperCandidates(in: app).isEmpty
        }, object: nil)
        let result = XCTWaiter.wait(for: [dismissed], timeout: 20)
        if result != .completed { attachPaperDiagnostic(in: app, name: "editor-save-dismissal-timeout") }
        XCTAssertEqual(result, .completed, "The editor must close before the saved draft is reopened")
        let library = app.segmentedControls["library.tabs"]
        XCTAssertTrue(library.waitForExistence(timeout: 10), "The draft library must be visible after saving")
        waitUntilHittable(library)
    }

    @MainActor
    private func waitForVisiblePaper(in app: XCUIApplication) throws -> XCUIElement {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            visiblePaper(in: app) != nil
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 15)
        if result != .completed { attachPaperDiagnostic(in: app, name: "editor-reopen-readiness-timeout") }
        XCTAssertEqual(result, .completed, "The reopened editor must present a visible, interactive paper")
        return try XCTUnwrap(visiblePaper(in: app))
    }

    private func paperCandidates(in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "editor.paper"))
            .allElementsBoundByIndex
    }

    private func visiblePaper(in app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch
        guard window.exists else { return nil }
        for candidate in paperCandidates(in: app) {
            // Ignore any old/hidden paper candidates before asking for pixels.
            // Check real geometry before requesting hittability.
            guard visibleFrame(of: candidate, inside: window.frame) != nil else { continue }
            if candidate.isHittable { return candidate }
        }
        return nil
    }

    @MainActor
    private func waitForInk(on paper: XCUIElement, in app: XCUIApplication, above minimum: Int) {
        let window = app.windows.firstMatch
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard window.exists,
                  visibleFrame(of: paper, inside: window.frame) != nil,
                  paper.isHittable,
                  let count = try? darkPixelCount(paper.screenshot().image) else { return false }
            return count > minimum
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 10)
        if result != .completed { attachPaperDiagnostic(in: app, name: "editor-ink-readiness-timeout") }
        XCTAssertEqual(result, .completed, "A real finger drag must add visible ink to the paper")
    }

    private func attachPaperDiagnostic(in app: XCUIApplication, name: String) {
        attach(app.screenshot(), name: name)
        let window = app.windows.firstMatch
        let frames = paperCandidates(in: app).enumerated().map { index, candidate in
            "paper[\(index)] id=\(candidate.identifier) frame=\(candidate.frame)"
        }.joined(separator: "\n")
        let geometry = "Application frame: \(app.frame)\nMain window frame: \(window.frame)\n\(frames)\n\n"
        let hierarchy = XCTAttachment(string: geometry + app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func darkPixelCount(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0
        // Ignore the paper border, shadows and anything outside the drawing.
        for y in (cg.height / 10)..<(cg.height * 9 / 10) {
            for x in (cg.width / 10)..<(cg.width * 9 / 10) {
                let index = (y * cg.width + x) * 4
                if Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) < 555 { count += 1 }
            }
        }
        return count
    }
}
