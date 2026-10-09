import Combine
import Foundation
import PairNotesCore

@MainActor
struct ChatReactionSource {
    let currentScope: () -> String
    let ownUID: () -> String?
    let isAuthorized: () -> Bool
    let reactions: @MainActor ([ChatReactionTarget]) async throws -> [ChatReaction]
    let setReaction: @MainActor (ChatReactionTarget, ChatReactionKind?) async throws -> [ChatReaction]

    static func live(_ services: AppServices) -> Self {
        Self(currentScope: { services.privateImageKey("conversation") },
             ownUID: { services.identity?.uid },
             isAuthorized: { services.identity != nil && services.membershipResolved && services.membership != nil },
             reactions: { try await services.chatReactions(targets: $0) },
             setReaction: { try await services.setChatReaction(target: $0, kind: $1) })
    }
}

/// Keeps confirmed reactions in the current account/pair only. A GET started
/// before or during a local mutation cannot overwrite that mutation or removal.
@MainActor
final class ChatReactionStore: ObservableObject {
    @Published private(set) var loadedScope: String?
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    @Published private var values: [ChatReactionTarget: [ChatReaction]] = [:]
    @Published private var busy: Set<ChatReactionTarget> = []
    @Published private var errors: [ChatReactionTarget: String] = [:]
    @Published private var confirmations: [ChatReactionTarget: UInt64] = [:]
    private var source: ChatReactionSource?
    private var generation: UInt64 = 0
    private var fetchSequence: UInt64 = 0
    private var writeVersions: [ChatReactionTarget: UInt64] = [:]
    private var pending: [ChatReactionTarget: UUID] = [:]
    private var queuedRefresh: (source: ChatReactionSource, targets: [ChatReactionTarget])?

    func reactions(for target: ChatReactionTarget) -> [ChatReaction] {
        currentScopeIsValid ? values[target, default: []] : []
    }
    func myReaction(for target: ChatReactionTarget) -> ChatReaction? {
        guard currentScopeIsValid, let uid = source?.ownUID() else { return nil }
        return values[target, default: []].first { $0.authorID == uid }
    }
    func isReacting(_ target: ChatReactionTarget) -> Bool { currentScopeIsValid && busy.contains(target) }
    func confirmationRevision(_ target: ChatReactionTarget) -> UInt64 {
        currentScopeIsValid ? confirmations[target, default: 0] : 0
    }
    func error(for target: ChatReactionTarget) -> String? { currentScopeIsValid ? errors[target] : nil }

    func reset() {
        generation &+= 1; fetchSequence &+= 1
        loadedScope = nil; source = nil; loading = false; loadError = nil
        values = [:]; busy = []; errors = [:]; confirmations = [:]
        pending = [:]; writeVersions = [:]; queuedRefresh = nil
    }

    func refresh(services: AppServices, targets: [ChatReactionTarget]) async {
        await refresh(source: .live(services), targets: targets)
    }

    func refresh(source: ChatReactionSource, targets: [ChatReactionTarget]) async {
        guard !Task.isCancelled, let scope = bind(source) else { return }
        if loading { queuedRefresh = (source, targets); return }
        fetchSequence &+= 1
        let request = fetchSequence, epoch = generation, versions = writeVersions
        let ordered = Set(targets).sorted { $0.key < $1.key }
        loading = !ordered.isEmpty; loadError = nil
        defer {
            if generation == epoch, fetchSequence == request {
                loading = false
                if let queued = queuedRefresh {
                    queuedRefresh = nil
                    if !Task.isCancelled, isCurrent(queued.source, scope: scope, generation: epoch) {
                        Task {
                            guard isCurrent(queued.source, scope: scope, generation: epoch) else { return }
                            await refresh(source: queued.source, targets: queued.targets)
                        }
                    }
                }
            }
        }
        do {
            var received: [ChatReaction] = []
            // Wire requests remain bounded even if a caller has many loaded rows.
            for start in stride(from: 0, to: ordered.count, by: 100) {
                try Task.checkCancellation()
                guard isCurrent(source, scope: scope, generation: epoch) else { return }
                let batch = Array(ordered[start..<min(start + 100, ordered.count)])
                received += try await source.reactions(batch)
            }
            guard !Task.isCancelled, fetchSequence == request,
                  isCurrent(source, scope: scope, generation: epoch) else { return }
            let grouped = Dictionary(grouping: received, by: \.target)
            for target in ordered where pending[target] == nil &&
                versions[target, default: 0] == writeVersions[target, default: 0] {
                apply(grouped[target, default: []], to: target, preservingNewer: true)
            }
        } catch {
            if error is CancellationError { return }
            guard !Task.isCancelled, fetchSequence == request,
                  isCurrent(source, scope: scope, generation: epoch) else { return }
            loadError = "No se pudieron actualizar las reacciones."
        }
    }

