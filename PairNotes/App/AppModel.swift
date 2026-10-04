import Combine
import Foundation
import Network
import PairNotesCore

@MainActor
final class AppModel: ObservableObject {
    let services: AppServices
    @Published private(set) var identity: SessionIdentity?
    @Published private(set) var membership: PairMembership?
    @Published private(set) var catalog: DraftCatalogStore?
    @Published private(set) var drafts: [DraftSummary] = []
    @Published private(set) var guestDrafts: [DraftSummary] = []
    @Published private(set) var outbox: [OutboxOperation] = []
    @Published private(set) var notes: [RemoteNote] = []
    @Published private(set) var latestReceived: RemoteNote?
    @Published private(set) var nextCursor: TimelineCursor?
    @Published private(set) var status: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isQueueing = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isOnline = true

    private let storageDirectory: URL
    private let monitor = NWPathMonitor()
    private var monitorStarted = false
    private var observedPath: Bool?
    private var queueStore: DurableOutbox?
    private var catalogs: [String: DraftCatalogStore] = [:]
    private var queueStores: [String: DurableOutbox] = [:]
    private var recoveryTasks: [String: Task<Void, Error>] = [:]
    private var recoveredQueueUIDs: Set<String> = []
    private var needsRecovery = false
    private var membershipResolved = false
    private var activeContext: PublicationContext?
    private var generation: UInt64 = 0
    private var timelineRequest: UInt64 = 0
    private var timelineLoaded = false
    private var previousFirstPageIDs: Set<String> = []
    private var processor: Task<Void, Never>?
    private var processorID: UUID?
    private var processingRequested = false
    private var foregroundInProgress = false

    init(services: AppServices? = nil, storageDirectory: URL? = nil) {
        self.services = services ?? .shared
        self.storageDirectory = storageDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PairNotes", isDirectory: true)
    }

    var canSend: Bool { identity != nil && membershipResolved && activeContext != nil }

