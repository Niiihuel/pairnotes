import Foundation

public struct NoteWidgetSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let noteID: UUID
    public let revision: UInt64
    public let revisionHash: String
    public let authorName: String
    public let updatedAt: Date
    public let pngData: Data
    public let imageHash: String

    public init(
        noteID: UUID, revision: UInt64, revisionHash: String,
        authorName: String, updatedAt: Date, pngData: Data
    ) {
        self.schemaVersion = 1
        self.noteID = noteID
        self.revision = revision
        self.revisionHash = revisionHash
        self.authorName = authorName
        self.updatedAt = updatedAt
        self.pngData = pngData
        self.imageHash = ContentDigest.sha256(pngData)
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw LocalStoreError.unsupportedVersion }
        guard revision > 0, revisionHash.count == 64,
              revisionHash.allSatisfy({ $0.isHexDigit }),
              !authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              updatedAt.timeIntervalSince1970.isFinite else {
            throw LocalStoreError.invalidDocument
        }
        guard !pngData.isEmpty, ContentDigest.sha256(pngData) == imageHash else {
            throw LocalStoreError.corruptData
        }
    }
}

public protocol WidgetSnapshotStoring: Sendable {
    func write(_ snapshot: NoteWidgetSnapshot) async throws
    func read() async throws -> NoteWidgetSnapshot?
    func clear() async throws
}

/// The app is the only writer; WidgetKit opens this store as a reader.
/// Atomic replacement of one JSON envelope prevents torn JSON/image pairs.
/// Data's JSON representation is local only, never a Firestore record.
public actor WidgetSnapshotStore: WidgetSnapshotStoring {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("note-widget.json") }

    public init(directory: URL) { self.directory = directory }

    public func write(_ snapshot: NoteWidgetSnapshot) throws {
        try snapshot.validate()
        if let existing = try read() {
            if snapshot == existing { return }
            guard snapshot.updatedAt >= existing.updatedAt else {
                throw LocalStoreError.obsoleteRevision
            }
            if snapshot.noteID == existing.noteID {
                guard snapshot.revision > existing.revision else {
                    throw LocalStoreError.obsoleteRevision
                }
            } else if snapshot.updatedAt == existing.updatedAt {
                throw LocalStoreError.obsoleteRevision
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    public func read() throws -> NoteWidgetSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let bytes = try Data(contentsOf: fileURL)
        let snapshot: NoteWidgetSnapshot
        do {
            snapshot = try JSONDecoder().decode(NoteWidgetSnapshot.self, from: bytes)
        } catch {
            throw LocalStoreError.corruptData
        }
        try snapshot.validate()
        return snapshot
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
