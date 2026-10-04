import Foundation

public struct UserProfile: Codable, Equatable, Identifiable, Sendable {
    /// Production will use a Firebase UID; mock IDs are explicitly fictitious.
    public let id: String
    public let displayName: String
    public let avatarSymbol: String

    public init(id: String, displayName: String, avatarSymbol: String) {
        self.id = id
        self.displayName = displayName
        self.avatarSymbol = avatarSymbol
    }
}

/// UI fixtures are separate from server-confirmed publications.
public struct DemoNote: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String
    public let author: UserProfile
    public let createdAt: Date

    public init(id: UUID, title: String, message: String, author: UserProfile, createdAt: Date) {
        self.id = id
        self.title = title
        self.message = message
        self.author = author
        self.createdAt = createdAt
    }
}

/// Frozen value returned only after a future backend confirms publication.
/// Editing a received note must create a new draft with a new identity.
public struct PublishedNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let pairID: String
    public let pairEpoch: UInt64
    public let authorID: String
    public let recipientID: String
    public let serverPublishedAt: Date
    public let archive: DraftArchive

    public init(
        id: UUID, pairID: String, pairEpoch: UInt64, authorID: String,
        recipientID: String, serverPublishedAt: Date, archive: DraftArchive
    ) {
        self.id = id
        self.pairID = pairID
        self.pairEpoch = pairEpoch
        self.authorID = authorID
        self.recipientID = recipientID
        self.serverPublishedAt = serverPublishedAt
        self.archive = archive
    }
}

public enum LocationSharingState: String, Codable, Sendable {
    case notRequested, denied, paused, unavailable
}

public protocol IdentityProvider: Sendable {
    func currentUser() async -> UserProfile?
}

public protocol NotesRepository: Sendable {
    func notes() async -> [DemoNote]
}

public protocol LocationProvider: Sendable {
    func state() async -> LocationSharingState
}

/// Contract only: no uploads, accounts, or claims of delivery in M0/M1.
public protocol NotePublisher: Sendable {
    func publish(_ archive: DraftArchive, idempotencyKey: UUID) async throws -> PublishedNote
}

/// Apple rendering stays in its platform adapter, outside the pure domain.
public protocol NoteRenderer: Sendable {
    func render(document: NoteDocument, source: NativeSource) async throws -> [RenderedImage]
}
