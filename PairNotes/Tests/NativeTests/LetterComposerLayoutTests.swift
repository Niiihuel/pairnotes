import PairNotesCore
import SwiftUI
import UIKit
import XCTest
@testable import PairNotes

final class LetterComposerLayoutTests: XCTestCase {
    /// Uses the real composer and a private, synthetic local draft. Rendering
    /// does not restore a session, present permissions or send a letter.
    @MainActor
    func testTitleBodyAndSendRemainSeparateAtPhoneWidthsAndAccessibilitySizes() async throws {
        let services = AppServices()
        guard services.identity == nil else {
            throw XCTSkip("Use a clean simulator session for the unauthenticated letter fixture")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let storage = MemoryCompositionStorage(key: services.privateImageKey("letter-composition:new"))
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryCompositions")
            .appendingPathComponent(ContentDigest.sha256(Data(storage.key.utf8)))
        let files = ["json", "jpg", "png", "wav"].map { base.appendingPathExtension($0) }
        let originals = files.map { try? Data(contentsOf: $0) }
        defer {
            for (url, data) in zip(files, originals) {
                if let data { try? data.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
            previousWindow?.makeKeyAndVisible()
        }
        storage.clear()
        let draft = LetterComposition(id: UUID().uuidString.lowercased(),
            title: "Un pequeño recuerdo de nuestro día",
            body: "Hoy quería guardar estas palabras para vos.\n\nGracias por acompañarme en los días simples, por las risas y por todo lo que compartimos.",
            opensAt: Date(timeIntervalSince1970: 1_900_000_000), noteID: "", scheduled: false)

        for width: CGFloat in [320, 393] {
            for dark in [false, true] {
                for largeText in [false, true] {
                    try storage.saveValue(draft)
                    let name = "letter-composer-\(Int(width))-\(dark ? "dark" : "light")-\(largeText ? "accessibility3" : "body")"
                    let ready = expectation(description: name + " laid out")
                    let layout = LetterLayoutRecorder(ready: ready)
                    let root = LetterComposer(services: services, notes: [])
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                            Task { @MainActor in layout.record(size) }
                        }
                        .dynamicTypeSize(largeText ? .accessibility3 : .large)
                        .environment(\.coupleAppTheme, services.personalization.theme)
                        .frame(width: width, height: 800)
                    let host = UIHostingController(rootView: AnyView(root))
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
                    window.overrideUserInterfaceStyle = dark ? .dark : .light
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    host.view.frame = window.bounds
                    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    window.setNeedsLayout(); window.layoutIfNeeded()
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true), name)
                    }
                    await fulfillment(of: [ready], timeout: 3)
                    XCTAssertEqual(layout.size.width, width, accuracy: 0.5, name)
                    XCTAssertEqual(layout.size.height, 800, accuracy: 0.5, name)

                    let frames = accessibilityFrames(in: host.view)
                    let viewport = UIAccessibility.convertToScreenCoordinates(window.bounds, in: window)
                    if let close = frames["letter.close"], let send = frames["letter.send"] {
                        for frame in [close, send] {
                            XCTAssertGreaterThanOrEqual(frame.width, 43.5, name)
                            XCTAssertGreaterThanOrEqual(frame.height, 43.5, name)
                            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame), name)
                            XCTAssertLessThan(frame.midY, viewport.midY, "Sending stays in the top toolbar: \(name)")
                        }
                        XCTAssertFalse(close.intersects(send), "Close and send must remain separate: \(name)")
                    }
                    if let title = frames["letter.title"], let body = frames["letter.body"] {
                        XCTAssertGreaterThanOrEqual(title.width, 100, name)
                        XCTAssertGreaterThanOrEqual(body.width, 100, name)
                        XCTAssertLessThanOrEqual(title.maxY, body.minY, "Title and body must not overlap: \(name)")
                        XCTAssertEqual(title.minX, body.minX, accuracy: 0.5, name)
                        XCTAssertEqual(title.width, body.width, accuracy: 0.5, name)
                    }
                    let diagnostics = XCTAttachment(string: (["Mounted composer: \(layout.size)"] +
                        ["letter.close", "letter.send", "letter.title", "letter.body"].map {
                            "\($0): \(frames[$0].map { String(describing: $0) } ?? "not exposed by the native accessibility container")"
                        }).joined(separator: "\n"))
                    diagnostics.name = name + "-geometry"; diagnostics.lifetime = .keepAlways; add(diagnostics)
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true), name)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    host.rootView = AnyView(EmptyView())
                    host.view.layoutIfNeeded()
                    await Task.yield()
                    let restored: LetterComposition = try XCTUnwrap(storage.loadValue())
                    XCTAssertEqual(restored, draft, "Rendering must preserve the private draft and immediate opening: \(name)")
                    window.isHidden = true; window.rootViewController = nil
                }
            }
        }
    }

    @MainActor
    private func accessibilityFrames(in root: UIView) -> [String: CGRect] {
        var frames: [String: CGRect] = [:], visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int = 0) {
            guard depth < 64, visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let identified = object as? UIAccessibilityIdentification,
               let id = identified.accessibilityIdentifier,
               ["letter.close", "letter.send", "letter.title", "letter.body"].contains(id) {
                let frame = object.accessibilityFrame
                if frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
                   frame.width > 0, frame.height > 0 { frames[id] = frame }
            }
            if let view = object as? UIView { for child in view.subviews { visit(child, depth: depth + 1) } }
            if let elements = object.accessibilityElements {
                for case let child as NSObject in elements { visit(child, depth: depth + 1) }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 256 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child, depth: depth + 1) }
                }
            }
        }
        visit(root)
        return frames
    }
}

@MainActor
private final class LetterLayoutRecorder {
    let ready: XCTestExpectation
    var size = CGSize.zero
    private var fulfilled = false
    init(ready: XCTestExpectation) { self.ready = ready }
    func record(_ size: CGSize) {
        self.size = size
        if size.width > 0, size.height > 0, !fulfilled { fulfilled = true; ready.fulfill() }
    }
}
