import Foundation

/// Unknown values remain decodable so a newer document can retain its preview.
public struct EditorKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let paper = EditorKind(rawValue: "paper-v1")
    public static let studio = EditorKind(rawValue: "studio-v1")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CanvasSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public static let standard = CanvasSize(width: 1536, height: 1536)
}

public struct NoteDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentPaperEditorVersion = 1

    public let id: UUID
    public let schemaVersion: Int
    public let editorKind: EditorKind
    public let minimumEditorVersion: Int
    public let canvasSize: CanvasSize
    public let colorSpace: String
    public let assetIDs: [UUID]
    public let revision: UInt64
    /// SHA-256 of the opaque editable source. This is not an authorization token.
    public let revisionHash: String

    public init(
        id: UUID, schemaVersion: Int = currentSchemaVersion,
        editorKind: EditorKind = .paper,
        minimumEditorVersion: Int = currentPaperEditorVersion,
        canvasSize: CanvasSize = .standard, colorSpace: String = "sRGB",
        assetIDs: [UUID] = [], revision: UInt64, revisionHash: String
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.editorKind = editorKind
        self.minimumEditorVersion = minimumEditorVersion
        self.canvasSize = canvasSize
        self.colorSpace = colorSpace
        self.assetIDs = assetIDs
        self.revision = revision
        self.revisionHash = revisionHash
    }

    /// Rendering a stored preview never grants permission to overwrite its source.
    public var isEditable: Bool {
        schemaVersion == Self.currentSchemaVersion && editorKind == .paper &&
        (1...Self.currentPaperEditorVersion).contains(minimumEditorVersion) &&
        colorSpace == "sRGB"
    }
}

public struct NativeSource: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let revision: UInt64
    public let revisionHash: String
    /// Native bytes (including mixed content) are kept without interpreting them.
    public let data: Data

    public init(documentID: UUID, revision: UInt64, revisionHash: String, data: Data) {
        self.documentID = documentID
        self.revision = revision
        self.revisionHash = revisionHash
        self.data = data
    }
}

public enum RenderKind: String, Codable, CaseIterable, Sendable {
    case final, widget, thumbnail
}

public struct RenderedImage: Codable, Equatable, Sendable {
    public let kind: RenderKind
    public let documentID: UUID
    public let revision: UInt64
    public let revisionHash: String
    public let pngData: Data
    public let imageHash: String

    public init(
        kind: RenderKind, documentID: UUID, revision: UInt64,
        revisionHash: String, pngData: Data
    ) {
        self.kind = kind
        self.documentID = documentID
        self.revision = revision
        self.revisionHash = revisionHash
        self.pngData = pngData
        self.imageHash = ContentDigest.sha256(pngData)
    }
}

public struct DraftArchive: Codable, Equatable, Sendable {
    public let document: NoteDocument
    public let source: NativeSource
    public let renders: [RenderedImage]

    public init(document: NoteDocument, source: NativeSource, renders: [RenderedImage]) {
        self.document = document
        self.source = source
        self.renders = renders
    }

    /// The caller must render all three images from this exact source capture.
    /// Core verifies byte integrity and revision labels, not visual equivalence.
    public static func make(
        id: UUID = UUID(), revision: UInt64, nativeData: Data,
        finalPNG: Data, widgetPNG: Data, thumbnailPNG: Data,
        canvasSize: CanvasSize = .standard
    ) throws -> DraftArchive {
        let hash = ContentDigest.sha256(nativeData)
        let document = NoteDocument(
            id: id, canvasSize: canvasSize, revision: revision, revisionHash: hash
        )
        let source = NativeSource(
            documentID: id, revision: revision, revisionHash: hash, data: nativeData
        )
        let renders = zip(RenderKind.allCases, [finalPNG, widgetPNG, thumbnailPNG]).map {
            RenderedImage(kind: $0.0, documentID: id, revision: revision,
                          revisionHash: hash, pngData: $0.1)
        }
        let archive = DraftArchive(document: document, source: source, renders: renders)
        try archive.validateIntegrity()
        return archive
    }

    public func image(for kind: RenderKind) -> RenderedImage? {
        renders.first { $0.kind == kind }
    }

    public func validateIntegrity() throws {
        guard document.revision > 0, document.canvasSize.width > 0,
              document.canvasSize.height > 0, !source.data.isEmpty,
              Set(document.assetIDs).count == document.assetIDs.count else {
            throw LocalStoreError.invalidDocument
        }
        guard source.documentID == document.id, source.revision == document.revision,
              source.revisionHash == document.revisionHash,
              ContentDigest.sha256(source.data) == document.revisionHash else {
            throw LocalStoreError.inconsistentRevision
        }
        guard renders.count == RenderKind.allCases.count,
              Set(renders.map(\.kind)) == Set(RenderKind.allCases) else {
            throw LocalStoreError.missingRender
        }
        for render in renders {
            guard render.documentID == document.id, render.revision == document.revision,
                  render.revisionHash == document.revisionHash else {
                throw LocalStoreError.inconsistentRevision
            }
            guard !render.pngData.isEmpty,
                  ContentDigest.sha256(render.pngData) == render.imageHash else {
                throw LocalStoreError.corruptData
            }
        }
    }
}

public enum LocalStoreError: Error, Equatable {
    case invalidDocument
    case inconsistentRevision
    case missingRender
    case corruptData
    case unsupportedVersion
    case obsoleteRevision
}
