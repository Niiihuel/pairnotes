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
    func testVoicePreparationSeekingAndPausePreservePositionWithoutAutoplay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        for index in 0..<16000 { buffer.int16ChannelData![0][index] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: url)
        let controller = VoiceNoteController()
        controller.prepare(data)
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.playing)
        XCTAssertEqual(controller.duration, 1, accuracy: 0.02)
        controller.seek(to: 0.5)
        controller.pause()
        controller.prepare(data)
        XCTAssertEqual(controller.elapsed, 0.5, accuracy: 0.02)
        controller.seek(to: .nan)
        XCTAssertEqual(controller.elapsed, 0.5, accuracy: 0.02)
        controller.seek(to: -1)
        XCTAssertEqual(controller.elapsed, 0)
        controller.stopAll()
        XCTAssertEqual(controller.duration, 0)
        XCTAssertFalse(controller.playing)
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
