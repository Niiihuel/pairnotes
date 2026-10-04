import Foundation

public enum OutboxStatus: String, Codable, Sendable {
    case queued, sending, failed, sent, cancelled
}

/// A frozen capture. Retrying uses this ID and these bytes even if the draft was edited.
public struct OutboxOperation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let archive: DraftArchive
    public let context: PublicationContext
    public let enqueuedAt: Date
    public private(set) var status: OutboxStatus
    public private(set) var attempts: Int
    public private(set) var failureCode: String?
    public private(set) var publishedNote: RemoteNote?

    public var idempotencyKey: UUID { id }

    fileprivate init(id: UUID, archive: DraftArchive, context: PublicationContext, enqueuedAt: Date) {
        self.id = id
        self.archive = archive
        self.context = context
        self.enqueuedAt = enqueuedAt
        status = .queued
        attempts = 0
    }

    fileprivate mutating func transition(to state: OutboxStatus, code: String? = nil, note: RemoteNote? = nil) {
        status = state
        failureCode = code
        publishedNote = note
        if state == .sending { attempts += 1 }
    }
}

/// One writer per account directory. Every state transition is an atomic file write.
/// Call recoverInterrupted once when restoring the account, before starting a sender.
/// The sender must revalidate session/context before each network operation; the server
/// independently checks membership and epoch during upload and finalization.
public actor DurableOutbox {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let accountUID: String
        let operation: OutboxOperation
    }

    private let directory: URL
    private let accountUID: String

    public init(directory: URL, accountUID: String) {
        self.accountUID = accountUID
        self.directory = directory.appendingPathComponent("account-" + ContentDigest.sha256(Data(accountUID.utf8)))
    }

    @discardableResult
    public func enqueue(archive: DraftArchive, context: PublicationContext,
                        idempotencyKey: UUID = UUID(), at date: Date = Date()) throws -> OutboxOperation {
        try validate(context)
        try archive.validateIntegrity()
        guard archive.document.isEditable else { throw LocalStoreError.unsupportedVersion }
        guard date.timeIntervalSince1970.isFinite else { throw LocalStoreError.invalidDocument }
        if let existing = try load(id: idempotencyKey) {
            guard existing.archive == archive, existing.context == context else {
                throw AccountDomainError.conflictingOperation
            }
            return existing
        }
        let operation = OutboxOperation(id: idempotencyKey, archive: archive, context: context, enqueuedAt: date)
        try write(operation)
        return operation
    }

    public func list() throws -> [OutboxOperation] {
        guard !accountUID.isEmpty else { throw AccountDomainError.accountMismatch }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var entries = [OutboxOperation]()
        for url in urls where url.pathExtension == "outbox" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let operation = try load(id: id) else { throw LocalStoreError.corruptData }
            entries.append(operation)
        }
        return entries.sorted {
            if $0.enqueuedAt != $1.enqueuedAt { return $0.enqueuedAt < $1.enqueuedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func pending(context: PublicationContext) throws -> [OutboxOperation] {
        try validate(context)
        return try list().filter { $0.context == context && $0.status == .queued }
    }

    public func recoverInterrupted() throws {
        for var operation in try list() where operation.status == .sending {
            operation.transition(to: .queued)
            try write(operation)
        }
    }

    @discardableResult
    public func markSending(id: UUID, context: PublicationContext) throws -> OutboxOperation {
        var operation = try require(id: id, context: context)
        guard operation.status == .queued else { throw AccountDomainError.invalidTransition }
        guard operation.attempts < Int.max else { throw LocalStoreError.invalidDocument }
        operation.transition(to: .sending)
        try write(operation)
        return operation
    }

    public func markFailed(id: UUID, context: PublicationContext, code: String) throws {
        var operation = try require(id: id, context: context)
        guard operation.status == .sending else { throw AccountDomainError.invalidTransition }
        // Only an application-defined category is persisted, not URLs, tokens or payloads.
        let safeCode = String(code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(64))
        operation.transition(to: .failed, code: safeCode.isEmpty ? "unknown" : safeCode)
        try write(operation)
    }

    public func retry(id: UUID, context: PublicationContext) throws {
        var operation = try require(id: id, context: context)
        guard operation.status == .failed else { throw AccountDomainError.invalidTransition }
        operation.transition(to: .queued)
        try write(operation)
    }

    public func markSent(id: UUID, context: PublicationContext, note: RemoteNote) throws {
        var operation = try require(id: id, context: context)
        try note.validate(for: context)
        guard UUID(uuidString: note.id) == id,
              note.revision == operation.archive.document.revision,
              note.revisionHash == operation.archive.document.revisionHash else {
            throw AccountDomainError.invalidPublication
        }
        if operation.status == .sent && operation.publishedNote == note { return }
        guard operation.status == .sending else { throw AccountDomainError.invalidTransition }
        operation.transition(to: .sent, note: note)
        try write(operation)
    }

    /// Call with nil at sign-out/revocation, or with the refreshed context after a
    /// relationship changes. Old work becomes terminal and is never retargeted.
    public func cancelPending(except activeContext: PublicationContext?) throws {
        if let activeContext { try validate(activeContext) }
        for var operation in try list()
            where operation.status != .sent && operation.status != .cancelled && operation.context != activeContext {
            operation.transition(to: .cancelled)
            try write(operation)
        }
    }

    private func validate(_ context: PublicationContext) throws {
        try context.validate()
        guard !accountUID.isEmpty, context.authorID == accountUID else { throw AccountDomainError.accountMismatch }
    }

    private func require(id: UUID, context: PublicationContext) throws -> OutboxOperation {
        try validate(context)
        guard let operation = try load(id: id) else { throw AccountDomainError.operationNotFound }
        guard operation.context == context else { throw AccountDomainError.staleContext }
        return operation
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("outbox")
    }

    private func load(id: UUID) throws -> OutboxOperation? {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)) }
        catch { throw LocalStoreError.corruptData }
        guard envelope.schemaVersion == 1 else { throw LocalStoreError.unsupportedVersion }
        guard envelope.accountUID == accountUID, envelope.operation.id == id else { throw LocalStoreError.corruptData }
        let operation = envelope.operation
        try validate(operation.context)
        try operation.archive.validateIntegrity()
        guard operation.attempts >= 0, operation.enqueuedAt.timeIntervalSince1970.isFinite else {
            throw LocalStoreError.corruptData
        }
        if operation.status == .sent {
            guard let note = operation.publishedNote,
                  UUID(uuidString: note.id) == operation.id,
                  note.revision == operation.archive.document.revision,
                  note.revisionHash == operation.archive.document.revisionHash else { throw LocalStoreError.corruptData }
            try note.validate(for: operation.context)
        } else if operation.publishedNote != nil { throw LocalStoreError.corruptData }
        return operation
    }

    private func write(_ operation: OutboxOperation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = Envelope(schemaVersion: 1, accountUID: accountUID, operation: operation)
        try JSONEncoder().encode(envelope).write(to: fileURL(operation.id), options: .atomic)
    }
}
