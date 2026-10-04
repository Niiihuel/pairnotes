import Foundation

public protocol DraftStore: Sendable {
    func save(_ archive: DraftArchive) async throws
    func load(id: UUID) async throws -> DraftArchive?
}

/// M0 single-writer store. Share one actor per directory in the app.
/// One atomic archive contains the manifest, opaque source and its derivatives.
/// A SwiftData index and multi-process writers are outside this prototype.
public actor FileDraftStore: DraftStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func save(_ archive: DraftArchive) throws {
        try archive.validateIntegrity()
        guard archive.document.isEditable else { throw LocalStoreError.unsupportedVersion }
        if let existing = try load(id: archive.document.id) {
            // Incompatible and corrupt existing files are preserved, even if the
            // caller supplies an older manifest with a larger revision number.
            guard existing.document.isEditable else { throw LocalStoreError.unsupportedVersion }
            guard archive.document.revision > existing.document.revision else {
                throw LocalStoreError.obsoleteRevision
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(archive)
        try bytes.write(to: fileURL(id: archive.document.id), options: .atomic)
    }

    /// Future editor/schema versions remain readable as immutable preview data.
    public func load(id: UUID) throws -> DraftArchive? {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url)
        let archive: DraftArchive
        do {
            archive = try JSONDecoder().decode(DraftArchive.self, from: bytes)
        } catch {
            throw LocalStoreError.corruptData
        }
        guard archive.document.id == id else { throw LocalStoreError.invalidDocument }
        try archive.validateIntegrity()
        return archive
    }

    private func fileURL(id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("pairnote")
    }
}