    func start() async {
        if !monitorStarted {
            monitorStarted = true
            monitor.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                Task { @MainActor in await self?.networkChanged(connected: connected) }
            }
            monitor.start(queue: DispatchQueue(label: "PairNotes.connectivity"))
        }
        await reconcileSession()
        await services.restore()
        await reconcileSession()
        await refreshSpace()
    }

    /// Unknown membership during restoration pauses the queue. A failed network
    /// request cannot revoke membership, discard a note or retarget its recipient.
    func reconcileSession() async {
        let newIdentity = services.identity
        let resolved = services.membershipResolved
        let newPair = services.membership
        let newContext = resolved ? newIdentity.flatMap { identity in
            try? newPair?.publicationContext(for: identity.uid)
        } : nil
        let accountChanged = catalog == nil || identity?.uid != newIdentity?.uid
        let relationshipChanged = membershipResolved != resolved || activeContext != newContext
        let oldQueue = queueStore
        if accountChanged || relationshipChanged {
            generation &+= 1
            stopProcessor()
            timelineRequest &+= 1
            isLoading = false
            isLoadingMore = false
            isQueueing = false
            if accountChanged || (resolved && activeContext != newContext) {
                notes = []
                latestReceived = nil
                nextCursor = nil
                timelineLoaded = false
                previousFirstPageIDs = []
            }
            status = nil
        }
        identity = newIdentity
        membership = newPair
        membershipResolved = resolved
        activeContext = newContext
        if accountChanged {
            let scope: DraftAccountScope = newIdentity.map { .user(uid: $0.uid) } ?? .guest
            let catalogKey = newIdentity.map { "account:" + $0.uid } ?? "guest"
            if catalogs[catalogKey] == nil {
                catalogs[catalogKey] = DraftCatalogStore(directory: storageDirectory.appendingPathComponent("Drafts"), account: scope)
            }
            catalog = catalogs[catalogKey]
            if let uid = newIdentity?.uid {
                if queueStores[uid] == nil {
                    queueStores[uid] = DurableOutbox(directory: storageDirectory.appendingPathComponent("Outbox"), accountUID: uid)
                }
                queueStore = queueStores[uid]
                needsRecovery = !recoveredQueueUIDs.contains(uid)
            } else {
                queueStore = nil
                needsRecovery = false
            }
            drafts = []
            guestDrafts = []
            outbox = []
        }
        let currentGeneration = generation
        do {
            if accountChanged, let oldQueue { try await oldQueue.cancelPending(except: nil) }
            guard currentGeneration == generation else { return }
            if let queueStore {
                if needsRecovery, let uid = newIdentity?.uid {
                    let recovery: Task<Void, Error>
                    if let existing = recoveryTasks[uid] { recovery = existing }
                    else {
                        recovery = Task { try await queueStore.recoverInterrupted() }
                        recoveryTasks[uid] = recovery
                    }
                    do {
                        try await recovery.value
                        recoveredQueueUIDs.insert(uid)
                        recoveryTasks[uid] = nil
                        if currentGeneration == generation { needsRecovery = false }
                    }
                    catch {
                        recoveryTasks[uid] = nil
                        if currentGeneration == generation { needsRecovery = true }
                        throw error
                    }
                }
                guard currentGeneration == generation else { return }
                if resolved { try await queueStore.cancelPending(except: newContext) }
            }
            guard currentGeneration == generation else { return }
            await reloadDrafts()
            await reloadOutbox()
            if resolved, newContext != nil, accountChanged || relationshipChanged || notes.isEmpty {
                await refreshTimeline()
            }
            guard currentGeneration == generation else { return }
            startProcessor()
        } catch {
            guard currentGeneration == generation else { return }
            status = "No se pudo recuperar el almacenamiento local. Tus archivos se conservaron."
        }
    }

    func foreground() async {
        guard !foregroundInProgress else { return }
        foregroundInProgress = true
        defer { foregroundInProgress = false }
        if services.identity != nil {
            do { try await services.refreshMembership() }
            catch { status = "No se pudo actualizar la conexión. Los envíos pendientes se conservan." }
        }
        await reconcileSession()
        await retryTransientFailures()
        await refreshTimeline()
        await refreshSpace()
    }

    private func refreshSpace() async {
        guard let uid = services.identity?.uid, let pair = services.membership else { return }
        do {
            try await services.refreshCoupleSpace()
            await LocationSharingController.shared.refreshIfNeeded(services: services)
        } catch {
            guard services.identity?.uid == uid, services.membership?.id == pair.id else { return }
            services.spaceError = "No se pudo actualizar su espacio. Deslizá hacia abajo para reintentar."
        }
    }

    func reloadDrafts() async {
        let currentGeneration = generation
        guard let catalog else { return }
        do {
            let summaries = try await catalog.list()
            guard currentGeneration == generation else { return }
            drafts = summaries
            if identity != nil {
                let guest = DraftCatalogStore(directory: storageDirectory.appendingPathComponent("Drafts"), account: .guest)
                let localGuestDrafts = try await guest.list()
                guard currentGeneration == generation else { return }
                guestDrafts = localGuestDrafts
            } else { guestDrafts = [] }
        } catch {
            guard currentGeneration == generation else { return }
            status = "No se pudieron abrir los borradores. Los archivos originales se conservaron."
        }
    }

    /// Explicitly copy a guest drawing into the current account. The original
    /// remains private in its guest namespace and is never silently reassigned.
    func copyGuestDraft(_ draft: DraftSummary) async -> Bool {
        guard identity != nil, let catalog else { return false }
        let currentGeneration = generation
        let guest = DraftCatalogStore(directory: storageDirectory.appendingPathComponent("Drafts"), account: .guest)
        do {
            guard let archive = try await guest.load(id: draft.id), currentGeneration == generation else { return false }
            _ = try await catalog.importCopy(archive, title: draft.title)
            guard currentGeneration == generation else { return false }
            await reloadDrafts()
            status = "El dibujo se copió a tus borradores. El original de invitado se conserva."
            return true
        } catch {
            if currentGeneration == generation { status = "No se pudo copiar este dibujo. El original se conserva." }
            return false
        }
    }

    func deleteDraft(_ draft: DraftSummary) async {
        let currentGeneration = generation
        guard let catalog else { return }
        do {
            try await catalog.remove(id: draft.id)
            guard currentGeneration == generation else { return }
            await reloadDrafts()
        } catch {
            guard currentGeneration == generation else { return }
            status = "No se pudo eliminar el borrador."
        }
    }

    func refreshTimeline() async {
        guard membershipResolved, activeContext != nil else { return }
        timelineRequest &+= 1
        let request = timelineRequest
        let currentGeneration = generation
        isLoading = true
        isLoadingMore = false
        defer {
            if request == timelineRequest, currentGeneration == generation { isLoading = false }
        }
        do {
            async let pageRequest = services.timeline()
            async let latestRequest = services.latestReceivedNote()
            let (page, received) = try await (pageRequest, latestRequest)
            guard request == timelineRequest, currentGeneration == generation else { return }
            notes = try NoteTimeline.merging(notes, page.notes)
            latestReceived = received
            let firstPageIDs = Set(page.notes.map(\.id))
            // A whole new page may have arrived since the previous refresh.
            // Restart at its boundary so older cursors cannot skip that gap.
            if !timelineLoaded || previousFirstPageIDs.isDisjoint(with: firstPageIDs) {
                nextCursor = page.nextCursor
            }
            previousFirstPageIDs = firstPageIDs
            timelineLoaded = true
        } catch is CancellationError {
            return
        } catch {
            guard request == timelineRequest, currentGeneration == generation else { return }
            status = "No se pudieron actualizar los recuerdos. Deslizá hacia abajo para reintentar."
        }
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, let cursor = nextCursor, activeContext != nil else { return }
        let currentGeneration = generation
        let request = timelineRequest
        isLoadingMore = true
        defer {
            if currentGeneration == generation, request == timelineRequest { isLoadingMore = false }
        }
        do {
            let page = try await services.timeline(after: cursor)
            guard currentGeneration == generation, request == timelineRequest else { return }
            notes = try NoteTimeline.merging(notes, page.notes)
            nextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard currentGeneration == generation, request == timelineRequest else { return }
            status = "No se pudieron cargar más recuerdos. Podés volver a intentarlo."
        }
    }

    /// True means the immutable capture is durably queued, not delivered.
    func queue(archive: DraftArchive) async -> Bool {
        guard !isQueueing else { return false }
        guard let context = activeContext, membershipResolved, let queueStore else {
            status = "Iniciá sesión y vinculá las dos cuentas para enviar. El dibujo sigue guardado en este iPhone."
            return false
        }
        isQueueing = true
        let currentGeneration = generation
        defer { if currentGeneration == generation { isQueueing = false } }
        do {
            let existing = try await queueStore.list().first {
                $0.context == context && $0.archive == archive && $0.status != .cancelled
            }
            guard currentGeneration == generation else { return false }
            let operation: OutboxOperation
            if let existing {
                operation = existing
                if existing.status == .failed { try await queueStore.retry(id: existing.id, context: context) }
            } else {
                operation = try await queueStore.enqueue(archive: archive, context: context)
            }
            guard currentGeneration == generation else {
                try? await queueStore.cancel(id: operation.id, context: context)
                return false
            }
            status = operation.status == .sent ? "Esta revisión ya fue enviada." : "En cola. El envío se confirmará cuando el servidor lo publique."
            await reloadOutbox()
            startProcessor()
            return true
        } catch {
            guard currentGeneration == generation else { return false }
            status = "No se pudo preparar el envío. El borrador sigue guardado en este iPhone."
            return false
        }
    }

    func retry(_ operation: OutboxOperation) async {
        guard let context = activeContext, operation.context == context, let queueStore else { return }
        let currentGeneration = generation
        do {
            try await queueStore.retry(id: operation.id, context: context)
            guard currentGeneration == generation else { return }
            await reloadOutbox()
            startProcessor()
        } catch {
            guard currentGeneration == generation else { return }
            status = "No se pudo reanudar este envío. Revisá la conexión y la pareja vinculada."
        }
    }

    private func reloadOutbox() async {
        let currentGeneration = generation
        guard let queueStore else { outbox = []; return }
        do {
            let operations = try await queueStore.list()
            guard currentGeneration == generation else { return }
            outbox = operations
        } catch {
            guard currentGeneration == generation else { return }
            status = "No se pudo leer la cola de envíos. Los archivos se conservaron."
        }
    }

    private func startProcessor() {
        guard isOnline, membershipResolved, let context = activeContext,
              let queueStore, !needsRecovery else { return }
        guard processor == nil else { processingRequested = true; return }
        processingRequested = false
        let currentGeneration = generation
        let identifier = UUID()
        processorID = identifier
        isProcessing = true
        processor = Task { [weak self] in
            guard let self else { return }
            await self.process(store: queueStore, context: context, generation: currentGeneration, identifier: identifier)
        }
    }

    private func stopProcessor() {
        processor?.cancel()
        processor = nil
        processorID = nil
        processingRequested = false
        isProcessing = false
    }

    private func process(store: DurableOutbox, context: PublicationContext, generation capturedGeneration: UInt64, identifier: UUID) async {
        defer {
            if processorID == identifier {
                processor = nil
                processorID = nil
                isProcessing = false
                if processingRequested { startProcessor() }
            }
        }
        while !Task.isCancelled, capturedGeneration == generation, isOnline, context == activeContext {
            let next: OutboxOperation
            do {
                guard let pending = try await store.pending(context: context).first else { return }
                guard !Task.isCancelled, capturedGeneration == generation, context == activeContext else { return }
                next = try await store.markSending(id: pending.id, context: context)
            } catch {
                if capturedGeneration == generation { status = "No se pudo preparar el próximo envío." }
                return
            }
            await reloadOutbox()
            do {
                try Task.checkCancellation()
                guard capturedGeneration == generation, context == activeContext else { throw CancellationError() }
                let note = try await services.publish(operation: next)
                try Task.checkCancellation()
                guard capturedGeneration == generation, context == activeContext else { throw CancellationError() }
                try await store.markSent(id: next.id, context: context, note: note)
                guard capturedGeneration == generation else { return }
                notes = try NoteTimeline.merging(notes, [note])
                status = "Dibujo enviado."
                await reloadOutbox()
            } catch {
                try? await store.markFailed(id: next.id, context: context, code: failureCode(error))
                guard capturedGeneration == generation else { return }
                await reloadOutbox()
                if !Task.isCancelled { status = "No se pudo enviar el dibujo. La copia permanece en la cola para reintentar." }
                // Do not loop failed requests. Retry requires a user action,
                // foreground activation, or a new connectivity event.
                return
            }
        }
    }

    private func retryTransientFailures() async {
        guard isOnline, membershipResolved, let context = activeContext, let queueStore else { return }
        let currentGeneration = generation
        do {
            let entries = try await queueStore.list()
            for entry in entries where entry.context == context && entry.status == .failed &&
                ["network-unavailable", "request-timeout", "server-unavailable", "interrupted"].contains(entry.failureCode ?? "") {
                guard currentGeneration == generation else { return }
                try await queueStore.retry(id: entry.id, context: context)
            }
            guard currentGeneration == generation else { return }
            await reloadOutbox()
            startProcessor()
        } catch {
            if currentGeneration == generation { status = "No se pudo recuperar la cola. Podés reintentar cada envío." }
        }
    }

    private func networkChanged(connected: Bool) async {
        let previous = observedPath
        observedPath = connected
        isOnline = connected
        guard connected, previous == false else { return }
        await foreground()
    }

    private func failureCode(_ error: Error) -> String {
        if error is CancellationError { return "interrupted" }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorTimedOut ? "request-timeout" : "network-unavailable"
        }
        if let api = error as? APIError, (500...599).contains(api.status) { return "server-unavailable" }
        return "publication-failed"
    }
}
