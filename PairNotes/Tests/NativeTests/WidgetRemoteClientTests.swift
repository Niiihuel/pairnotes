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

    private func coupleMetadata(avatar: Bool = false, recipient: String = "first-user") throws -> Data {
        let avatarValue: Any = avatar ? ["id": "30000000-0000-4000-8000-000000000003", "sha256": ContentDigest.sha256(png)] : NSNull()
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "pairId": "pair-test", "pairEpoch": 1,
            "generatedAt": Date().timeIntervalSince1970 * 1_000,
            "validUntil": Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000,
            "note": NSNull(), "startedOn": "2024-01-31",
            "profiles": [["uid": "first-user", "displayName": "Alex ficticio", "avatar": avatarValue],
                         ["uid": "second-user", "displayName": "Sam ficticio", "avatar": NSNull()]],
            "latestMessage": ["id": "40000000-0000-4000-8000-000000000004", "authorId": "second-user",
                              "recipientId": recipient, "text": "Mensaje ficticio", "sentAt": Date().timeIntervalSince1970 * 1_000],
            "distance": ["status": "disabled", "meters": NSNull(), "updatedAt": NSNull(), "accuracyMeters": NSNull()]
        ])
    }

    func testCoupleDataWithoutDrawingLoadsPrivateAvatarAndCachesOnlyForSameAccount() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try coupleMetadata(avatar: true)), (200, png)]
        let received = await client.refresh()
        XCTAssertNil(received.snapshot)
        XCTAssertEqual(received.couple?.latestMessage?.text, "Mensaje ficticio")
        XCTAssertEqual(received.couple?.startedOn?.rawValue, "2024-01-31")
        XCTAssertEqual(received.avatars["first-user"], png)
        XCTAssertEqual(state.paths, ["/widgetSnapshot", "/widgetAvatar"])
        state.offline = true
        let cached = await client.refresh()
        XCTAssertTrue(cached.cached)
        XCTAssertEqual(cached.couple, received.couple)
        state.authorization = WidgetTestState.credential(uid: "second-user") // even if token were reused by bad local config
        let switched = await client.refresh()
        XCTAssertNil(switched.couple)
        XCTAssertTrue(switched.avatars.isEmpty)
    }

    func testRevokedAvatarRequestClearsAllPrivateCoupleDataAndPriorOfflineCache() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try coupleMetadata())]
        let initial = await client.refresh()
        XCTAssertNotNil(initial.couple)
        state.responses = [(200, try coupleMetadata(avatar: true)), (403, Data())]
        let revoked = await client.refresh()
        XCTAssertNil(revoked.couple)
        XCTAssertTrue(revoked.avatars.isEmpty)
        state.offline = true
        let offline = await client.refresh()
        XCTAssertNil(offline.couple)
    }

    func testWrongMessageRecipientAndExpiredCacheHidePrivateContent() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try coupleMetadata(recipient: "third-user"))]
        let wrongRecipient = await client.refresh()
        XCTAssertNil(wrongRecipient.couple)
        state.responses = [(200, try coupleMetadata())]
        let good = await client.refresh()
        XCTAssertNotNil(good.couple)
        let cacheURL = directory.appendingPathComponent("received-note.json")
        var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        cache["expiresAt"] = Date().addingTimeInterval(-1).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: cache).write(to: cacheURL)
        state.offline = true
        let expired = await client.refresh()
        XCTAssertNil(expired.couple)
        XCTAssertTrue(expired.avatars.isEmpty)
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
