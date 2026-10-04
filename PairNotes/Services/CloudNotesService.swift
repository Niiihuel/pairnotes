import Foundation
import PairNotesCore

extension AppServices {
    func publish(operation: OutboxOperation) async throws -> RemoteNote {
        let client = try requireClient()
        let context = operation.context
        try checkPublicationContext(context)
        try operation.archive.validateIntegrity()
        let archive = operation.archive
        var assets: [(role: String, bytes: Data, hash: String, contentType: String)] = [
            ("source", archive.source.data, archive.source.revisionHash, "application/octet-stream")
        ]
        for kind in RenderKind.allCases {
            guard let image = archive.image(for: kind) else { throw LocalStoreError.missingRender }
            assets.append((kind.rawValue, image.pngData, image.imageHash, "image/png"))
        }
        let noteID = operation.id.uuidString.lowercased()
        let response = try await call("createUploadSession", [
            "pairId": context.pairID, "pairEpoch": context.pairEpoch,
            "idempotencyKey": noteID, "noteId": noteID,
            "revision": archive.document.revision, "revisionHash": archive.document.revisionHash,
            "assets": assets.map { ["role": $0.role, "sha256": $0.hash, "byteCount": $0.bytes.count, "contentType": $0.contentType] as [String: Any] }
        ])
        try checkPublicationContext(context)
        guard let sessionID = response["sessionId"] as? String,
              let paths = response["paths"] as? [String: String], response["noteId"] as? String == noteID,
              let published = response["published"] as? Bool else { throw ServiceError.invalidResponse }
        if !published {
            for asset in assets {
                try checkPublicationContext(context)
                guard let path = paths[asset.role], path == "tmp/\(context.authorID)/\(sessionID)/\(asset.role)" else {
                    throw ServiceError.invalidResponse
                }
                // The authenticated server implements create-only PUT and verifies
                // the complete bytes before accepting reuse on an outbox retry.
                _ = try await client.authenticatedData(path: "upload", method: "PUT", query: [
                    URLQueryItem(name: "sessionId", value: sessionID), URLQueryItem(name: "role", value: asset.role)
                ], body: asset.bytes, headers: ["Content-Type": asset.contentType, "X-Content-SHA256": asset.hash])
                try checkPublicationContext(context)
            }
        }
        // Upload completion alone is never represented as Sent.
        try checkPublicationContext(context)
        let final = try await call("finalizeNote", ["pairId": context.pairID, "pairEpoch": context.pairEpoch, "sessionId": sessionID])
        try checkPublicationContext(context)
        guard let data = final["note"] as? [String: Any] else { throw ServiceError.invalidResponse }
        let note = try decodeRemoteNote(data)
        try note.validate(for: context)
        guard note.id == noteID, note.revision == archive.document.revision,
              note.revisionHash == archive.document.revisionHash else { throw LocalStoreError.inconsistentRevision }
        return note
    }

