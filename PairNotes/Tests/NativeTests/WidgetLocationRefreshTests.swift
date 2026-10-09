import Foundation
import PairNotesCore
import XCTest
@testable import PairNotes

final class WidgetLocationRefreshTests: XCTestCase {
    private func setup() -> (WidgetRemoteClient, DistanceRefreshState, URL) {
        let state = DistanceRefreshState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DistanceRefreshProtocol.self]
        DistanceRefreshProtocol.state = state
        let client = WidgetRemoteClient(session: URLSession(configuration: configuration),
            authorization: { state.authorization }, sampleLocation: { state.sample() }, directory: { directory })
        return (client, state, directory)
    }

    func testDistanceProviderMeasuresUploadsAndReloadsWithoutManualInteraction() async throws {
        let (client, state, directory) = setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await client.refreshDistance()
        XCTAssertEqual(state.paths, ["/widgetSnapshot", "/widgetLocation", "/widgetSnapshot"])
        XCTAssertEqual(state.measurementCount, 1)
        XCTAssertEqual(result.couple?.distance.displayMeters(), 500)
        let body = try XCTUnwrap(state.uploadedSample)
        XCTAssertEqual(Set(body.keys), Set(["latitude", "longitude", "horizontalAccuracy", "capturedAt", "consentVersion"]))
        XCTAssertEqual(body["consentVersion"] as? Int, 3)
        XCTAssertEqual(body["latitude"] as? Double, -31.4)
        XCTAssertEqual(state.tokens, Array(repeating: "Bearer " + state.authorization!.token, count: 3))
        let cache = try Data(contentsOf: directory.appendingPathComponent("received-note.json"))
        let cacheText = String(decoding: cache, as: UTF8.self)
        XCTAssertFalse(cacheText.contains("latitude"))
        XCTAssertFalse(cacheText.contains("longitude"))
        _ = await client.refreshDistance()
        XCTAssertEqual(state.measurementCount, 1, "Repeated timeline requests respect the measurement cooldown")
    }

    func testOrdinaryWidgetsAndMissingConsentNeverMeasure() async {
        let (client, state, directory) = setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await client.refresh()
        XCTAssertEqual(state.measurementCount, 0)
        state.consent = false
        _ = await client.refreshDistance()
        XCTAssertEqual(state.measurementCount, 0)
        XCTAssertFalse(state.paths.contains("/widgetLocation"))
    }

    func testDeniedWidgetLocationKeepsDatedDistanceWithoutUploading() async {
        let (client, state, directory) = setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.suppliesSample = false
        let result = await client.refreshDistance()
        XCTAssertEqual(state.paths, ["/widgetSnapshot"])
        XCTAssertEqual(state.measurementCount, 1)
        XCTAssertEqual(result.couple?.distance.displayMeters(), 2_000)
        XCTAssertEqual(result.couple?.distance.displayStatus(), .stale)
    }

    func testAccountChangeDuringMeasurementCannotUploadToNewAccountOrReturnOldDistance() async {
        for suppliesSample in [true, false] {
            let (client, state, directory) = setup()
            defer { try? FileManager.default.removeItem(at: directory) }
            state.switchAccountDuringSample = true
            state.suppliesSample = suppliesSample
            let result = await client.refreshDistance()
            XCTAssertNil(result.couple)
            XCTAssertFalse(state.paths.contains("/widgetLocation"))
        }
    }

    func testRemotePauseWhileMeasuringRechecksConsentAndRemovesDistance() async {
        let (client, state, directory) = setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.pauseDuringSample = true
        let result = await client.refreshDistance()
        XCTAssertEqual(state.paths, ["/widgetSnapshot", "/widgetLocation", "/widgetSnapshot"])
        XCTAssertEqual(result.couple?.distance.status, .disabled)
        XCTAssertNil(result.couple?.distance.displayMeters())
    }

    func testRejectedConsentCannotFallBackToOldCachedDistanceIfTheRecheckIsOffline() async {
        let (client, state, directory) = setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.pauseDuringSample = true
        state.offlineAfterRejection = true
        let result = await client.refreshDistance()
        XCTAssertNil(result.couple)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("received-note.json").path))
    }

    func testRemotePauseInvalidatesAnOrdinarySnapshotStartedWhileMeasuring() async throws {
        let measuring = expectation(description: "Fresh consent checked; location measurement suspended")
        let ordinaryStarted = expectation(description: "Ordinary refresh holds an older snapshot")
        let ordinaryCancelled = expectation(description: "Rejected consent cancels the older snapshot")
        let ordinaryFinished = expectation(description: "Cancelled ordinary refresh returns")
        let freshRequested = expectation(description: "Rejected consent requests a new snapshot")
        let distanceFinished = expectation(description: "Distance refresh returns without the held snapshot")
        let state = PausedDistanceRaceState(measuring: measuring, ordinaryStarted: ordinaryStarted,
            ordinaryCancelled: ordinaryCancelled, freshRequested: freshRequested)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PausedDistanceRaceProtocol.self]
        PausedDistanceRaceProtocol.state = state
        let session = URLSession(configuration: configuration)
        let client = WidgetRemoteClient(session: session, authorization: { state.authorization },
            sampleLocation: { await state.sample() }, directory: { directory })
        let distance = Task {
            let result = await client.refreshDistance()
            distanceFinished.fulfill()
            return result
        }
        var ordinary: Task<WidgetRefreshResult, Never>?
        defer {
            state.releaseAll()
            distance.cancel(); ordinary?.cancel()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let measurementResult = await XCTWaiter.fulfillment(of: [measuring], timeout: 3)
        XCTAssertEqual(measurementResult, .completed)
        guard measurementResult == .completed else { return }
        ordinary = Task {
            let result = await client.refresh()
            ordinaryFinished.fulfill()
            return result
        }
        let ordinaryResult = await XCTWaiter.fulfillment(of: [ordinaryStarted], timeout: 3)
        XCTAssertEqual(ordinaryResult, .completed)
        guard ordinaryResult == .completed else { return }
        state.releaseMeasurement()
        let completed = await XCTWaiter.fulfillment(
            of: [ordinaryCancelled, ordinaryFinished, freshRequested, distanceFinished], timeout: 5)
        XCTAssertEqual(completed, .completed,
            "A rejected location upload must replace a concurrent stale GET, rather than coalesce with it")
        guard completed == .completed else { return }
        let result = await distance.value
        XCTAssertEqual(state.paths, ["/widgetSnapshot", "/widgetSnapshot", "/widgetLocation", "/widgetSnapshot"])
        XCTAssertEqual(result.couple?.distance.status, .disabled)
        XCTAssertNil(result.couple?.distance.displayMeters())
        XCTAssertNil(result.locationAccess)
        let cached = try Data(contentsOf: directory.appendingPathComponent("received-note.json"))
        struct CachedDistance: Decodable { let couple: CoupleWidgetSnapshot? }
        let persisted = try JSONDecoder().decode(CachedDistance.self, from: cached)
        XCTAssertEqual(persisted.couple?.distance.status, .disabled,
            "The cancelled ordinary snapshot must not repopulate the old distance cache")
        XCTAssertNil(persisted.couple?.distance.displayMeters())
    }

    func testInvalidLocationSamplesAreNeverUploaded() async {
        let (client, state, directory) = setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        state.invalidSample = true
        _ = await client.refreshDistance()
        XCTAssertFalse(state.paths.contains("/widgetLocation"))
        let now = Date()
        for sample in [
            WidgetLocationSample(latitude: .nan, longitude: 0, horizontalAccuracy: 100, capturedAt: now),
            WidgetLocationSample(latitude: 0, longitude: 181, horizontalAccuracy: 100, capturedAt: now),
            WidgetLocationSample(latitude: 0, longitude: 0, horizontalAccuracy: -1, capturedAt: now),
            WidgetLocationSample(latitude: 0, longitude: 0, horizontalAccuracy: 100, capturedAt: now.addingTimeInterval(-121)),
            WidgetLocationSample(latitude: 0, longitude: 0, horizontalAccuracy: 100, capturedAt: now.addingTimeInterval(61))
        ] { XCTAssertFalse(sample.isUsable(at: now)) }
    }
}

