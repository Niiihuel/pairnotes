import XCTest
import UIKit

/// Runs out of process and sends real finger gestures to the launched app.
/// Native model/render tests cannot establish that UIKit receives these touches.
final class EditorInteractionTests: XCTestCase {
    @MainActor
    func testFingerDrawingSurvivesModesPhotoCancellationAndSaveReopen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_AR"]
        app.launch()
        let create = app.tabBars.buttons["Crear"]
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
        waitForInk(on: paper, above: blankInk + 100)
        let first = paper.screenshot()
        attach(first, name: "editor-touch-first-stroke")
        let firstInk = try darkPixelCount(first.image)

        let mode = app.segmentedControls["editor.selection"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons["Seleccionar"].tap()
        mode.buttons["Dibujar"].tap()
        draw(on: paper, from: CGVector(dx: 0.35, dy: 0.5), to: CGVector(dx: 0.65, dy: 0.52))
        waitForInk(on: paper, above: firstInk + 100)
        let secondInk = try darkPixelCount(paper.screenshot().image)

        app.buttons["editor.photo"].tap()
        // The loading sheet and loaded PHPicker can expose different cancel
        // labels/identifiers. Ignore unavailable AX placeholders (infinite frames)
        // and editor.cancel beneath the sheet; never ask the placeholder isHittable.
        let cancelVisible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            visiblePickerCancelFrame(in: app) != nil
        }, object: nil)
        let cancelResult = XCTWaiter.wait(for: [cancelVisible], timeout: 10)
        if cancelResult != .completed {
            attach(app.screenshot(), name: "editor-photo-picker-cancel-timeout")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "editor-photo-picker-cancel-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(cancelResult, .completed, "The presented photo picker must have a visible cancel control")
        let cancelFrame = try XCTUnwrap(visiblePickerCancelFrame(in: app))
        let appFrame = app.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: cancelFrame.midX - appFrame.minX,
                                 dy: cancelFrame.midY - appFrame.minY)).tap()
        let pickerDismissed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            visiblePickerCancelFrame(in: app) == nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pickerDismissed], timeout: 10), .completed)
        draw(on: paper, from: CGVector(dx: 0.38, dy: 0.6), to: CGVector(dx: 0.62, dy: 0.62))
        waitForInk(on: paper, above: secondInk + 100)
        attach(paper.screenshot(), name: "editor-touch-after-cancel-photo")

        app.buttons["editor.done"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 20), "A drawn draft must be saved and shown in the library")
        saved.tap()
        XCTAssertTrue(paper.waitForExistence(timeout: 10))
        waitForInk(on: paper, above: blankInk + 200)
        attach(paper.screenshot(), name: "editor-touch-saved-and-reopened")
        app.buttons["editor.cancel"].tap()
    }

    @MainActor
    private func draw(on paper: XCUIElement, from start: CGVector, to end: CGVector) {
        waitUntilHittable(paper)
        paper.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: paper.coordinate(withNormalizedOffset: end))
    }

    private func visiblePickerCancelFrame(in app: XCUIApplication) -> CGRect? {
        let names = ["Cancel", "Cancelar", "Close", "Cerrar"]
        let candidates = app.buttons.matching(NSPredicate(
            format: "(identifier IN %@ OR label IN %@) AND identifier != %@",
            argumentArray: [names, names, "editor.cancel"])).allElementsBoundByIndex
        let window = app.frame
        for candidate in candidates {
            guard let frame = visibleFrame(of: candidate, in: app),
                  frame.midX < window.minX + window.width * 0.25,
                  frame.midY < window.minY + window.height * 0.25 else { continue }
            return frame
        }
        return nil
    }

    private func visibleFrame(of element: XCUIElement, in app: XCUIApplication) -> CGRect? {
        guard element.exists else { return nil }
        let frame = element.frame
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              !frame.isEmpty, app.frame.contains(frame) else { return nil }
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
    private func waitForInk(on paper: XCUIElement, above minimum: Int) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard paper.exists, let count = try? darkPixelCount(paper.screenshot().image) else { return false }
            return count > minimum
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed,
                       "A real finger drag must add visible ink to the paper")
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
