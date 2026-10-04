import XCTest
import Foundation
import PairNotesCore
@testable import PairNotes

final class WidgetRemoteClientTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jKfQAAAAASUVORK5CYII=")!

    private func setupClient() -> (WidgetRemoteClient, WidgetTestState, URL) {
        let state = WidgetTestState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WidgetTestProtocol.self]
        WidgetTestProtocol.state = state
        let client = WidgetRemoteClient(session: URLSession(configuration: configuration),
                                        authorization: { state.authorization }, directory: { directory })
        return (client, state, directory)
    }

    private func metadata(_ state: WidgetTestState, imageHash: String? = nil, epoch: UInt64 = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "pairId": "pair-test", "pairEpoch": epoch,
            "generatedAt": Date().timeIntervalSince1970 * 1_000,
            "validUntil": Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000,
            "note": ["id": "20000000-0000-4000-8000-000000000002", "revision": 1,
                     "revisionHash": String(repeating: "a", count: 64),
                     "publishedAt": Date().timeIntervalSince1970 * 1_000,
                     "authorDisplayName": "Persona ficticia", "imageSHA256": imageHash ?? ContentDigest.sha256(png)]
        ])
    }

    func testReceivedSnapshotThenOfflineCacheThenRevocationClearsPixels() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try metadata(state)), (200, png)]
        let received = await client.refresh()
        XCTAssertNotNil(received.snapshot)
        XCTAssertFalse(received.cached)
        XCTAssertEqual(state.paths, ["/widgetSnapshot", "/widgetImage"])
        XCTAssertTrue(state.authorizations.allSatisfy { $0 == "Bearer " + state.authorization!.token })
        state.offline = true
        let cached = await client.refresh()
        XCTAssertEqual(cached.snapshot, received.snapshot)
        XCTAssertTrue(cached.cached)
        state.offline = false
        state.responses = [(403, Data())]
        let revoked = await client.refresh()
        XCTAssertNil(revoked.snapshot)
        state.offline = true
        let afterRevocation = await client.refresh()
        XCTAssertNil(afterRevocation.snapshot)
    }

    func testDifferentCredentialCannotReadPriorOfflineCache() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try metadata(state)), (200, png)]
        let initial = await client.refresh()
        XCTAssertNotNil(initial.snapshot)
        state.authorization = WidgetTestState.credential(token: String(repeating: "b", count: 64), uid: "second-user")
        state.offline = true
        let switched = await client.refresh()
        XCTAssertNil(switched.snapshot)
    }

    func testStalePairEpochAndCorruptImageAreRejected() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try metadata(state, epoch: 2))]
        let wrongPair = await client.refresh()
        XCTAssertNil(wrongPair.snapshot)
        XCTAssertEqual(state.paths, ["/widgetSnapshot"])
        state.responses = [(200, try metadata(state, imageHash: String(repeating: "0", count: 64))), (200, png)]
        let corrupt = await client.refresh()
        XCTAssertNil(corrupt.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("received-note.json").path))
    }

    func testExpiredCredentialMakesNoNetworkRequest() async {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.authorization = WidgetTestState.credential(expiry: .distantPast)
        let result = await client.refresh()
        XCTAssertNil(result.snapshot)
        XCTAssertTrue(state.paths.isEmpty)
    }
}

/// URLProtocol executes synchronously in these tests; state is locked because
/// URLSession calls it off the test's executor. No real keychain or network used.
private final class WidgetTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAuthorization: WidgetAuthorization? = WidgetTestState.credential()
    private var storedResponses: [(Int, Data)] = []
    private var storedOffline = false
    private var storedPaths: [String] = []
    private var storedHeaders: [String] = []
    var authorization: WidgetAuthorization? {
        get { lock.withLock { storedAuthorization } }
        set { lock.withLock { storedAuthorization = newValue } }
    }
    var responses: [(Int, Data)] {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }
    var offline: Bool {
        get { lock.withLock { storedOffline } }
        set { lock.withLock { storedOffline = newValue } }
    }
    var paths: [String] { lock.withLock { storedPaths } }
    var authorizations: [String] { lock.withLock { storedHeaders } }
    static func credential(token: String = String(repeating: "a", count: 64), uid: String = "first-user",
                           expiry: Date = Date().addingTimeInterval(3_600)) -> WidgetAuthorization {
        WidgetAuthorization(token: token, expiresAt: expiry, baseURL: URL(string: "https://widget.example.test")!,
                            uid: uid, pairID: "pair-test", pairEpoch: 1, deviceID: "device-test", apnsEnvironment: "development")
    }
    func next(_ request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            storedPaths.append(request.url!.path)
            storedHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if storedOffline { throw URLError(.notConnectedToInternet) }
            guard !storedResponses.isEmpty else { throw URLError(.badServerResponse) }
            return storedResponses.removeFirst()
        }
    }
}

private final class WidgetTestProtocol: URLProtocol {
    static var state: WidgetTestState?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "widget.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let state = Self.state else { throw URLError(.badServerResponse) }
            let (status, data) = try state.next(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