    func timeline(after cursor: TimelineCursor? = nil) async throws -> TimelinePage {
        let uid = try requireUID()
        guard let pair = membership else { throw ServiceError.noPair }
        var payload: [String: Any] = ["pairId": pair.id, "pairEpoch": pair.pairEpoch, "limit": 30]
        if let cursor {
            payload["cursor"] = ["publishedAt": cursor.serverPublishedAt.timeIntervalSince1970 * 1_000, "noteId": cursor.noteID]
        }
        let result = try await call("timeline", payload)
        try checkPair(uid: uid, pair: pair)
        guard let records = result["notes"] as? [[String: Any]] else { throw ServiceError.invalidResponse }
        let notes = try records.map { try decodeRemoteNote($0) }
        guard notes.allSatisfy({ $0.pairID == pair.id && $0.pairEpoch == pair.pairEpoch }) else {
            throw ServiceError.sessionChanged
        }
        let next: TimelineCursor?
        if let cursor = result["nextCursor"] as? [String: Any] {
            guard let milliseconds = cursor["publishedAt"] as? NSNumber, let id = cursor["noteId"] as? String else { throw ServiceError.invalidResponse }
            next = TimelineCursor(serverPublishedAt: Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000), noteID: id)
        } else { next = nil }
        return TimelinePage(notes: notes, nextCursor: next)
    }

    func note(id: String) async throws -> RemoteNote {
        let uid = try requireUID()
        guard UUID(uuidString: id) != nil else { throw ServiceError.invalidResponse }
        guard let pair = membership else { throw ServiceError.noPair }
        let response = try await call("note", ["pairId": pair.id, "pairEpoch": pair.pairEpoch, "noteId": id])
        try checkPair(uid: uid, pair: pair)
        guard let data = response["note"] as? [String: Any] else { throw ServiceError.invalidResponse }
        let note = try decodeRemoteNote(data)
        guard note.pairID == pair.id, note.pairEpoch == pair.pairEpoch, note.id == id else {
            throw ServiceError.sessionChanged
        }
        return note
    }

    func latestReceivedNote() async throws -> RemoteNote? {
        let uid = try requireUID()
        guard let pair = membership else { throw ServiceError.noPair }
        let response = try await call("latestReceivedNote", ["pairId": pair.id, "pairEpoch": pair.pairEpoch])
        try checkPair(uid: uid, pair: pair)
        guard let data = response["note"] as? [String: Any] else {
            guard response["note"] is NSNull else { throw ServiceError.invalidResponse }
            return nil
        }
        let note = try decodeRemoteNote(data)
        guard note.pairID == pair.id, note.pairEpoch == pair.pairEpoch, note.recipientID == uid else { throw ServiceError.sessionChanged }
        return note
    }

    func image(path: String) async throws -> Data {
        let uid = try requireUID()
        guard let pair = membership else { throw ServiceError.noPair }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 5, pieces[0] == "pairs", String(pieces[1]) == pair.id,
              String(pieces[2]) == String(pair.pairEpoch), UUID(uuidString: String(pieces[3])) != nil,
              ["final", "widget", "thumbnail"].contains(String(pieces[4])) else {
            throw ServiceError.invalidResponse
        }
        let data = try await requireClient().authenticatedData(path: "image", query: [URLQueryItem(name: "path", value: path)])
        try checkPair(uid: uid, pair: pair)
        guard data.count <= 12 * 1024 * 1024 else { throw ServiceError.invalidResponse }
        return data
    }

    /// Only the detail screen calls this, after presenting the received note.
    func markViewed(note: RemoteNote) async throws {
        let uid = try requireUID()
        guard let pair = membership, note.recipientID == uid,
              note.pairID == pair.id, note.pairEpoch == pair.pairEpoch else { throw ServiceError.sessionChanged }
        _ = try await call("markNoteViewed", ["pairId": pair.id, "pairEpoch": pair.pairEpoch, "noteId": note.id])
    }

    func checkPublicationContext(_ context: PublicationContext) throws {
        try checkUID(context.authorID)
        guard let pair = membership, pair.id == context.pairID, pair.pairEpoch == context.pairEpoch,
              pair.partner.uid == context.recipientID else { throw ServiceError.sessionChanged }
    }

    private func checkPair(uid: String, pair: PairMembership) throws {
        try checkUID(uid)
        guard membership?.id == pair.id, membership?.pairEpoch == pair.pairEpoch else { throw ServiceError.sessionChanged }
    }

    private func decodeRemoteNote(_ data: [String: Any]) throws -> RemoteNote {
        guard let id = data["id"] as? String, let pairID = data["pairId"] as? String,
              let epoch = data["pairEpoch"] as? NSNumber, let authorID = data["authorId"] as? String,
              let recipientID = data["recipientId"] as? String, let revision = data["revision"] as? NSNumber,
              let hash = data["revisionHash"] as? String, let paths = data["paths"] as? [String: String],
              let source = paths["source"], let final = paths["final"], let widget = paths["widget"],
              let thumbnail = paths["thumbnail"] else { throw ServiceError.invalidResponse }
        guard let milliseconds = data["publishedAt"] as? NSNumber else { throw ServiceError.invalidResponse }
        let date = Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
        let note = RemoteNote(id: id, pairID: pairID, pairEpoch: epoch.uint64Value, authorID: authorID,
                              recipientID: recipientID, revision: revision.uint64Value, revisionHash: hash,
                              serverPublishedAt: date, assets: NoteAssetPaths(source: source, final: final, widget: widget, thumbnail: thumbnail))
        try note.validate()
        return note
    }
}