    func setReaction(_ kind: ChatReactionKind?, for target: ChatReactionTarget,
                     services: AppServices, expectedScope: String? = nil) async {
        await setReaction(kind, for: target, source: .live(services), expectedScope: expectedScope)
    }

    func setReaction(_ kind: ChatReactionKind?, for target: ChatReactionTarget,
                     source: ChatReactionSource, expectedScope: String? = nil) async {
        guard !Task.isCancelled, source.isAuthorized(),
              expectedScope.map({ $0 == source.currentScope() }) ?? true else { return }
        // A callback from a row belonging to the previous pair cannot rebind it.
        if let loadedScope, loadedScope != source.currentScope() { return }
        guard let scope = bind(source), pending[target] == nil else { return }
        let operation = UUID(), epoch = generation
        pending[target] = operation; busy.insert(target); errors[target] = nil
        writeVersions[target, default: 0] &+= 1
        defer {
            if generation == epoch, pending[target] == operation {
                pending[target] = nil; busy.remove(target)
            }
        }
        do {
            try Task.checkCancellation()
            guard isCurrent(source, scope: scope, generation: epoch) else { return }
            let confirmed = try await source.setReaction(target, kind)
            guard !Task.isCancelled, pending[target] == operation,
                  isCurrent(source, scope: scope, generation: epoch) else { return }
            // Also invalidate GETs begun while this POST was pending. The version
            // survives a null result, so an older GET cannot resurrect a removal.
            writeVersions[target, default: 0] &+= 1
            apply(confirmed, to: target, preservingNewer: false)
            confirmations[target, default: 0] &+= 1
        } catch {
            if error is CancellationError { return }
            guard !Task.isCancelled, pending[target] == operation,
                  isCurrent(source, scope: scope, generation: epoch) else { return }
            errors[target] = "No se pudo guardar la reacción. Intentá de nuevo."
        }
    }

    private var currentScopeIsValid: Bool {
        guard let source, let loadedScope else { return false }
        return source.isAuthorized() && source.currentScope() == loadedScope
    }

    private func bind(_ source: ChatReactionSource) -> String? {
        guard source.isAuthorized(), source.ownUID() != nil else { reset(); return nil }
        let scope = source.currentScope()
        if loadedScope != scope { reset(); loadedScope = scope }
        self.source = source
        return scope
    }

    private func isCurrent(_ source: ChatReactionSource, scope: String, generation epoch: UInt64) -> Bool {
        generation == epoch && loadedScope == scope && source.isAuthorized() && source.currentScope() == scope
    }

    private func apply(_ incoming: [ChatReaction], to target: ChatReactionTarget, preservingNewer: Bool) {
        let previous = values[target, default: []]
        values[target] = incoming.map { value in
            if preservingNewer, let newer = previous.first(where: { $0.authorID == value.authorID }),
               newer.updatedAt > value.updatedAt { return newer }
            return value
        }.sorted { $0.authorID < $1.authorID }
    }
}
