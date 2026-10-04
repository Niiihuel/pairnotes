import XCTest
import Foundation
import PairNotesCore
@testable import PairNotes

final class ServiceConfigurationTests: XCTestCase {
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
        let pending = Task { try await client.authenticatedJSON(path: "auth/session", method: "GET") }
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
}

private func configuration() throws -> ServiceConfiguration {
    try ServiceConfiguration.load(values: ["PAIRNOTES_API_BASE_URL": "https://api.example.test/v1", "PAIRNOTES_APNS_ENVIRONMENT": "development"])
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
    private var refreshes = 0
    private var requests = 0
    private var authorization: [String] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(holdRefresh: Bool = false, rejectRefresh: Bool = false) {
        self.holdRefresh = holdRefresh
        self.rejectRefresh = rejectRefresh
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
        let status = isRefresh && rejectRefresh ? 401 : 200
        let payload: [String: Any] = status == 401 ? ["error": ["message": "session_revoked"]]
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
