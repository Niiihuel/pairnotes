import PairNotesCore
import SwiftUI
import UIKit
import XCTest
@testable import PairNotes

final class ChatComposerLayoutTests: XCTestCase {
    /// Mounts the production composer directly. No account, restored session,
    /// microphone request, send action or networking is needed to render it.
    @MainActor
    func testRealComposerFitsPhoneWidthsWithEmptyTextAndAccessibilityText() async throws {
        let services = AppServices()
        guard services.identity == nil else { throw XCTSkip("Use a clean simulator session for the unauthenticated layout fixture") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let storage = MemoryCompositionStorage(key: services.privateImageKey("message-draft"))
        let savedURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryCompositions")
            .appendingPathComponent(ContentDigest.sha256(Data(storage.key.utf8)) + ".json")
        let original = try? Data(contentsOf: savedURL)
        defer {
            if let original { try? original.write(to: savedURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: savedURL) }
        }
        for width: CGFloat in [320, 393] {
            for largeText in [false, true] {
                for text in ["", "Te quería contar algo lindo de hoy."] {
                    try storage.saveValue(ChatLayoutDraft(text: text))
                    let caseName = "chat-composer-\(Int(width))-\(largeText ? "accessibility3" : "body")-\(text.isEmpty ? "empty" : "text")"
                    let ready = expectation(description: caseName + " laid out")
                    let layout = ChatComposerLayoutRecorder(ready: ready)
                    let action: () -> Void = { XCTFail("Rendering must not invoke an attachment or recording action") }
                    let composer = ChatMessageComposer(services: services, createPhoto: action, takePhoto: action,
                        createDrawing: action, showDrafts: action, createLetter: action, recordAudio: action,
                        onSent: { _ in XCTFail("Rendering must not send a message") })
                    let root = VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        composer.background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: ChatComposerSize.self, value: proxy.size)
                            }
                        }
                    }
                    .background(services.personalization.theme.canvas)
                    .dynamicTypeSize(largeText ? .accessibility3 : .large)
                    .environment(\.coupleAppTheme, services.personalization.theme)
                    .onPreferenceChange(ChatComposerSize.self) { value in
                        Task { @MainActor in layout.record(value) }
                    }
                    .ignoresSafeArea()
                    let host = UIHostingController(rootView: AnyView(root))
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 420)
                    window.overrideUserInterfaceStyle = width == 320 ? .light : .dark
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    host.view.layoutIfNeeded()
                    await fulfillment(of: [ready], timeout: 3)
                    XCTAssertEqual(layout.size.width, width, accuracy: 0.5, caseName)
                    XCTAssertTrue(layout.size.height.isFinite)
                    XCTAssertGreaterThanOrEqual(layout.size.height, 58, caseName)
                    XCTAssertLessThanOrEqual(layout.size.height, 360, caseName)

                    let expected = text.isEmpty ? ["chat.attach", "chat.camera", "chat.record"] :
                        ["chat.attach", "message.opening", "chat.send"]
                    let frames = accessibilityFrames(in: host.view)
                    if expected.allSatisfy({ frames[$0] != nil }), let field = frames["chat.message"] {
                        let viewport = UIAccessibility.convertToScreenCoordinates(window.bounds, in: window)
                        let ordered = expected.compactMap { frames[$0] }.sorted { $0.minX < $1.minX }
                        for frame in ordered {
                            XCTAssertGreaterThanOrEqual(frame.width, 43.5, caseName)
                            XCTAssertGreaterThanOrEqual(frame.height, 43.5, caseName)
                            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame), caseName)
                        }
                        XCTAssertGreaterThanOrEqual(field.width, 70, "The message field must remain usable at \(width) pt")
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(field), caseName)
                        for (left, right) in zip(ordered, ordered.dropFirst()) {
                            XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5, caseName)
                        }
                    }
                    let diagnostics = XCTAttachment(string: (["Composer bounds: \(layout.size)"] +
                        (expected + ["chat.message"]).map { "\($0): \(frames[$0].map { String(describing: $0) } ?? "not exposed by the native accessibility container")" }).joined(separator: "\n"))
                    diagnostics.name = caseName + "-geometry"
                    diagnostics.lifetime = .keepAlways
                    add(diagnostics)
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = caseName
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    // Apply disappearance before the next fixture replaces the
                    // private draft; the composer persists synchronously here.
                    host.rootView = AnyView(EmptyView())
                    host.view.layoutIfNeeded()
                    await Task.yield()
                    window.isHidden = true
                    window.rootViewController = nil
                    previousWindow?.makeKeyAndVisible()
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
               let id = identified.accessibilityIdentifier, ["chat.attach", "chat.camera", "chat.record", "chat.send", "chat.message", "message.opening"].contains(id) {
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

private struct ChatLayoutDraft: Encodable {
    let text: String
    let id = UUID()
    let submittedText: String? = nil
    let opensAt: Date? = nil
    let sealAttempted: Bool? = nil
}

private struct ChatComposerSize: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

@MainActor
private final class ChatComposerLayoutRecorder {
    let ready: XCTestExpectation
    var size = CGSize.zero
    private var fulfilled = false
    init(ready: XCTestExpectation) { self.ready = ready }
    func record(_ size: CGSize) {
        self.size = size
        if size.width > 0, size.height > 0, !fulfilled { fulfilled = true; ready.fulfill() }
    }
}
