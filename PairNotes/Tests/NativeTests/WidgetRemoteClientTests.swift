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
                                        authorization: { state.authorization }, saveAuthorization: { state.authorization = $0 }, directory: { directory })
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
        XCTAssertTrue(revoked.needsAuthorization)
        state.offline = true
        let afterRevocation = await client.refresh()
        XCTAssertNil(afterRevocation.snapshot)
    }

    func testSuccessfulRefreshRenewsCredentialAndKeepsOfflineContentPastRefreshInterval() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renewed = Date().addingTimeInterval(30 * 86_400)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata(state)) as? [String: Any])
        payload["credentialExpiresAt"] = renewed.timeIntervalSince1970 * 1_000
        payload["validUntil"] = Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1_000
        state.responses = [(200, try JSONSerialization.data(withJSONObject: payload)), (200, png)]
        let result = await client.refresh()
        XCTAssertNotNil(result.snapshot)
        XCTAssertEqual(try XCTUnwrap(state.authorization).expiresAt.timeIntervalSince1970, renewed.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(result.expiresAt).timeIntervalSinceNow, 23 * 3_600)
        state.offline = true
        let cached = await client.refresh()
        XCTAssertTrue(cached.cached)
        XCTAssertEqual(cached.snapshot, result.snapshot)
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
        XCTAssertTrue(result.needsAuthorization, "The app must repair expired credentials automatically")
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

    func testUnchangedAvatarSurvivesRefreshWithoutDownloadingAgain() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try coupleMetadata(avatar: true)), (200, png)]
        let initial = await client.refresh()
        XCTAssertEqual(initial.avatars["first-user"], png)
        state.responses = [(200, try coupleMetadata(avatar: true))]
        let refreshed = await client.refresh()
        XCTAssertEqual(refreshed.avatars["first-user"], png)
        XCTAssertFalse(refreshed.cached)
        XCTAssertEqual(state.paths.filter { $0 == "/widgetAvatar" }.count, 1)
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

    private let photoID = "50000000-0000-4000-8000-000000000005"
    private let photoAssetID = "60000000-0000-4000-8000-000000000006"

    private func photoMetadata(hash: String? = nil, assetID: String? = nil) throws -> Data {
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: coupleMetadata()) as? [String: Any])
        payload["latestPhoto"] = ["id": photoID, "authorId": "second-user", "recipientId": "first-user",
                                  "caption": "Una foto ficticia", "sentAt": Date().addingTimeInterval(-10).timeIntervalSince1970 * 1_000,
                                  "photo": ["id": assetID ?? photoAssetID, "sha256": hash ?? ContentDigest.sha256(png)]]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func reactionResponse(kind: String = "heart", author: String = "first-user") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["reaction": ["authorId": author, "photoId": photoID,
            "kind": kind, "updatedAt": Date().timeIntervalSince1970 * 1_000]])
    }

    func testPhotoLoadsVerifiedPixelsAndReusesUnchangedImage() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try photoMetadata()), (200, png)]
        let initial = await client.refresh()
        XCTAssertEqual(initial.photoData, png)
        XCTAssertEqual(initial.couple?.latestPhoto?.caption, "Una foto ficticia")
        XCTAssertEqual(state.paths, ["/widgetSnapshot", "/widgetPhoto"])
        state.responses = [(200, try photoMetadata())]
        let refreshed = await client.refresh()
        XCTAssertEqual(refreshed.photoData, png)
        XCTAssertEqual(state.paths.filter { $0 == "/widgetPhoto" }.count, 1)
        state.authorization = WidgetTestState.credential(uid: "second-user")
        state.offline = true
        let switched = await client.refresh()
        XCTAssertNil(switched.photoData)
        XCTAssertNil(switched.couple)
    }

    func testCorruptReplacementPhotoCannotReusePreviouslyAuthorizedPixels() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try photoMetadata()), (200, png)]
        _ = await client.refresh()
        state.responses = [(200, try photoMetadata(hash: String(repeating: "f", count: 64),
                                                    assetID: "70000000-0000-4000-8000-000000000007")), (200, png)]
        let replaced = await client.refresh()
        XCTAssertNil(replaced.photoData)
        state.offline = true
        let offline = await client.refresh()
        XCTAssertNil(offline.photoData)
    }

    func testReactionConfirmsServerValueAndClearsVisibleRetryFeedback() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try photoMetadata()), (200, png)]
        _ = await client.refresh()
        state.offline = true
        do {
            _ = try await client.reactToPhoto(photoID: photoID, assetID: photoAssetID, kind: .heart)
            XCTFail("An offline reaction must not appear sent")
        } catch {}
        await client.recordPhotoInteractionFailure(photoID: photoID)
        let failed = await client.refresh()
        XCTAssertNil(failed.couple?.latestPhoto?.reaction)
        XCTAssertNotNil(failed.photoInteractionMessage)
        state.offline = false
        state.responses = [(200, try reactionResponse())]
        let confirmed = try await client.reactToPhoto(photoID: photoID, assetID: photoAssetID, kind: .heart)
        XCTAssertEqual(confirmed.kind, .heart)
        state.offline = true
        let successful = await client.refresh()
        XCTAssertEqual(successful.couple?.latestPhoto?.reaction?.kind, .heart)
        XCTAssertNil(successful.photoInteractionMessage)
    }

    func testReactionRevocationClearsPhotoAndSpoofedResponseCannotChangeReaction() async throws {
        let (client, state, directory) = setupClient()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.responses = [(200, try photoMetadata()), (200, png)]
        _ = await client.refresh()
        state.responses = [(200, try reactionResponse(author: "second-user"))]
        do {
            _ = try await client.reactToPhoto(photoID: photoID, assetID: photoAssetID, kind: .heart)
            XCTFail("Another account's reaction must be rejected")
        } catch {}
        state.offline = true
        let unchanged = await client.refresh()
        XCTAssertNil(unchanged.couple?.latestPhoto?.reaction)
        state.offline = false
        state.responses = [(403, Data())]
        do {
            _ = try await client.reactToPhoto(photoID: photoID, assetID: photoAssetID, kind: .heart)
            XCTFail("A revoked widget credential cannot react")
        } catch {}
        state.offline = true
        let revoked = await client.refresh()
        XCTAssertNil(revoked.photoData)
    }

    func testProximityNeedsFreshAndAccurateLocationAndSeparationIncreasesWithDistance() {
        let now = Date()
        let near = CoupleDistancePresentation(distance: CoupleDistance(status: .available, meters: 30,
            updatedAt: now, accuracyMeters: 20), at: now)
        XCTAssertEqual(near.title, "¡Estamos juntos!")
        let uncertain = CoupleDistancePresentation(distance: CoupleDistance(status: .available, meters: 30,
            updatedAt: now, accuracyMeters: 200), at: now)
        XCTAssertNotEqual(uncertain.title, "¡Estamos juntos!")
        let stale = CoupleDistancePresentation(distance: CoupleDistance(status: .available, meters: 30,
            updatedAt: now.addingTimeInterval(-CoupleDistance.freshAge), accuracyMeters: 20), at: now)
        XCTAssertNotEqual(stale.title, "¡Estamos juntos!")
        XCTAssertEqual(stale.detail, "Ubicación anterior")
        let far = CoupleDistancePresentation(distance: CoupleDistance(status: .available, meters: 100_000,
            updatedAt: now, accuracyMeters: 20), at: now)
        XCTAssertGreaterThan(far.separation, near.separation)
        let expired = CoupleDistancePresentation(distance: CoupleDistance(status: .available, meters: 30,
            updatedAt: now.addingTimeInterval(-CoupleDistance.maximumAge), accuracyMeters: 20), at: now)
        XCTAssertEqual(expired.title, "≈ menos de 100 m")
        XCTAssertEqual(expired.detail, "Ubicación anterior")
        XCTAssertFalse(expired.fresh)
        XCTAssertEqual(expired.separation, near.separation)
        XCTAssertNotNil(expired.updatedAt)
    }

    func testDistanceSeparationIsMonotonicAcrossItsWholeRangeAndDoesNotChangeAsItAges() {
        let now = Date()
        let ranges: [Double] = [0, 30, 100, 500, 1_000, 10_000, 100_000, 1_000_000, 21_000_000]
        var previous: CGFloat = -1
        for meters in ranges {
            let fresh = CoupleDistancePresentation(distance: CoupleDistance(status: .available,
                meters: meters, updatedAt: now, accuracyMeters: 20), at: now)
            let old = CoupleDistancePresentation(distance: CoupleDistance(status: .available,
                meters: meters, updatedAt: now.addingTimeInterval(-3 * 86_400), accuracyMeters: 20), at: now)
            XCTAssertGreaterThan(fresh.separation, previous)
            XCTAssertGreaterThanOrEqual(fresh.separation, 0)
            XCTAssertLessThanOrEqual(fresh.separation, 1)
            XCTAssertEqual(fresh.separation, old.separation)
            XCTAssertTrue(old.hasDistance)
            XCTAssertFalse(old.fresh)
            XCTAssertNotEqual(old.title, "¡Estamos juntos!")
            XCTAssertEqual(old.detail, "Ubicación anterior")
            previous = fresh.separation
        }
    }

    func testUnavailableDistancesHaveNeutralGeometryAndNeverExposeAnOldMeasurement() {
        let now = Date()
        for status in [CoupleDistanceStatus.disabled, .waiting] {
            let value = CoupleDistancePresentation(distance: CoupleDistance(status: status,
                meters: 30, updatedAt: now, accuracyMeters: 20), at: now)
            XCTAssertFalse(value.hasDistance)
            XCTAssertNil(value.updatedAt)
            XCTAssertEqual(value.separation, 0.5)
            XCTAssertNotEqual(value.symbol, "heart.fill")
        }
        for meters in [-1.0, .infinity, .nan, 21_000_001] {
            let value = CoupleDistancePresentation(distance: CoupleDistance(status: .available,
                meters: meters, updatedAt: now, accuracyMeters: 20), at: now)
            XCTAssertFalse(value.hasDistance)
            XCTAssertNil(value.updatedAt)
        }
    }

    func testDistanceAvatarLayoutFitsNarrowAccessoriesAndMovesFacesTogetherAsDistanceDecreases() {
        for width: CGFloat in [0, 1, 60, 100, 126, 152, 271, 600] {
            for compact in [false, true] {
                let size: CGFloat = compact ? 28 : 48
                let near = CoupleDistanceAvatarLayout(width: width, preferredAvatarSize: size,
                    separation: 0, compact: compact)
                let far = CoupleDistanceAvatarLayout(width: width, preferredAvatarSize: size,
                    separation: 1, compact: compact)
                XCTAssertLessThanOrEqual(near.connectorWidth, far.connectorWidth)
                for layout in [near, far] {
                    XCTAssertGreaterThanOrEqual(layout.avatarDiameter, 0)
                    XCTAssertLessThanOrEqual(layout.avatarDiameter, size)
                    XCTAssertGreaterThanOrEqual(layout.leadingInset, 0)
                    XCTAssertEqual(layout.leadingInset * 2 + layout.avatarDiameter * 2 + layout.connectorWidth,
                                   width, accuracy: 0.001)
                }
            }
        }
        for width: CGFloat in [-1, .infinity, .nan] {
            let layout = CoupleDistanceAvatarLayout(width: width, preferredAvatarSize: 28,
                separation: .nan, compact: true)
            XCTAssertEqual(layout.width, 0)
            XCTAssertEqual(layout.avatarDiameter, 0)
            XCTAssertEqual(layout.connectorWidth, 0)
        }
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
