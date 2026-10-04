import Foundation

/// Private Storage object paths, not public download URLs or inline image data.
public struct NoteAssetPaths: Codable, Equatable, Sendable {
    public let source: String
    public let final: String
    public let widget: String
    public let thumbnail: String

    public init(source: String, final: String, widget: String, thumbnail: String) {
        self.source = source
        self.final = final
        self.widget = widget
        self.thumbnail = thumbnail
    }

    public func path(for kind: RenderKind) -> String {
        switch kind {
        case .final: return final
        case .widget: return widget
        case .thumbnail: return thumbnail
        }
    }
}

/// Immutable metadata returned after the server has finalized all four assets.
/// Draft bytes remain in private local archives and Storage, never Firestore.
public struct RemoteNote: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let pairID: String
    public let pairEpoch: UInt64
    public let authorID: String
    public let recipientID: String
    public let revision: UInt64
    public let revisionHash: String
    public let serverPublishedAt: Date
    public let assets: NoteAssetPaths

    public init(id: String, pairID: String, pairEpoch: UInt64, authorID: String,
                recipientID: String, revision: UInt64, revisionHash: String,
                serverPublishedAt: Date, assets: NoteAssetPaths) {
        self.id = id
        self.pairID = pairID
        self.pairEpoch = pairEpoch
        self.authorID = authorID
        self.recipientID = recipientID
        self.revision = revision
        self.revisionHash = revisionHash
        self.serverPublishedAt = serverPublishedAt
        self.assets = assets
    }

    public var cursor: TimelineCursor {
        TimelineCursor(serverPublishedAt: serverPublishedAt, noteID: id)
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil, !pairID.isEmpty, !pairID.contains("/"),
              pairID != ".", pairID != "..", pairEpoch > 0,
              !authorID.isEmpty, !recipientID.isEmpty, authorID != recipientID,
              revision > 0, revisionHash.count == 64,
              revisionHash.allSatisfy({ $0.isHexDigit }),
              serverPublishedAt.timeIntervalSince1970.isFinite else {
            throw AccountDomainError.invalidPublication
        }
        let prefix = "pairs/\(pairID)/\(pairEpoch)/\(id)/"
        guard assets.source == prefix + "source", assets.final == prefix + "final",
              assets.widget == prefix + "widget", assets.thumbnail == prefix + "thumbnail" else {
            throw AccountDomainError.invalidPublication
        }
    }

    public func validate(for context: PublicationContext) throws {
        try validate()
        guard pairID == context.pairID, pairEpoch == context.pairEpoch,
              authorID == context.authorID, recipientID == context.recipientID else {
            throw AccountDomainError.staleContext
        }
    }
}

public struct TimelineCursor: Codable, Equatable, Sendable {
    public let serverPublishedAt: Date
    public let noteID: String

    public init(serverPublishedAt: Date, noteID: String) {
        self.serverPublishedAt = serverPublishedAt
        self.noteID = noteID
    }
}

public struct TimelinePage: Equatable, Sendable {
    public let notes: [RemoteNote]
    public let nextCursor: TimelineCursor?

    public init(notes: [RemoteNote], nextCursor: TimelineCursor?) {
        self.notes = notes
        self.nextCursor = nextCursor
    }
}

public struct TimelineDay: Equatable, Identifiable, Sendable {
    /// Start of day in the caller's calendar/time zone, including DST boundaries.
    public let id: Date
    public let notes: [RemoteNote]
}

public enum NoteTimeline {
    /// Stable ordering matches the backend's descending (server date, note ID) cursor.
    public static func sorted(_ notes: [RemoteNote]) -> [RemoteNote] {
        notes.sorted {
            if $0.serverPublishedAt != $1.serverPublishedAt {
                return $0.serverPublishedAt > $1.serverPublishedAt
            }
            return $0.id > $1.id
        }
    }

    public static func groupedByDay(_ notes: [RemoteNote], calendar: Calendar) -> [TimelineDay] {
        let groups = Dictionary(grouping: sorted(notes)) { calendar.startOfDay(for: $0.serverPublishedAt) }
        return groups.keys.sorted(by: >).map { TimelineDay(id: $0, notes: groups[$0]!) }
    }

    /// Merge overlapping pagination/live-update results without duplicate cards.
    /// Published records are immutable; conflicting IDs are rejected explicitly.
    public static func merging(_ existing: [RemoteNote], _ incoming: [RemoteNote]) throws -> [RemoteNote] {
        var byID = [String: RemoteNote]()
        for note in existing + incoming {
            try note.validate()
            if let previous = byID[note.id], previous != note {
                throw AccountDomainError.conflictingOperation
            }
            byID[note.id] = note
        }
        return sorted(Array(byID.values))
    }
}
