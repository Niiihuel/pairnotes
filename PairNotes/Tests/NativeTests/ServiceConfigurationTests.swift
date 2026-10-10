import XCTest
import Foundation
import AVFoundation
import SwiftUI
import UIKit
import PairNotesCore
@testable import PairNotes

final class ServiceConfigurationTests: XCTestCase {
    func testThemeSurvivesRelaunchAndSeparatesAccountsAndServers() throws {
        let suite = "theme-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = CoupleThemePreference(baseURL: "https://a.example", uid: "one", defaults: defaults)
        XCTAssertNil(original.load())
        original.save(.night)
        XCTAssertEqual(CoupleThemePreference(baseURL: "https://a.example", uid: "one", defaults: defaults).load(), .night)
        XCTAssertNil(CoupleThemePreference(baseURL: "https://a.example", uid: "two", defaults: defaults).load())
        XCTAssertNil(CoupleThemePreference(baseURL: "https://b.example", uid: "one", defaults: defaults).load())
        original.clear()
        XCTAssertNil(original.load())
        defaults.set("unknown-future-theme", forKey: original.key)
        XCTAssertNil(original.load())
    }

    @MainActor
    func testEverySharedPaletteHasDarkSurfacesAndReadableInk() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for theme in CoupleTheme.allCases {
            var background: CGFloat = 1, foreground: CGFloat = 0
            let canvas = UIColor(theme.canvas).resolvedColor(with: dark)
            let ink = UIColor(theme.ink).resolvedColor(with: dark)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            canvas.getRed(&r, green: &g, blue: &b, alpha: &a); background = (r + g + b) / 3
            ink.getRed(&r, green: &g, blue: &b, alpha: &a); foreground = (r + g + b) / 3
            XCTAssertLessThan(background, 0.2, theme.rawValue)
            XCTAssertGreaterThan(foreground, 0.8, theme.rawValue)
        }
    }

    @MainActor
    func testVoicePreparationSeekingAndPausePreservePositionWithoutAutoplay() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        for index in 0..<16000 { buffer.int16ChannelData![0][index] = Int16(sin(Double(index) / 20) * Double(index % 1600) * 10) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: url)
        let controller = VoiceNoteController()
        controller.prepare(data)
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.playing)
        XCTAssertFalse(controller.isUpdatingDisplay, "An idle player must not keep a display link running")
        XCTAssertEqual(controller.duration, 1, accuracy: 0.02)
        controller.seek(to: 0.5)
        controller.pause()
        controller.prepare(data)
        XCTAssertEqual(controller.elapsed, 0.5, accuracy: 0.02)
        controller.cancelRecording()
        XCTAssertEqual(controller.elapsed, 0.5, accuracy: 0.02, "Cancelling a new take must preserve the reviewed audio position")
        XCTAssertEqual(controller.duration, 1, accuracy: 0.02)
        XCTAssertFalse(controller.isUpdatingDisplay)
        controller.seek(to: .nan)
        XCTAssertEqual(controller.elapsed, 0.5, accuracy: 0.02)
        controller.seek(to: -1)
        XCTAssertEqual(controller.elapsed, 0)
        controller.stopAll()
        XCTAssertEqual(controller.duration, 0)
        XCTAssertFalse(controller.playing)
        XCTAssertFalse(controller.isUpdatingDisplay)

        // Preparing an offscreen row and releasing its controller must leave
        // the chosen audio playing. Choosing another row switches playback.
        let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        do {
            let file = try AVAudioFile(forWriting: sessionURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            for _ in 0..<8 { try file.write(from: buffer) }
        }
        let sessionData = try Data(contentsOf: sessionURL)
        let idleRow = VoiceNoteController()
        defer { controller.stopAll(); idleRow.stopAll() }
        controller.play(sessionData)
        XCTAssertNil(controller.error)
        XCTAssertTrue(controller.playing)
        XCTAssertTrue(controller.isUpdatingDisplay)
        try await Task.sleep(for: .milliseconds(150))
        let beforeIdlePreparation = controller.elapsed
        idleRow.prepare(sessionData)
        idleRow.stopAll()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.playing)
        XCTAssertGreaterThan(controller.elapsed, beforeIdlePreparation,
            "Preparing or releasing another row must not deactivate the active audio session")
        idleRow.play(sessionData)
        XCTAssertNil(idleRow.error)
        XCTAssertTrue(idleRow.playing)
        XCTAssertFalse(controller.playing, "Only the selected row should play")
        XCTAssertFalse(controller.isUpdatingDisplay, "Switching rows must invalidate the previous display link")
        XCTAssertTrue(idleRow.isUpdatingDisplay)
        idleRow.stopAll()
        XCTAssertFalse(idleRow.isUpdatingDisplay)

        for interruption in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                             UIApplication.didEnterBackgroundNotification] {
            controller.play(sessionData)
            XCTAssertTrue(controller.playing)
            XCTAssertTrue(controller.isUpdatingDisplay)
            NotificationCenter.default.post(name: interruption, object: nil, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ])
            let deadline = Date().addingTimeInterval(1)
            while controller.isUpdatingDisplay && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(controller.playing, interruption.rawValue)
            XCTAssertFalse(controller.isUpdatingDisplay, interruption.rawValue)
            let paused = controller.elapsed
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(controller.elapsed, paused, accuracy: 0.001, "Suspended audio must remain paused")
        }
        controller.stopAll()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let content = VStack(alignment: .leading, spacing: 24) {
                Text("Audios").font(.title.bold())
                VoicePlaybackControls(player: controller, data: data, title: "Tu audio")
                    .padding(20).background(CoupleTheme.rose.card, in: RoundedRectangle(cornerRadius: 22))
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CoupleTheme.rose.canvas).tint(CoupleTheme.rose.accent)
            let host = UIHostingController(rootView: content)
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
            XCTAssertFalse(controller.playing, "Rendering and seeking must never autoplay")
            let attachment = XCTAttachment(image: image)
            attachment.name = appearance == .dark ? "voice-player-dark" : "voice-player-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testPausedVoiceCanBeReviewedAndResumedWithoutReplacingEarlierSamples() async throws {
        let first = try voicePCMData(frames: 16_000, sample: 1234)
        let second = try voicePCMData(frames: 32_000, sample: -2345)
        var devices: [VoiceRecorderFixture] = []
        var snapshots: [Data] = []
        let controller = VoiceNoteController(requestPermission: { true }, makeRecorder: { url, _ in
            let device = VoiceRecorderFixture(url: url, data: devices.isEmpty ? first : second)
            devices.append(device)
            return device
        }, managesAudioSession: false)
        defer { controller.stopAll() }
        controller.didRecord = { snapshots.append($0) }

        await controller.record()
        XCTAssertTrue(controller.recording)
        XCTAssertFalse(controller.recordingPaused)
        controller.pauseRecording()
        XCTAssertFalse(controller.recording)
        XCTAssertTrue(controller.recordingPaused)
        XCTAssertTrue(controller.canResumeRecording)
        XCTAssertFalse(controller.isUpdatingDisplay)
        XCTAssertEqual(snapshots.count, 1)
        let reviewed = try XCTUnwrap(controller.recordedData)
        controller.prepare(reviewed)
        controller.seek(to: 0.5)
        controller.pause()
        XCTAssertTrue(controller.canResumeRecording, "Reviewing a paused WAV must keep its continuation")

        await controller.resumeRecording()
        XCTAssertTrue(controller.recording)
        XCTAssertFalse(controller.recordingPaused)
        XCTAssertEqual(controller.elapsed, 1, accuracy: 0.001)
        XCTAssertEqual(devices[1].limit, 59, accuracy: 0.001)
        controller.pauseRecording()
        XCTAssertEqual(controller.duration, 3, accuracy: 0.001)
        XCTAssertEqual(snapshots.count, 2)
        let samples = try voicePCMSamples(XCTUnwrap(controller.recordedData))
        XCTAssertEqual(samples.count, 48_000)
        XCTAssertTrue(samples.prefix(16_000).allSatisfy { $0 == 1234 })
        XCTAssertTrue(samples.dropFirst(16_000).allSatisfy { $0 == -2345 })
        controller.finishRecording()
        XCTAssertFalse(controller.recordingPaused)
        XCTAssertFalse(controller.canResumeRecording)
        XCTAssertEqual(controller.recordedData, snapshots.last)
        XCTAssertEqual(snapshots.count, 2, "Finalizing an already reviewed take must not duplicate the draft callback")
        XCTAssertTrue(devices.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @MainActor
    func testVoiceContinuationFailuresKeepTheReviewedTakeAndAllowRetry() async throws {
        let first = try voicePCMData(frames: 16_000, sample: 2400)
        var devices: [VoiceRecorderFixture] = []
        let controller = VoiceNoteController(requestPermission: { true }, makeRecorder: { url, _ in
            let index = devices.count
            let device = VoiceRecorderFixture(url: url, data: index == 2 ? Data("corrupt".utf8) : first,
                                              starts: index != 1)
            devices.append(device)
            return device
        }, managesAudioSession: false)
        defer { controller.stopAll() }
        await controller.record()
        controller.pauseRecording()
        let reviewed = try XCTUnwrap(controller.recordedData)
        controller.prepare(reviewed)

        await controller.resumeRecording()
        XCTAssertFalse(controller.recording)
        XCTAssertTrue(controller.canResumeRecording)
        XCTAssertEqual(controller.recordedData, reviewed)
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: devices[1].url.path))

        await controller.resumeRecording()
        XCTAssertTrue(controller.recording)
        controller.pauseRecording()
        XCTAssertTrue(controller.canResumeRecording)
        XCTAssertEqual(controller.recordedData, reviewed, "An unreadable new segment must never replace the good prefix")
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: devices[2].url.path))
        controller.cancelRecording()
        XCTAssertFalse(controller.recordingPaused)
        XCTAssertFalse(controller.isUpdatingDisplay)
        XCTAssertEqual(controller.recordedData, reviewed)
        XCTAssertTrue(devices.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @MainActor
    func testVoiceLimitAppliesToTheWholeTakeAcrossPauses() async throws {
        let first = try voicePCMData(frames: 59 * 16_000, sample: 1000)
        let second = try voicePCMData(frames: 2 * 16_000, sample: -1000)
        var devices: [VoiceRecorderFixture] = []
        let controller = VoiceNoteController(requestPermission: { true }, makeRecorder: { url, _ in
            let device = VoiceRecorderFixture(url: url, data: devices.isEmpty ? first : second)
            devices.append(device)
            return device
        }, managesAudioSession: false)
        defer { controller.stopAll() }
        await controller.record()
        controller.pauseRecording()
        await controller.resumeRecording()
        XCTAssertEqual(devices[1].limit, 1, accuracy: 0.001)
        controller.pauseRecording()
        let data = try XCTUnwrap(controller.recordedData)
        XCTAssertEqual(try AVAudioPlayer(data: data).duration, 60, accuracy: 0.001)
        XCTAssertEqual(try voicePCMSamples(data).count, 60 * 16_000)
        XCTAssertFalse(controller.recordingPaused)
        XCTAssertFalse(controller.canResumeRecording)
        XCTAssertFalse(controller.isUpdatingDisplay)
        XCTAssertTrue(devices.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        await controller.resumeRecording()
        XCTAssertEqual(devices.count, 2, "The duration limit must prevent opening another segment")
    }

    @MainActor
    func testCancellingPausedVoiceWhilePermissionIsPendingCannotStartAMicrophoneLater() async throws {
        let data = try voicePCMData(frames: 16_000, sample: 1200)
        var requests = 0
        var permission: CheckedContinuation<Bool, Never>?
        var devices: [VoiceRecorderFixture] = []
        let controller = VoiceNoteController(requestPermission: {
            requests += 1
            if requests == 1 { return true }
            return await withCheckedContinuation { permission = $0 }
        }, makeRecorder: { url, _ in
            let device = VoiceRecorderFixture(url: url, data: data)
            devices.append(device)
            return device
        }, managesAudioSession: false)
        defer { controller.stopAll() }
        await controller.record()
        controller.pauseRecording()
        let reviewed = controller.recordedData
        let resuming = Task { await controller.resumeRecording() }
        let deadline = Date().addingTimeInterval(1)
        while permission == nil && Date() < deadline { await Task.yield() }
        XCTAssertTrue(controller.requestingPermission)
        controller.cancelRecording()
        permission?.resume(returning: true)
        await resuming.value
        XCTAssertFalse(controller.recording)
        XCTAssertFalse(controller.recordingPaused)
        XCTAssertFalse(controller.requestingPermission)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(controller.recordedData, reviewed)
        XCTAssertTrue(devices.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @MainActor
    func testVoiceBackgroundCaptureKeepsAllSegmentsWithoutResuming() async throws {
        let segment = try voicePCMData(frames: 16_000, sample: 1500)
        var devices: [VoiceRecorderFixture] = []
        var snapshots: [Data] = []
        let controller = VoiceNoteController(requestPermission: { true }, makeRecorder: { url, _ in
            let device = VoiceRecorderFixture(url: url, data: segment)
            devices.append(device)
            return device
        }, managesAudioSession: false)
        defer { controller.stopAll() }
        controller.didRecord = { snapshots.append($0) }
        await controller.record()
        controller.pauseRecording()
        await controller.resumeRecording()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let deadline = Date().addingTimeInterval(1)
        while controller.recording && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.recording)
        XCTAssertFalse(controller.recordingPaused)
        XCTAssertFalse(controller.isUpdatingDisplay)
        XCTAssertFalse(controller.playing)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(try AVAudioPlayer(data: XCTUnwrap(controller.recordedData)).duration, 2, accuracy: 0.001)
        XCTAssertTrue(devices.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    }

    func testMissingOrInsecureConfigurationNeverSelectsDemoBackend() {
        for url in ["", "$(PAIRNOTES_API_BASE_URL)", "http://127.0.0.1:3000", "https://localhost/",
                    "https://user:secret@example.test", "https://example.test/?token=secret", "https://example.test/#fragment"] {
            XCTAssertThrowsError(try ServiceConfiguration.load(values: [
                "PAIRNOTES_API_BASE_URL": url, "PAIRNOTES_APNS_ENVIRONMENT": "development"
            ]), url)
        }
    }

    func testExplicitHTTPSConfigurationKeepsBasePathAndRequiresAPNsEnvironment() throws {
        let config = try configuration()
        XCTAssertEqual(config.apiBaseURL.absoluteString, "https://api.example.test/v1/")
        XCTAssertEqual(config.apnsEnvironment, "development")
        XCTAssertTrue(config.googleClientID.isEmpty)
        XCTAssertThrowsError(try ServiceConfiguration.load(values: ["PAIRNOTES_API_BASE_URL": "https://api.example.test"]))
    }

    func testMalformedSessionCannotBeAcceptedAsAuthentication() {
        XCTAssertThrowsError(try AuthSession.decode([:], provider: "google"))
        XCTAssertThrowsError(try AuthSession.decode(sessionJSON(), provider: "demo"))
        var bad = sessionJSON()
        bad["refreshToken"] = "short"
        XCTAssertThrowsError(try AuthSession.decode(bad, provider: "apple"))
        bad = sessionJSON()
        bad["accessToken"] = String(repeating: "a", count: 42) + "\n"
        XCTAssertThrowsError(try AuthSession.decode(bad, provider: "google"))
    }

    func testTimelineCursorUsesIntegerMillisecondsAndRejectsUnsafeDates() throws {
        let date = Date(timeIntervalSince1970: 2_147_483_648_002.0 / 1_000)
        XCTAssertEqual(try RailwayClient.milliseconds(date), 2_147_483_648_002)
        XCTAssertThrowsError(try RailwayClient.milliseconds(Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try RailwayClient.milliseconds(Date(timeIntervalSince1970: -1)))
        XCTAssertThrowsError(try RailwayClient.milliseconds(Date(timeIntervalSince1970: 9_007_199_254_740_992.0 / 1_000)))
    }

    func testPrivateSessionGroupCannotBeSharedWithWidget() throws {
        var values = validConfigurationValues()
        values["PAIRNOTES_KEYCHAIN_GROUP"] = values["PAIRNOTES_PRIVATE_KEYCHAIN_GROUP"]
        XCTAssertThrowsError(try ServiceConfiguration.load(values: values))
        values = validConfigurationValues()
        values["PAIRNOTES_PRIVATE_KEYCHAIN_GROUP"] = "$(AppIdentifierPrefix)org.example.PairNotes"
        XCTAssertThrowsError(try ServiceConfiguration.load(values: values))
    }

    func testOnlyExplicitNullConfirmsAnUnlinkedPair() throws {
        XCTAssertNil(try AppServices.membership(from: ["pair": NSNull()], for: "fictional-uid"))
        for malformed: [String: Any] in [[:], ["pair": "missing"], ["pair": []], ["pair": ["status": "active"]]] {
            XCTAssertThrowsError(try AppServices.membership(from: malformed, for: "fictional-uid"))
        }
    }

    @MainActor
    func testConcurrentExpiredRequestsShareOneRefreshAndPersistRotation() async throws {
        let saved = try AuthSession.decode(sessionJSON(expired: true), provider: "google")
        let store = MemoryAuthStore(saved)
        let transport = SessionTransportFixture()
        let client = try RailwayClient(configuration: configuration(), store: store, transport: transport)
        async let first = client.authenticatedJSON(path: "auth/session", method: "GET")
        async let second = client.authenticatedJSON(path: "auth/session", method: "GET")
        _ = try await (first, second)
        let stats = await transport.stats()
        XCTAssertEqual(stats.refreshes, 1)
        XCTAssertEqual(stats.requests, 2)
        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(store.value?.refreshToken, String(repeating: "n", count: 43))
        XCTAssertEqual(Set(stats.authorization), ["Bearer " + String(repeating: "b", count: 43)])
    }

    @MainActor
    func testSignOutDuringRefreshCannotRestoreOldAccount() async throws {
        let saved = try AuthSession.decode(sessionJSON(expired: true), provider: "google")
        let store = MemoryAuthStore(saved)
        let transport = SessionTransportFixture(holdRefresh: true)
        let client = try RailwayClient(configuration: configuration(), store: store, transport: transport)
        let pending = Task<Void, Error> { _ = try await client.authenticatedJSON(path: "auth/session", method: "GET") }
        await transport.waitUntilRefreshing()
        client.clear()
        await transport.releaseRefresh()
        do { _ = try await pending.value; XCTFail("A response from the signed-out session must be rejected") }
        catch { XCTAssertNil(client.session) }
        XCTAssertNil(store.value)
        XCTAssertEqual(store.writes, 0)
    }

    @MainActor
    func testRejectedRefreshClearsTokensInsteadOfRetryingAnOldIdentity() async throws {
        let store = MemoryAuthStore(try AuthSession.decode(sessionJSON(expired: true), provider: "google"))
        let transport = SessionTransportFixture(rejectRefresh: true)
        let client = try RailwayClient(configuration: configuration(), store: store, transport: transport)
        do { _ = try await client.authenticatedJSON(path: "auth/session", method: "GET"); XCTFail("Revoked refresh must fail") }
        catch { XCTAssertEqual((error as? APIError)?.status, 401) }
        XCTAssertNil(client.session)
        XCTAssertNil(store.value)
    }

    @MainActor
    func testRecentLoginRequiredPreservesValidSessionForReauthentication() async throws {
        let saved = try AuthSession.decode(sessionJSON(), provider: "google")
        let store = MemoryAuthStore(saved)
        let transport = SessionTransportFixture(recentLoginRequired: true)
        let client = try RailwayClient(configuration: configuration(), store: store, transport: transport)
        do { _ = try await client.authenticatedJSON(path: "closePair"); XCTFail("Sensitive operation must require reauthentication") }
        catch { XCTAssertEqual((error as? APIError)?.code, "recent_login_required") }
        let stats = await transport.stats()
        XCTAssertEqual(stats.refreshes, 0)
        XCTAssertEqual(client.session, saved)
        XCTAssertEqual(store.value, saved)
    }
}

private func configuration() throws -> ServiceConfiguration {
    try ServiceConfiguration.load(values: validConfigurationValues())
}

private func validConfigurationValues() -> [String: Any] {
    ["PAIRNOTES_API_BASE_URL": "https://api.example.test/v1", "PAIRNOTES_APNS_ENVIRONMENT": "development",
     "CFBundleIdentifier": "org.example.PairNotes", "PAIRNOTES_PRIVATE_KEYCHAIN_GROUP": "FICTITIOUS.org.example.PairNotes",
     "PAIRNOTES_KEYCHAIN_GROUP": "FICTITIOUS.org.example.PairNotes.widget"]
}

private func sessionJSON(expired: Bool = false, rotated: Bool = false) -> [String: Any] {
    ["accessToken": String(repeating: rotated ? "b" : "a", count: 43),
     "refreshToken": String(repeating: rotated ? "n" : "r", count: 43),
     "expiresAt": Date().addingTimeInterval(expired ? -60 : 900).timeIntervalSince1970 * 1_000,
     "identity": ["uid": "fictional-test-account", "displayName": "Sol ficticio"]]
}

@MainActor
private final class MemoryAuthStore: AuthSessionStore {
    var value: AuthSession?
    var writes = 0
    init(_ value: AuthSession) { self.value = value }
    func read(baseURL: URL) throws -> AuthSession? { value }
    func write(_ session: AuthSession, baseURL: URL) throws { writes += 1; value = session }
    func clear() throws { value = nil }
}

private actor SessionTransportFixture: HTTPTransport {
    let holdRefresh: Bool
    let rejectRefresh: Bool
    let recentLoginRequired: Bool
    private var refreshes = 0
    private var requests = 0
    private var authorization: [String] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(holdRefresh: Bool = false, rejectRefresh: Bool = false, recentLoginRequired: Bool = false) {
        self.holdRefresh = holdRefresh
        self.rejectRefresh = rejectRefresh
        self.recentLoginRequired = recentLoginRequired
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isRefresh = request.url!.path.hasSuffix("auth/refresh")
        if isRefresh {
            refreshes += 1
            if holdRefresh {
                await withCheckedContinuation { continuation in
                    releaseWaiter = continuation
                    startedWaiter?.resume()
                    startedWaiter = nil
                }
            }
        } else {
            requests += 1
            authorization.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
        let status = (isRefresh && rejectRefresh) || recentLoginRequired ? 401 : 200
        let payload: [String: Any] = status == 401 ? ["error": ["message": recentLoginRequired ? "recent_login_required" : "session_revoked"]]
            : (isRefresh ? sessionJSON(rotated: true) : ["identity": ["uid": "fictional-test-account", "displayName": "Sol ficticio"]])
        return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func waitUntilRefreshing() async {
        if releaseWaiter != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func releaseRefresh() { releaseWaiter?.resume(); releaseWaiter = nil }
    func stats() -> (refreshes: Int, requests: Int, authorization: [String]) { (refreshes, requests, authorization) }
}

/// Files contain deterministic, real PCM samples; no microphone or permission dialog is used.
@MainActor
private final class VoiceRecorderFixture: VoiceRecordingDevice {
    let url: URL
    private let data: Data
    private let starts: Bool
    weak var delegate: (any AVAudioRecorderDelegate)?
    var isMeteringEnabled = false
    var currentTime: TimeInterval = 0
    private(set) var limit: TimeInterval = 0
    init(url: URL, data: Data, starts: Bool = true) {
        self.url = url; self.data = data; self.starts = starts
    }
    func record(forDuration duration: TimeInterval) -> Bool { limit = duration; return starts }
    func stop() { try? data.write(to: url) }
    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { -20 }
}

private func voicePCMData(frames: Int, sample: Int16) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames { buffer.int16ChannelData![0][index] = sample }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }
    return try Data(contentsOf: url)
}

private func voicePCMSamples(_ data: Data) throws -> [Int16] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
    return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
}
