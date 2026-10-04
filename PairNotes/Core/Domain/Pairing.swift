import Foundation

public struct SessionIdentity: Codable, Equatable, Sendable {
    public let uid: String
    public let displayName: String

    public init(uid: String, displayName: String) {
        self.uid = uid
        self.displayName = displayName
    }
}

/// A server-confirmed relationship. Local validation catches inconsistent responses;
/// it does not replace server authorization or grant access to another member.
public struct PairMembership: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let memberIDs: [String]
    public let pairEpoch: UInt64
    public let partner: SessionIdentity

    public init(id: String, memberIDs: [String], pairEpoch: UInt64, partner: SessionIdentity) {
        self.id = id
        self.memberIDs = memberIDs
        self.pairEpoch = pairEpoch
        self.partner = partner
    }

    public func validate(for uid: String) throws {
        guard !id.isEmpty, !uid.isEmpty, pairEpoch > 0,
              memberIDs.count == 2, Set(memberIDs).count == 2,
              memberIDs.allSatisfy({ !$0.isEmpty }), memberIDs.contains(uid),
              partner.uid != uid, memberIDs.contains(partner.uid) else {
            throw AccountDomainError.invalidMembership
        }
    }

    public func publicationContext(for uid: String) throws -> PublicationContext {
        try validate(for: uid)
        return PublicationContext(authorID: uid, pairID: id, pairEpoch: pairEpoch,
                                  recipientID: partner.uid)
    }
}

/// The opaque secret belongs only in the explicit invitation flow, never logs.
public struct PairInvite: Equatable, Sendable {
    public let token: String
    public let expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool { date >= expiresAt }

    /// One text item keeps messaging apps from joining a separate item and message.
    public var shareMessage: String {
        "\(InvitationCode.messageIntroduction)\n\(token)\n\n\(InvitationCode.messageInstructions)"
    }
}

/// Accept only the code or messages produced by PairNotes. Never extract a secret
/// from an arbitrary URL or repair a damaged code; the server validates its use.
public enum InvitationCode {
    fileprivate static let messageIntroduction = "Te invito a PairNotes.\n\nCódigo de invitación:"
    fileprivate static let messageInstructions = "Abrí PairNotes → Nosotros → Tengo una invitación y pegá este mensaje."
    private static let legacyInstructions = "Pegá este código en Nosotros para vincular nuestras cuentas."

    public static func parse(_ input: String) -> String? {
        // Bound pasted content before splitting it, including multibyte input.
        guard input.utf8.prefix(2_049).count <= 2_048 else { return nil }
        let words = components(input)
        if words.count == 1 { return validCode(words[0]) }

        let introduction = components(messageIntroduction)
        let instructions = components(messageInstructions)
        if words.count == introduction.count + 1 + instructions.count,
           Array(words.prefix(introduction.count)) == introduction,
           Array(words.suffix(instructions.count)) == instructions {
            return validCode(words[introduction.count])
        }

        let legacy = components(legacyInstructions)
        if words.count == 1 + legacy.count, Array(words.dropFirst()) == legacy {
            return validCode(words[0])
        }
        return nil
    }

    private static func components(_ text: String) -> [Substring] {
        text.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
    }

    private static func validCode(_ code: Substring) -> String? {
        guard code.utf8.count == 43, code.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
                (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { return nil }
        return String(code)
    }
}

public protocol PairingService: Sendable {
    func currentPair() async throws -> PairMembership?
    func createInvite() async throws -> PairInvite
    func acceptInvite(token: String) async throws -> PairMembership
    func closePair(pairID: String, pairEpoch: UInt64) async throws
}

public enum AccountDomainError: Error, Equatable {
    case invalidMembership
    case invalidPublication
    case invalidContext
    case accountMismatch
    case staleContext
    case invalidTransition
    case operationNotFound
    case conflictingOperation
}

/// Capture this when the person taps Send. Never silently retarget a queued note.
public struct PublicationContext: Codable, Equatable, Sendable {
    public let authorID: String
    public let pairID: String
    public let pairEpoch: UInt64
    public let recipientID: String

    public init(authorID: String, pairID: String, pairEpoch: UInt64, recipientID: String) {
        self.authorID = authorID
        self.pairID = pairID
        self.pairEpoch = pairEpoch
        self.recipientID = recipientID
    }

    public func validate() throws {
        guard !authorID.isEmpty, !recipientID.isEmpty, authorID != recipientID,
              !pairID.isEmpty, pairEpoch > 0 else { throw AccountDomainError.invalidContext }
    }
}