/// Each HTTP callback and fixture mutation is locked; the only deliberately
/// suspended requests are released during cleanup, even after a failed assert.
private final class PausedDistanceRaceState: @unchecked Sendable {
    let authorization = DistanceRefreshState.credential()
    private let lock = NSLock()
    private let fixture = DistanceRefreshState()
    private let measuring: XCTestExpectation
    private let ordinaryStarted: XCTestExpectation
    private let ordinaryCancelled: XCTestExpectation
    private let freshRequested: XCTestExpectation
    private var measurement: CheckedContinuation<Void, Never>?
    private var measurementReleased = false
    private var held: (PausedDistanceRaceProtocol, Int, Data)?
    private var snapshots = 0

    init(measuring: XCTestExpectation, ordinaryStarted: XCTestExpectation,
         ordinaryCancelled: XCTestExpectation, freshRequested: XCTestExpectation) {
        self.measuring = measuring; self.ordinaryStarted = ordinaryStarted
        self.ordinaryCancelled = ordinaryCancelled; self.freshRequested = freshRequested
    }

    var paths: [String] { lock.withLock { fixture.paths } }

    func sample() async -> WidgetLocationSample? {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if measurementReleased { return true }
                measurement = continuation
                return false
            }
            measuring.fulfill()
            if resume { continuation.resume() }
        }
        return lock.withLock {
            fixture.consent = false // The other device paused while we measured.
            return fixture.sample()
        }
    }

    func start(_ loader: PausedDistanceRaceProtocol) {
        do {
            let action = try lock.withLock { () throws -> (Int, Data, Bool, Bool) in
                let (status, data) = try fixture.response(loader.request)
                guard loader.request.url?.path == "/widgetSnapshot" else { return (status, data, false, false) }
                snapshots += 1
                if snapshots == 2 {
                    held = (loader, status, data)
                    return (status, data, true, false)
                }
                return (status, data, false, snapshots == 3)
            }
            if action.2 { ordinaryStarted.fulfill(); return }
            if action.3 { freshRequested.fulfill() }
            loader.respond(status: action.0, data: action.1)
        } catch { loader.fail(error) }
    }

    func stopped(_ loader: PausedDistanceRaceProtocol) {
        let cancelledHeld = lock.withLock {
            guard held?.0 === loader else { return false }
            held = nil
            return true
        }
        if cancelledHeld { ordinaryCancelled.fulfill() }
    }

    func releaseMeasurement() {
        let continuation = lock.withLock {
            measurementReleased = true
            let continuation = measurement
            measurement = nil
            return continuation
        }
        continuation?.resume()
    }

    func releaseAll() {
        releaseMeasurement()
        let pending = lock.withLock {
            let pending = held
            held = nil
            return pending
        }
        if let pending { pending.0.respond(status: pending.1, data: pending.2) }
    }
}

