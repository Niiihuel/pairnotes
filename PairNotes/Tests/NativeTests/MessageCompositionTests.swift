import Foundation
import AVFoundation
import PairNotesCore
import SwiftUI
import UIKit
import XCTest
@testable import PairNotes

final class MessageCompositionTests: XCTestCase {
    @MainActor
    func testOpeningPopoverRegistersSynchronouslyAndReleasesAnUnpresentedRequest() throws {
        let events = OpeningPresentationEvents()
        let tracker = MessageOpeningPresentation()
        let control = CoupleModalControl(onPresented: { events.open.insert($0) }, onDismissed: { events.open.remove($0) })
        let owner = try XCTUnwrap(tracker.begin(control))
        XCTAssertEqual(events.open, [owner], "A notification in the same tick must see this owner")
        XCTAssertNil(tracker.begin(control), "Do not reopen while the previous popover is closing")
        tracker.requestedDismissal()
        XCTAssertTrue(events.open.isEmpty, "A request cancelled before mounting must not leak an owner")
        let second = try XCTUnwrap(tracker.begin(control))
        tracker.didClose(owner)
        XCTAssertEqual(events.open, [second], "An old callback must not release a newer presentation")
        tracker.requestedDismissal()
        XCTAssertTrue(events.open.isEmpty)
    }

    @MainActor
    func testOpeningPopoverOwnerWaitsForNativeChildDisappearance() async throws {
        let events = OpeningPresentationEvents()
        let tracker = MessageOpeningPresentation()
        let owner = try XCTUnwrap(tracker.begin(CoupleModalControl(
            onPresented: { events.open.insert($0) }, onDismissed: { events.open.remove($0) })))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let root = UIViewController(), modal = UIViewController()
        let observer = MessageOpeningLifecycleController(ownerID: owner, presentation: tracker)
        tracker.didMount(owner)
        modal.addChild(observer)
        modal.view.addSubview(observer.view)
        observer.view.frame = modal.view.bounds
        observer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        observer.didMove(toParent: modal)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds; window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let appeared = expectation(description: "native popover observer appeared")
        root.present(modal, animated: false) { appeared.fulfill() }
        await fulfillment(of: [appeared], timeout: 3)
        XCTAssertNotNil(observer.view.window)
        tracker.requestedDismissal()
        XCTAssertEqual(events.open, [owner], "A binding change alone is not a completed UIKit dismissal")
        let disappeared = expectation(description: "native popover observer disappeared")
        root.dismiss(animated: false) { disappeared.fulfill() }
        await fulfillment(of: [disappeared], timeout: 3)
        XCTAssertTrue(events.open.isEmpty)
        XCTAssertNil(tracker.ownerID)
    }

