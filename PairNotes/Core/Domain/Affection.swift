import Foundation

public enum AffectionKind: String, Codable, CaseIterable, Sendable {
    case heart, hug, kiss
    public var symbol: String {
        switch self { case .heart: return "❤️"; case .hug: return "🫂"; case .kiss: return "😘" }
    }
    public var title: String {
        switch self { case .heart: return "Un corazón"; case .hug: return "Un abrazo"; case .kiss: return "Un beso" }
    }
}
public struct CoupleGesture: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let authorId: String
    public let recipientId: String
    public let kind: AffectionKind
    public let replyTo: String?
    public let sentAt: Date
    public func validate(memberIDs: [String]) throws {
        guard memberIDs.contains(authorId), memberIDs.contains(recipientId), authorId != recipientId,
              !id.isEmpty, id.utf8.count <= 128, sentAt.timeIntervalSince1970.isFinite else { throw LocalStoreError.corruptData }
    }
}
public struct DrawingReaction: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let authorId: String
    public let noteId: String
    public let kind: String
    public let reply: String
    public let updatedAt: Date
    public var symbol: String { ["heart": "❤️", "hug": "🫂", "sparkles": "✨"][kind] ?? "" }
}
public struct LetterAsset: Codable, Equatable, Sendable {
    public let id: String
    public let sha256: String
    public let duration: Double?
}
public struct TimeCapsuleLetter: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let authorId: String
    public let recipientId: String
    public let status: String
    public let opensAt: Date
    public let createdAt: Date
    public let openedAt: Date?
    /// Authoritative server permission, never inferred from the device clock.
    public let canOpen: Bool
    public let title: String?
    public let body: String?
    public let noteId: String?
    public let photo: LetterAsset?
    public let drawing: LetterAsset?
    public let audio: LetterAsset?

    public func validate(uid: String, memberIDs: [String]) throws {
        guard memberIDs.contains(authorId), memberIDs.contains(recipientId), authorId != recipientId,
              memberIDs.contains(uid), !id.isEmpty, id.utf8.count <= 128,
              ["draft", "sealed"].contains(status), status != "draft" || authorId == uid,
              opensAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970.isFinite,
              title.map({ !$0.isEmpty && $0.utf16.count <= 120 }) ?? true,
              body.map({ $0.utf16.count <= 6000 }) ?? true else { throw LocalStoreError.corruptData }
        if uid != authorId && !canOpen {
            guard title == nil, body == nil, photo == nil, drawing == nil, audio == nil, noteId == nil else { throw LocalStoreError.corruptData }
        }
        if canOpen && status != "sealed" { throw LocalStoreError.corruptData }
        for asset in [photo, drawing, audio].compactMap({ $0 }) {
            guard UUID(uuidString: asset.id) != nil, asset.sha256.utf8.count == 64,
                  asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw LocalStoreError.corruptData }
        }
        if let audio { guard let duration = audio.duration, duration.isFinite, duration > 0, duration <= 60 else { throw LocalStoreError.corruptData } }
    }
}