private final class PausedDistanceRaceProtocol: URLProtocol {
    nonisolated(unsafe) static var state: PausedDistanceRaceState?
    private var loadingState: PausedDistanceRaceState?
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        loadingState = Self.state
        loadingState?.start(self)
    }
    override func stopLoading() {
        lock.withLock { stopped = true }
        loadingState?.stopped(self)
    }
    func respond(status: Int, data: Data) {
        guard lock.withLock({ !stopped }) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) {
        guard lock.withLock({ !stopped }) else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class DistanceRefreshState: @unchecked Sendable {
    // URLSession uses a serial delegate queue; sample() runs after its completed
    // snapshot request. Each test owns a fresh state and session.
    var authorization: WidgetAuthorization? = DistanceRefreshState.credential()
    var consent = true
    var suppliesSample = true
    var switchAccountDuringSample = false
    var pauseDuringSample = false
    var invalidSample = false
    var offlineAfterRejection = false
    var measurementCount = 0
    var paths: [String] = []
    var tokens: [String] = []
    var uploadedSample: [String: Any]?
    private var uploaded = false
    private var rejected = false

    static func credential(uid: String = "first-user") -> WidgetAuthorization {
        WidgetAuthorization(token: String(repeating: uid == "first-user" ? "a" : "b", count: 43),
            expiresAt: Date().addingTimeInterval(3_600), baseURL: URL(string: "https://widget.example.test")!,
            uid: uid, pairID: "pair-test", pairEpoch: 1, deviceID: "device-test", apnsEnvironment: "production")
    }

    func sample() -> WidgetLocationSample? {
        measurementCount += 1
        if switchAccountDuringSample { authorization = Self.credential(uid: "second-user") }
        if pauseDuringSample { consent = false }
        guard suppliesSample else { return nil }
        return WidgetLocationSample(latitude: invalidSample ? 91 : -31.4, longitude: -64.2,
                                    horizontalAccuracy: 100, capturedAt: Date())
    }

    func response(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path
        paths.append(path)
        tokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        if path == "/widgetLocation" {
            if let body = request.httpBody { uploadedSample = try JSONSerialization.jsonObject(with: body) as? [String: Any] }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                uploadedSample = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            guard consent else { rejected = true; return (403, Data()) }
            uploaded = true
            return (200, Data("{}".utf8))
        }
        if rejected && offlineAfterRejection { throw URLError(.notConnectedToInternet) }
        let date = Date().addingTimeInterval(uploaded ? 0 : -3_600)
        var result: [String: Any] = [
            "schemaVersion": 1, "pairId": "pair-test", "pairEpoch": 1,
            "generatedAt": Date().timeIntervalSince1970 * 1_000,
            "validUntil": Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000,
            "profiles": [["uid": "first-user", "displayName": "Perfil ficticio A"],
                         ["uid": "partner", "displayName": "Perfil ficticio B"]],
            "distance": ["status": consent ? (uploaded ? "available" : "stale") : "disabled",
                         "meters": consent ? (uploaded ? 500 : 2_000) : NSNull(),
                         "updatedAt": consent ? date.timeIntervalSince1970 * 1_000 : NSNull(),
                         "accuracyMeters": consent ? 200 : NSNull()]
        ]
        if consent { result["locationAccess"] = ["consentVersion": 3] }
        return (200, try JSONSerialization.data(withJSONObject: result))
    }
}

private final class DistanceRefreshProtocol: URLProtocol {
    nonisolated(unsafe) static var state: DistanceRefreshState?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state!.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
