import Foundation

public enum DraftAccountScope: Equatable, Sendable {
    case guest
    case user(uid: String)

    /// Account IDs never become file paths. Guest data is a separate namespace;
    /// signing in does not import it into an account without explicit consent.
    var directoryName: String {
        switch self {
        case .guest: return "guest"
        case .user(let uid): return "account-" + ContentDigest.sha256(Data(uid.utf8))
        }
    }

    func validate() throws {
        if case .user(let uid) = self, uid.isEmpty { throw AccountDomainError.accountMismatch }
    }
}

public struct DraftSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let revision: UInt64
    public let revisionHash: String
}

/// Share one actor per account directory. The small index is the commit point:
/// write immutable revision bytes first, then atomically replace the index.
/// Interrupted writes can leave an unreferenced revision, never a partial draft.
/// Unlike the M0 scratch store, this catalog keeps multiple private drafts.
public actor DraftCatalogStore {
    private struct Index: Codable {
        let schemaVersion: Int
        let namespace: String
        var drafts: [DraftSummary]
    }

    private let directory: URL
    private let account: DraftAccountScope
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, account: DraftAccountScope) {
        self.account = account
        self.directory = directory.appendingPathComponent(account.directoryName, isDirectory: true)
    }

    public func list() throws -> [DraftSummary] {
        try readIndex().drafts.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString > $1.id.uuidString
        }
    }

    public func load(id: UUID) throws -> DraftArchive? {
        guard let summary = try readIndex().drafts.first(where: { $0.id == id }) else { return nil }
        return try load(summary)
    }

    @discardableResult
    public func save(_ archive: DraftArchive, title: String = "Sin título", at date: Date = Date()) throws -> DraftSummary {
        try archive.validateIntegrity()
        guard archive.document.isEditable else { throw LocalStoreError.unsupportedVersion }
        guard date.timeIntervalSince1970.isFinite else { throw LocalStoreError.invalidDocument }
        var index = try readIndex()
        let id = archive.document.id
        if let existing = index.drafts.first(where: { $0.id == id }) {
            let oldArchive = try load(existing)
            guard oldArchive.document.isEditable else { throw LocalStoreError.unsupportedVersion }
            guard archive.document.revision > existing.revision else { throw LocalStoreError.obsoleteRevision }
        }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let summary = DraftSummary(id: id, title: cleanTitle.isEmpty ? "Sin título" : cleanTitle,
                                   updatedAt: date, revision: archive.document.revision,
                                   revisionHash: archive.document.revisionHash)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = archiveURL(summary)
        // A crash after the archive write can leave a revision without an index.
        // Reuse only byte-identical data; never overwrite unknown/corrupt bytes.
        if FileManager.default.fileExists(atPath: url.path) {
            guard try decodeArchive(Data(contentsOf: url)) == archive else {
                throw LocalStoreError.inconsistentRevision
            }
        } else {
            try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        }
        index.drafts.removeAll { $0.id == id }
        index.drafts.append(summary)
        try writeIndex(index)
        return summary
    }

    public func remove(id: UUID) throws {
        var index = try readIndex()
        guard index.drafts.contains(where: { $0.id == id }) else { return }
        index.drafts.removeAll { $0.id == id }
        try writeIndex(index)
        // Only our exact UUID-prefix revision files are removed after commit.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(id.uuidString + "-") && url.pathExtension == "pairnote" {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Explicitly copying a note retains its native source but creates a new draft identity.
    public func importCopy(_ archive: DraftArchive, title: String = "Copia", at date: Date = Date()) throws -> DraftArchive {
        try archive.validateIntegrity()
        guard archive.document.isEditable else { throw LocalStoreError.unsupportedVersion }
        let id = UUID()
        let original = archive.document
        let document = NoteDocument(id: id, schemaVersion: original.schemaVersion,
                                    editorKind: original.editorKind, minimumEditorVersion: original.minimumEditorVersion,
                                    canvasSize: original.canvasSize, colorSpace: original.colorSpace,
                                    assetIDs: original.assetIDs, revision: 1, revisionHash: original.revisionHash)
        let source = NativeSource(documentID: id, revision: 1, revisionHash: original.revisionHash,
                                  data: archive.source.data)
        let renders = archive.renders.map {
            RenderedImage(kind: $0.kind, documentID: id, revision: 1,
                          revisionHash: original.revisionHash, pngData: $0.pngData)
        }
        let copy = DraftArchive(document: document, source: source, renders: renders)
        try save(copy, title: title, at: date)
        return copy
    }

    private func readIndex() throws -> Index {
        try account.validate()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return Index(schemaVersion: 1, namespace: account.directoryName, drafts: [])
        }
        let index: Index
        do { index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)) }
        catch { throw LocalStoreError.corruptData }
        guard index.schemaVersion == 1 else { throw LocalStoreError.unsupportedVersion }
        guard index.namespace == account.directoryName,
              Set(index.drafts.map(\.id)).count == index.drafts.count,
              index.drafts.allSatisfy({ $0.revision > 0 && $0.updatedAt.timeIntervalSince1970.isFinite &&
                  $0.revisionHash.count == 64 && $0.revisionHash.allSatisfy({ $0.isHexDigit }) }) else {
            throw LocalStoreError.corruptData
        }
        return index
    }

    private func writeIndex(_ index: Index) throws {
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func archiveURL(_ summary: DraftSummary) -> URL {
        directory.appendingPathComponent("\(summary.id.uuidString)-\(summary.revision).pairnote")
    }

    private func load(_ summary: DraftSummary) throws -> DraftArchive {
        let archive: DraftArchive
        do { archive = try decodeArchive(Data(contentsOf: archiveURL(summary))) }
        catch { throw LocalStoreError.corruptData }
        guard archive.document.id == summary.id, archive.document.revision == summary.revision,
              archive.document.revisionHash == summary.revisionHash else {
            throw LocalStoreError.inconsistentRevision
        }
        return archive
    }

    private func decodeArchive(_ data: Data) throws -> DraftArchive {
        let archive: DraftArchive
        do { archive = try JSONDecoder().decode(DraftArchive.self, from: data) }
        catch { throw LocalStoreError.corruptData }
        try archive.validateIntegrity()
        return archive
    }
}
