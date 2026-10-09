import PairNotesCore
import SwiftUI
import UIKit
import XCTest
@testable import PairNotes

final class ReactionBubbleTests: XCTestCase {
    /// The former photo column squeezed five actions below 44 pt. Exercise the
    /// shared component's actual SwiftUI layout at a narrow widget width.
    @MainActor
    func testFiveReactionActionsKeepTheirHitRegionsAtNarrowWidthAndLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let laidOut = expectation(description: "Five reaction controls laid out in \(appearance.rawValue)")
            let frames = ReactionFrameRecorder(ready: laidOut)
            let host = UIHostingController(rootView: ReactionLayoutFixture(recorder: frames)
                .dynamicTypeSize(.accessibility3).ignoresSafeArea())
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 260, height: 80)
            window.overrideUserInterfaceStyle = appearance
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            await fulfillment(of: [laidOut], timeout: 3)
            XCTAssertEqual(frames.values.count, 5)
            let viewport = CGRect(x: 0, y: 0, width: 260, height: 80)
            let values = frames.values.values.sorted { $0.minX < $1.minX }
            for frame in values {
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
                XCTAssertTrue(viewport.contains(frame), "A reaction must stay visible inside the widget width: \(frame)")
            }
            for (left, right) in zip(values, values.dropFirst()) {
                XCTAssertLessThanOrEqual(left.maxX, right.minX, "Reaction targets must not overlap")
            }
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = appearance == .dark ? "reaction-bubble-dark" : "reaction-bubble-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

@MainActor
private final class ReactionFrameRecorder {
    let ready: XCTestExpectation
    var values: [String: CGRect] = [:]
    private var fulfilled = false
    init(ready: XCTestExpectation) { self.ready = ready }
    func record(_ values: [String: CGRect]) {
        self.values = values
        if values.count == 5, !fulfilled { fulfilled = true; ready.fulfill() }
    }
}

private struct ReactionControlFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ReactionLayoutFixture: View {
    let recorder: ReactionFrameRecorder
    var body: some View {
        ReactionBubble(tail: .topLeading) {
            HStack(spacing: 4) {
                ForEach(PhotoReactionKind.allCases, id: \.rawValue) { kind in
                    Button {} label: {
                        ReactionEmojiLabel(symbol: kind.symbol, selected: kind == .heart)
                            .background { geometry(kind.rawValue) }
                    }
                }
                Button {} label: { ReactionCameraLabel().background { geometry("camera") } }
            }.buttonStyle(ReactionBubbleButtonStyle())
        }
        .frame(width: 260, height: 80)
        .background(Color(uiColor: .systemBackground))
        .coordinateSpace(name: "reaction-test")
        .onPreferenceChange(ReactionControlFrames.self) { values in
            Task { @MainActor in recorder.record(values) }
        }
    }
    private func geometry(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ReactionControlFrames.self,
                value: [id: proxy.frame(in: .named("reaction-test"))])
        }
    }
}
