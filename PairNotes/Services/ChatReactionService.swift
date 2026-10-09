import Foundation
import PairNotesCore

extension AppServices {
    func chatReactions(targets: [ChatReactionTarget]) async throws -> [ChatReaction] {
        try Task.checkCancellation()
        let uid = try requireUID(), pair = try requirePair()
        guard targets.count <= 100, Set(targets).count == targets.count else { throw ServiceError.invalidResponse }
        for target in targets { try target.validate() }
        if targets.isEmpty { return [] }
        let fields = targets.map { ["targetType": $0.type.rawValue, "targetId": $0.id] }
        let response = try await affectionCall("getChatReactions", ["targets": fields])
        try Task.checkCancellation()
        struct Response: Decodable { let reactions: [ChatReaction] }
        let value: Response = try decodeSpace(response)
        try ChatReaction.validate(value.reactions, targets: Set(targets), memberIDs: pair.memberIDs)
        try checkSpaceContext(uid: uid, pair: pair)
        return value.reactions
    }

    func setChatReaction(target: ChatReactionTarget, kind: ChatReactionKind?) async throws -> [ChatReaction] {
        try Task.checkCancellation()
        let uid = try requireUID(), pair = try requirePair()
        try target.validate()
        let response = try await affectionCall("setChatReaction", [
            "targetType": target.type.rawValue, "targetId": target.id,
            "kind": kind.map { $0.rawValue as Any } ?? NSNull()
        ])
        try Task.checkCancellation()
        struct Response: Decodable { let reaction: ChatReaction?; let reactions: [ChatReaction] }
        let value: Response = try decodeSpace(response)
        try ChatReaction.validate(value.reactions, targets: [target], memberIDs: pair.memberIDs)
        let own = value.reactions.first { $0.authorID == uid }
        guard own == value.reaction, own?.kind == kind else { throw ServiceError.invalidResponse }
        try checkSpaceContext(uid: uid, pair: pair)
        return value.reactions
    }
}
