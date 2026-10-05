import Foundation

/// Private, content-addressed image cache. Callers include account, endpoint and
/// pair generation in the key, and revalidate their session after every await.
public actor PrivateImageCache {
    private struct Entry: Codable { let bytes: Data; let digest: String; let storedAt: Date }
    private let directory: URL
    private let memory = NSCache<NSString, NSData>()
    private var pending: [String: (UUID, Task<Data, Error>)] = [:]
    private var generation: UInt64 = 0
    private let maximumBytes = 128 * 1024 * 1024

    public init(directory: URL) {
        self.directory = directory
        memory.totalCostLimit = 32 * 1024 * 1024
    }

    public func data(key: String, expectedSHA256: String? = nil,
                     load: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let identifier = ContentDigest.sha256(Data((key + ":" + (expectedSHA256 ?? "")).utf8))
        if let value = memory.object(forKey: identifier as NSString) { return value as Data }
        let url = directory.appendingPathComponent(identifier).appendingPathExtension("image")
        if let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
           entry.storedAt > Date().addingTimeInterval(-30 * 86_400),
           valid(entry.bytes, expected: expectedSHA256 ?? entry.digest) {
            memory.setObject(entry.bytes as NSData, forKey: identifier as NSString, cost: entry.bytes.count)
            return entry.bytes
        }
        if let flight = pending[identifier] { return try await flight.1.value }
        let captured = generation, requestID = UUID()
        let task = Task<Data, Error> {
            let bytes = try await load()
            guard self.valid(bytes, expected: expectedSHA256) else { throw LocalStoreError.corruptData }
            guard captured == self.generation, !Task.isCancelled else { throw CancellationError() }
            self.memory.setObject(bytes as NSData, forKey: identifier as NSString, cost: bytes.count)
            // A full disk must not prevent a successfully downloaded image from displaying.
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let entry = Entry(bytes: bytes, digest: ContentDigest.sha256(bytes), storedAt: Date())
            if let data = try? JSONEncoder().encode(entry) { try? data.write(to: url, options: .atomic) }
            self.trimDisk()
            return bytes
        }
        pending[identifier] = (requestID, task)
        defer { if pending[identifier]?.0 == requestID { pending[identifier] = nil } }
        return try await task.value
    }

    public func clear() {
        generation &+= 1
        for flight in pending.values { flight.1.cancel() }
        pending.removeAll()
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
    }

    private func valid(_ bytes: Data, expected: String?) -> Bool {
        !bytes.isEmpty && bytes.count <= 12 * 1024 * 1024 &&
            (expected == nil || ContentDigest.sha256(bytes) == expected)
    }

    private func trimDisk() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let files = urls.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, size, date) in files {
            if total <= maximumBytes && date > Date().addingTimeInterval(-30 * 86_400) { continue }
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
