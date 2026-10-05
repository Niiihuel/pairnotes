import Foundation

/// A date belongs to the couple's calendar, independently of publication time.
public struct SharedMemory: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let pairId: String
    public let pairEpoch: UInt64
    public let authorId: String
    public let title: String
    public let date: CoupleDate
    public let kind: String
    public let recursYearly: Bool
    public let body: String
    public let noteId: String?
    public let photo: CoupleAvatar?
    public let decoration: MemoryDecoration?
    public let createdAt: Date
    public let updatedAt: Date

    public func validate(for pair: PairMembership) throws {
        func validID(_ value: String) -> Bool {
            (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        guard validID(id), pairId == pair.id, pairEpoch == pair.pairEpoch,
              pair.memberIDs.contains(authorId), (1...120).contains(title.utf16.count), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf16.count <= 2_000, ["date", "memory"].contains(kind), noteId == nil || validID(noteId!),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt else {
            throw AccountDomainError.invalidContext
        }
        if let photo {
            guard UUID(uuidString: photo.id) != nil, photo.sha256.utf8.count == 64,
                  photo.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AccountDomainError.invalidContext
            }
        }
    }
}
