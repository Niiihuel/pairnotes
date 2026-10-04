import Foundation

public struct UserProfile: Codable, Equatable, Identifiable, Sendable {
    /// Production uses the backend's opaque UID; mock IDs are explicitly fictitious.
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

/// Only a server-confirmed immutable record completes a durable operation.
public protocol NotePublisher: Sendable {
    func publish(_ operation: OutboxOperation) async throws -> RemoteNote
}

/// Apple rendering stays in its platform adapter, outside the pure domain.
public protocol NoteRenderer: Sendable {
    func render(document: NoteDocument, source: NativeSource) async throws -> [RenderedImage]
}