    @MainActor
    func testAudioComposerFitsPhoneAndLargeTextWithoutRecordingOrSending() async throws {
        let services = AppServices()
        guard services.identity == nil else { throw XCTSkip("Use a clean simulator for this unauthenticated layout fixture") }
        let storage = MemoryCompositionStorage(key: services.privateImageKey("chat-audio-composition"))
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryCompositions")
        let base = ContentDigest.sha256(Data(storage.key.utf8))
        let files = ["json", "wav", "jpg", "png"].map { directory.appendingPathComponent(base + "." + $0) }
        let original = files.map { try? Data(contentsOf: $0) }
        defer {
            for (url, data) in zip(files, original) {
                if let data { try? data.write(to: url, options: .atomic) }
                else { try? FileManager.default.removeItem(at: url) }
            }
        }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        for index in 0..<16000 { buffer.int16ChannelData![0][index] = Int16(sin(Double(index) / 20) * 8000) }
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
        let bytes = try Data(contentsOf: wav)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        for width: CGFloat in [320, 393] {
            for largeText in [false, true] {
                for hasAudio in [false, true] {
                    storage.clear()
                    try storage.saveValue(AudioMessageDraft())
                    if hasAudio { try storage.saveAudio(bytes) }
                    let name = "chat-audio-\(Int(width))-\(largeText ? "accessibility3" : "body")-\(hasAudio ? "review" : "empty")"
                    let ready = expectation(description: name)
                    let layout = AudioComposerLayout(ready)
                    let composer = AudioMessageComposer(services: services,
                        onSent: { _ in XCTFail("Rendering must not send audio") },
                        onCancel: { XCTFail("Rendering must not dismiss audio") })
                    let content = VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        composer.padding(12).onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                            Task { @MainActor in layout.record(size) }
                        }
                    }.dynamicTypeSize(largeText ? .accessibility3 : .large)
                        .tint(services.personalization.theme.accent).background(services.personalization.theme.canvas)
                        .frame(width: width, height: 800)
                        .ignoresSafeArea()
                    let host = UIHostingController(rootView: AnyView(content))
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
                    window.overrideUserInterfaceStyle = width == 320 ? .light : .dark
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    host.view.frame = window.bounds
                    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    window.setNeedsLayout()
                    window.layoutIfNeeded()
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    // Commit the mounted SwiftUI tree before awaiting its size.
                    // The previous final screenshot rendered it only after the timeout.
                    _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    await fulfillment(of: [ready], timeout: 3)
                    XCTAssertEqual(layout.size.width, width, accuracy: 0.5, name)
                    XCTAssertTrue(layout.size.height.isFinite)
                    XCTAssertGreaterThan(layout.size.height, 100, name)
                    XCTAssertLessThanOrEqual(layout.size.height, 800, name)
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    host.rootView = AnyView(EmptyView()); host.view.layoutIfNeeded(); await Task.yield()
                    window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                }
            }
        }
    }

    func testLegacyLettersKeepTheirScheduledOpeningAndNewLettersCanBeImmediate() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let original = LetterComposition(id: UUID().uuidString, title: "Para después", body: "Un recuerdo",
            opensAt: date, noteID: "")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "scheduled")
        let restored = try JSONDecoder().decode(LetterComposition.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNotEqual(restored.scheduled, false, "An existing draft must not become an immediate message")
        XCTAssertEqual(restored.opensAt, date)
        var immediate = restored
        immediate.scheduled = false
        let roundTrip = try JSONDecoder().decode(LetterComposition.self, from: JSONEncoder().encode(immediate))
        XCTAssertEqual(roundTrip.scheduled, false)
    }

    func testChatAudioDraftIsIsolatedAndRetainsPendingSendIdentity() throws {
        let key = "message-test:" + UUID().uuidString
        let storage = MemoryCompositionStorage(key: key + ":chat-audio-composition")
        let letter = MemoryCompositionStorage(key: key + ":letter-composition:voice")
        defer { storage.clear(); letter.clear() }
        try letter.saveValue(LetterComposition(id: "old-letter", title: "Privado", body: "No enviar con el audio",
            opensAt: Date().addingTimeInterval(86400), noteID: "drawing", scheduled: true))
        try letter.saveAudio(Data("old voice fixture".utf8))
        XCTAssertNil(storage.audio())
        let empty: AudioMessageDraft? = storage.loadValue()
        XCTAssertNil(empty)

        var draft = AudioMessageDraft()
        XCTAssertNil(draft.opensAt)
        draft.serverSaved = true; draft.sealAttempted = true
        let audio = Data("new voice fixture".utf8)
        try storage.saveAudio(audio); try storage.saveValue(draft)
        let restored: AudioMessageDraft? = storage.loadValue()
        XCTAssertEqual(restored, draft, "An uncertain seal must retry the same UUID")
        XCTAssertEqual(storage.audio(), audio)
        XCTAssertEqual(letter.audio(), Data("old voice fixture".utf8))
        storage.clear()
        XCTAssertNil(storage.audio())
        XCTAssertNotNil(letter.audio())
    }

    func testMeterHistoryUsesAudioTimeInsteadOfDisplayRefreshCount() {
        for rate in [60, 120] {
            var cadence = VoiceMeterCadence()
            let samples = (0..<rate * 3).filter { cadence.shouldSample(at: Double($0) / Double(rate)) }.count
            XCTAssertEqual(samples, 30, "\(rate) Hz must preserve the same three-second history")
        }
        var cadence = VoiceMeterCadence()
        XCTAssertFalse(cadence.shouldSample(at: .nan))
        XCTAssertFalse(cadence.shouldSample(at: -.infinity))
        XCTAssertTrue(cadence.shouldSample(at: 1))
        XCTAssertFalse(cadence.shouldSample(at: 1.01))
        XCTAssertTrue(cadence.shouldSample(at: 5), "Skipped display frames should sample once without inventing history")
        XCTAssertFalse(cadence.shouldSample(at: 5.01))
    }
}

@MainActor
private final class OpeningPresentationEvents {
    var open = Set<UUID>()
}

@MainActor
private final class AudioComposerLayout {
    private let ready: XCTestExpectation
    private var fulfilled = false
    var size = CGSize.zero
    init(_ ready: XCTestExpectation) { self.ready = ready }
    func record(_ value: CGSize) {
        size = value
        if value.width > 0, value.height > 0, !fulfilled { fulfilled = true; ready.fulfill() }
    }
}
