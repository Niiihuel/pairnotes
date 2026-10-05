import Foundation
import XCTest
@testable import PairNotesCore

final class PrivateImageCacheTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMemoryAndDiskCacheSurviveOfflineWithoutDownloadingAgain() async throws {
        let root = directory(), bytes = Data("private-photo".utf8)
        let cache = PrivateImageCache(directory: root)
        let first = try await cache.data(key: "account:pair:avatar", expectedSHA256: ContentDigest.sha256(bytes)) { bytes }
        XCTAssertEqual(first, bytes)
        let memory = try await cache.data(key: "account:pair:avatar", expectedSHA256: ContentDigest.sha256(bytes)) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(memory, bytes)
        let reopened = PrivateImageCache(directory: root)
        let disk = try await reopened.data(key: "account:pair:avatar", expectedSHA256: ContentDigest.sha256(bytes)) { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(disk, bytes)
    }

    func testOtherAccountAndNewPhotoCannotReuseOldPixels() async throws {
        let cache = PrivateImageCache(directory: directory()), bytes = Data("old-photo".utf8)
        _ = try await cache.data(key: "account-a:pair:avatar", expectedSHA256: ContentDigest.sha256(bytes)) { bytes }
        for (key, hash) in [("account-b:pair:avatar", ContentDigest.sha256(bytes)),
                            ("account-a:pair:avatar", ContentDigest.sha256(Data("new-photo".utf8)))] {
            do {
                _ = try await cache.data(key: key, expectedSHA256: hash) { throw URLError(.notConnectedToInternet) }
                XCTFail("Must never display a photo from another account or revision")
            } catch { }
        }
    }

    func testConcurrentViewsShareOneDownload() async throws {
        let cache = PrivateImageCache(directory: directory()), loader = ImageCacheLoader()
        async let first = cache.data(key: "same-photo") { try await loader.load() }
        async let second = cache.data(key: "same-photo") { try await loader.load() }
        let results = try await [first, second]
        XCTAssertEqual(results[0], results[1])
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
    }

    func testClearCancelsLateDownloadAndRemovesDiskFallback() async throws {
        let root = directory(), cache = PrivateImageCache(directory: root)
        let started = expectation(description: "download started")
        let task = Task {
            try await cache.data(key: "photo") {
                started.fulfill()
                // Deliberately ignore cancellation to model a late network completion.
                try? await Task.sleep(nanoseconds: 100_000_000)
                return Data("late-private-photo".utf8)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await cache.clear()
        do { _ = try await task.value; XCTFail("A revoked request must not repopulate cache") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testHashMismatchIsNeverPersisted() async throws {
        let root = directory(), cache = PrivateImageCache(directory: root)
        do {
            _ = try await cache.data(key: "photo", expectedSHA256: String(repeating: "0", count: 64)) { Data("wrong".utf8) }
            XCTFail("Corrupt response must be rejected")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

private actor ImageCacheLoader {
    private(set) var calls = 0
    func load() async throws -> Data {
        calls += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        return Data("downloaded-photo".utf8)
    }
}
