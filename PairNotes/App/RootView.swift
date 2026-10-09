import SwiftUI
import UIKit
// SDK 26 exposes the async push-info getter on a non-Sendable WidgetCenter.
@preconcurrency import WidgetKit
import PairNotesCore

private enum AppTab: Hashable { case home, create, memories, affection, couple }
private struct EditorRoute: Identifiable {
    let id = UUID()
    let store: DraftCatalogStore
    let draft: DraftSummary?
    let uid: String?
    let pairID: String?
    let pairEpoch: UInt64?
}
private struct NoteRoute: Identifiable { let id: String }
private struct PhotoRoute: Identifiable { let id: String }
private enum HomeSheet: String, Identifiable {
    case date, distance
    var id: String { rawValue }
}

struct RootView: View {
    @StateObject private var services = AppServices.shared
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var editor: EditorRoute?
    @State private var noteRoute: NoteRoute?
    @State private var photoRoute: PhotoRoute?
    @State private var cameraShowing = false
    @State private var cameraRequested = false
    @State private var pendingCamera = false
    @State private var pendingPhotoID: String?
    @State private var pendingNoteID: String?
    @State private var synchronizingWidgets = false
    @State private var widgetSyncedScope: String?
    @State private var nextWidgetSync = Date.distantPast
    @State private var widgetGeneration: UInt64 = 0
    @State private var affectionPath: [AffectionDestination] = []
    @State private var pendingAffection: AffectionDestination?
    @State private var pendingTab: AppTab?
    @State private var homeSheet: HomeSheet?
    @State private var collectionModalOwners: Set<UUID> = []
    @State private var collectionDismissalVersion: UInt64 = 0
    @State private var resettingAffectionPath = false
    @State private var dismissingGlobalSheet = false
    @State private var observedUID: String?
    @State private var linkedScope: String?

    private var scope: String {
        [services.identity?.uid ?? "guest", services.membership?.id ?? "none",
         String(services.membership?.pairEpoch ?? 0), String(services.membershipResolved)].joined(separator: ":")
    }

    private var hasPresentedSheet: Bool {
        editor != nil || noteRoute != nil || photoRoute != nil || cameraShowing ||
        homeSheet != nil || dismissingGlobalSheet || !collectionModalOwners.isEmpty
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(model: model, createNote: { openDraft(nil) }, openNote: openNote,
                         createPhoto: { openCamera(capture: false) }, openPhoto: routePhoto,
                         openMessages: { routeAffection(.messages) }, editDate: { homeSheet = .date },
                         openDistance: { homeSheet = .distance })
            }.tabItem { Label("Inicio", systemImage: "house") }.tag(AppTab.home)
            NavigationStack {
                DraftLibraryView(model: model, openDraft: openDraft, openNote: openNote)
            }.tabItem { Label("Dibujos", systemImage: "pencil.tip.crop.circle") }.tag(AppTab.create)
            NavigationStack {
                TimelineView(model: model, openNote: openNote)
            }.tabItem { Label("Recuerdos", systemImage: "rectangle.stack") }.tag(AppTab.memories)
            NavigationStack(path: $affectionPath) {
                AffectionHubView(services: services, connect: { selectedTab = .couple })
                    .navigationDestination(for: AffectionDestination.self) { destination in
                        switch destination {
                        case .letters(let id):
                            LettersView(services: services, notes: model.notes, catalog: model.catalog, focusID: id)
                                .id(id ?? "letters")
                        case .voices:
                            VoiceNotesView(services: services, notes: model.notes, catalog: model.catalog)
                        case .messages:
                            MessagesView(services: services)
                        case .photos:
                            CouplePhotosView(services: services, createPhoto: { openCamera(capture: false) }, openPhoto: routePhoto)
                        }
                    }
            }.tabItem { Label("Para vos", systemImage: "heart.text.clipboard") }.tag(AppTab.affection)
            NavigationStack {
                CoupleView(services: services)
            }.tabItem { Label("Nosotros", systemImage: "person.2") }.tag(AppTab.couple)
        }
        .tint(services.personalization.theme.accent)
        .preferredColorScheme(services.personalization.theme == .night ? .dark : nil)
        .environment(\.coupleModalControl, CoupleModalControl(
            dismissalVersion: collectionDismissalVersion,
            onPresented: { collectionModalOwners.insert($0) },
            onDismissed: { owner in
                collectionModalOwners.remove(owner)
                if collectionModalOwners.isEmpty, resettingAffectionPath {
                    affectionPath = []; resettingAffectionPath = false
                }
                presentPendingRoute()
            }))
        .sheet(item: $editor, onDismiss: { Task { await model.reloadDrafts() }; globalSheetDismissed() }) { route in
            NativePaperEditorView(store: route.store, draft: route.draft, theme: services.personalization.theme,
                                  onSaved: { Task { await model.reloadDrafts() } },
                                  onSend: { archive in
                guard services.identity?.uid == route.uid, model.identity?.uid == route.uid,
                      services.membership?.id == route.pairID,
                      services.membership?.pairEpoch == route.pairEpoch else { return false }
                let queued = await model.queue(archive: archive)
                if queued { selectedTab = .create }
                return queued
            })
        }
        .sheet(item: $noteRoute, onDismiss: globalSheetDismissed) { route in
            NavigationStack { ReceivedNoteDetailView(noteID: route.id, services: services) }
        }
        .sheet(item: $photoRoute, onDismiss: globalSheetDismissed) { route in
            NavigationStack { CouplePhotoDetailView(photoID: route.id, services: services,
                replyWithPhoto: { pendingCamera = true; cameraRequested = true; closePresentedSheets() }) }
        }
        .sheet(isPresented: $cameraShowing, onDismiss: globalSheetDismissed) {
            QuickPhotoComposer(services: services, opensCamera: cameraRequested)
        }
        .sheet(item: $homeSheet, onDismiss: globalSheetDismissed) { destination in
            switch destination {
            case .date: TogetherDateEditor(services: services)
            case .distance: NavigationStack { DistanceSettingsView(services: services, isPresentedModally: true) }
            }
        }
        .task {
            services.onOpenNote = { id in routeNote(id) }
            services.onOpenPhoto = { id in routePhoto(id) }
            services.onOpenCouple = { routeTab(.couple) }
            services.onOpenHome = { routeTab(.home) }
            services.onOpenLetters = { id in routeAffection(.letters(id)) }
            services.onOpenMessages = { routeAffection(.messages) }
            services.onSessionInvalidated = {
                widgetGeneration &+= 1
                WidgetAccessStore.clear()
                closePresentedSheets()
                // The first membership fetch also invalidates widget state.
                // Preserve an incoming link until that fetch resolves; an
                // established relationship or account change cancels it.
                if services.membership != nil || linkedScope != nil || (observedUID != nil && services.identity == nil) {
                    pendingAffection = nil
                    pendingCamera = false; pendingNoteID = nil; pendingPhotoID = nil
                }
                linkedScope = nil
                resetAffectionNavigation()
                widgetSyncedScope = nil
                nextWidgetSync = .distantPast
                LocationSharingController.shared.invalidate()
                PairPhotoActivityController.shared.invalidate()
                Task {
                    await MonthlyReminderService.shared.clearScheduled()
                    await WidgetRemoteClient.shared.clearCache()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            services.onReceivedNote = {
                Task {
                    await model.foreground()
                    _ = await WidgetRemoteClient.shared.refresh()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            await model.start()
            services.deliverPendingAffectionRoute()
        }
        .task(id: scope) {
            await model.reconcileSession()
            guard !Task.isCancelled else { return }
            observedUID = services.identity?.uid
            if services.membershipResolved, services.membership != nil { linkedScope = scope }
            services.deliverPendingAffectionRoute()
            if services.membershipResolved, services.membership != nil {
                if let pendingNoteID { routeNote(pendingNoteID) }
                if let pendingPhotoID { routePhoto(pendingPhotoID) }
                if pendingCamera { pendingCamera = false; openCamera(capture: cameraRequested) }
                if let pendingAffection { routeAffection(pendingAffection) }
                await synchronizeWidgets()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                // A native permission prompt may make the scene inactive. Only
                // backgrounding cancels the explicit location request.
                if scenePhase == .background { LocationSharingController.shared.invalidate() }
                return
            }
            await model.foreground()
            await synchronizeWidgets()
            await PairPhotoActivityController.shared.synchronize(services: services)
            // Foreground polling covers missed alerts and installations without
            // notification permission. iOS background execution is not assumed.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !Task.isCancelled else { return }
                await model.foreground()
                await synchronizeWidgets()
                await PairPhotoActivityController.shared.synchronize(services: services)
            }
        }
        .onChange(of: services.identity?.uid) { old, uid in
            observedUID = uid
            if old != nil {
                pendingAffection = nil; resetAffectionNavigation()
                pendingCamera = false; pendingNoteID = nil; pendingPhotoID = nil
                closePresentedSheets()
            }
        }
        .onChange(of: services.membership?.pairEpoch) { old, _ in
            // Preserve a cold link while membership first resolves; discard it
            // when an existing relationship is replaced or revoked.
            if old != nil { pendingAffection = nil; resetAffectionNavigation() }
        }
        .onChange(of: services.membership?.id) { old, _ in
            if old != nil { homeSheet = nil; pendingAffection = nil; resetAffectionNavigation() }
        }
        .onOpenURL { url in
            if url.scheme == "pairnotes", url.host == "home" { routeTab(.home); return }
            if url.scheme == "pairnotes", ["letters", "letter"].contains(url.host ?? "") {
                let id = url.pathComponents.last.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
                routeAffection(.letters(id)); return
            }
            if services.handle(url: url) { return }
            guard url.scheme == "pairnotes" else { return }
            switch url.host {
            case "create": routeTab(.create)
            case "couple": routeTab(.couple)
            case "messages": routeAffection(.messages)
            case "voices": routeAffection(.voices)
            case "photos": routeAffection(.photos)
            case "note": routeNote(url.lastPathComponent)
            case "photo": routePhoto(url.lastPathComponent)
            case "camera": openCamera(capture: true)
            default: break
            }
        }
        .environment(\.coupleAppTheme, services.personalization.theme)
    }

    private func openDraft(_ draft: DraftSummary?) {
        guard model.identity?.uid == services.identity?.uid, let store = model.catalog else { return }
        editor = EditorRoute(store: store, draft: draft, uid: services.identity?.uid,
                             pairID: services.membership?.id, pairEpoch: services.membership?.pairEpoch)
    }

    private func openNote(_ note: RemoteNote) { routeNote(note.id) }

    private func openCamera(capture: Bool) {
        pendingPhotoID = nil; pendingNoteID = nil; pendingAffection = nil; pendingTab = nil
        cameraRequested = capture
        guard services.identity != nil, services.membershipResolved, services.membership != nil else {
            pendingCamera = true; selectedTab = .couple; return
        }
        if hasPresentedSheet {
            pendingCamera = true
            closePresentedSheets()
        } else { cameraShowing = true }
    }

    private func presentPendingRoute() {
        guard !hasPresentedSheet else { return }
        if let tab = pendingTab { pendingTab = nil; routeTab(tab); return }
        guard services.membership != nil else { return }
        if let id = pendingPhotoID { pendingPhotoID = nil; routePhoto(id) }
        else if let id = pendingNoteID { pendingNoteID = nil; routeNote(id) }
        else if pendingCamera { pendingCamera = false; cameraShowing = true }
        else if let pendingAffection { routeAffection(pendingAffection) }
    }

    private func routeAffection(_ destination: AffectionDestination) {
        pendingCamera = false; pendingPhotoID = nil; pendingNoteID = nil; pendingTab = nil
        guard services.identity != nil, services.membershipResolved, services.membership != nil else {
            pendingAffection = destination; selectedTab = .couple; return
        }
        if hasPresentedSheet {
            pendingAffection = destination
            closePresentedSheets()
        } else {
            pendingAffection = nil
            selectedTab = .affection
            affectionPath = [destination]
        }
    }

    private func routePhoto(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        pendingCamera = false; pendingNoteID = nil; pendingAffection = nil; pendingTab = nil
        guard services.identity != nil, services.membershipResolved, services.membership != nil else {
            pendingPhotoID = uuid.uuidString.lowercased(); selectedTab = .couple; return
        }
        if photoRoute?.id == uuid.uuidString.lowercased() { return }
        if hasPresentedSheet {
            pendingPhotoID = uuid.uuidString.lowercased()
            closePresentedSheets()
        } else { pendingPhotoID = nil; photoRoute = PhotoRoute(id: uuid.uuidString.lowercased()) }
    }

    private func routeNote(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        pendingCamera = false; pendingPhotoID = nil; pendingAffection = nil; pendingTab = nil
        guard services.identity != nil, services.membershipResolved, services.membership != nil else {
            pendingNoteID = uuid.uuidString.lowercased()
            selectedTab = .couple
            return
        }
        if noteRoute?.id == uuid.uuidString.lowercased() { return }
        if hasPresentedSheet {
            pendingNoteID = uuid.uuidString.lowercased()
            closePresentedSheets()
        } else { pendingNoteID = nil; noteRoute = NoteRoute(id: uuid.uuidString.lowercased()) }
    }

    private func closePresentedSheets() {
        if editor != nil || noteRoute != nil || photoRoute != nil || cameraShowing || homeSheet != nil {
            dismissingGlobalSheet = true
        }
        editor = nil; noteRoute = nil; photoRoute = nil; cameraShowing = false; homeSheet = nil
        if !collectionModalOwners.isEmpty { collectionDismissalVersion &+= 1 }
    }

    private func routeTab(_ tab: AppTab) {
        pendingCamera = false; pendingPhotoID = nil; pendingNoteID = nil; pendingAffection = nil
        if hasPresentedSheet {
            pendingTab = tab; closePresentedSheets()
        } else {
            pendingTab = nil; selectedTab = tab
        }
    }

    private func globalSheetDismissed() {
        dismissingGlobalSheet = false
        presentPendingRoute()
    }

    private func resetAffectionNavigation() {
        if collectionModalOwners.isEmpty {
            affectionPath = []; resettingAffectionPath = false
        } else {
            // Keep the presenting collection alive until UIKit completes the
            // dismiss. Its scope guards already hide the previous account.
            resettingAffectionPath = true
            collectionDismissalVersion &+= 1
        }
    }

    private func synchronizeWidgets() async {
        guard !synchronizingWidgets, let uid = services.identity?.uid, let pair = services.membership,
              services.membershipResolved, SharedWidgetContainer.directory() != nil else { return }
        guard widgetSyncedScope != scope || Date() >= nextWidgetSync else { return }
        synchronizingWidgets = true
        let generation = widgetGeneration, capturedScope = scope
        defer {
            synchronizingWidgets = false
            if capturedScope != scope { Task { await synchronizeWidgets() } }
        }
        func stillCurrent() -> Bool {
            generation == widgetGeneration && services.identity?.uid == uid &&
            services.membership?.id == pair.id && services.membership?.pairEpoch == pair.pairEpoch
        }
        do {
            let existing = WidgetAccessStore.load()
            if existing?.uid != uid || existing?.pairID != pair.id || existing?.pairEpoch != pair.pairEpoch ||
                existing?.baseURL != services.widgetBaseURL || (existing?.expiresAt.timeIntervalSinceNow ?? 0) < 86_400 {
                let authorization = try await services.issueWidgetSession()
                guard stillCurrent() else { return }
                try WidgetAccessStore.save(authorization)
            }
            if let push = await WidgetCenter.shared.currentPushInfo {
                guard stillCurrent() else { return }
                // Push registration failure must not prevent ordinary timeline refreshes.
                try? await services.registerWidgetPushToken(push.token)
            }
            guard stillCurrent() else { return }
            var result = await WidgetRemoteClient.shared.refresh()
            if result.needsAuthorization {
                let authorization = try await services.issueWidgetSession()
                guard stillCurrent() else { return }
                try WidgetAccessStore.save(authorization)
                result = await WidgetRemoteClient.shared.refresh()
            }
            guard stillCurrent() else { return }
            widgetSyncedScope = capturedScope
            nextWidgetSync = Date().addingTimeInterval(result.cached || result.needsAuthorization || result.expiresAt == nil ? 30 : 300)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Foreground polling retries automatically without presenting a setup control.
            if stillCurrent() { widgetSyncedScope = capturedScope; nextWidgetSync = Date().addingTimeInterval(30) }
        }
    }
}

struct ReceivedNoteDetailView: View {
    let noteID: String
    @ObservedObject var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var note: RemoteNote?
    @State private var image: UIImage?
    @State private var message: String?
    @State private var loading = false
    @State private var exporting = false
    @State private var hasMarkedViewed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if loading { ProgressView("Abriendo dibujo…") }
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().privacySensitive()
                    if let note {
                        Text(note.serverPublishedAt, format: .dateTime.day().month(.wide).year().hour().minute())
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let note { NoteReactionsView(services: services, note: note) }
                    Button("Exportar imagen", systemImage: "square.and.arrow.up") { exporting = true }
                        .buttonStyle(.bordered)
                }
                if let message {
                    ContentUnavailableView("No se pudo abrir", systemImage: "lock.doc", description: Text(message))
                    Button("Reintentar") { Task { await load() } }
                }
            }.padding()
        }
        .coupleScreenBackground()
        .navigationTitle("Recuerdo").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } } }
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await markViewed() } }
        }
        .sheet(isPresented: $exporting) { if let image { ShareImageView(image: image) } }
    }

    private func load() async {
        guard !loading else { return }
        let uid = services.identity?.uid
        let pair = services.membership
        loading = true
        image = nil
        note = nil
        message = nil
        defer { loading = false }
        do {
            let fetched = try await services.note(id: noteID)
            let bytes = try await services.image(path: fetched.assets.final)
            guard !Task.isCancelled, services.identity?.uid == uid,
                  services.membership?.id == pair?.id, services.membership?.pairEpoch == pair?.pairEpoch,
                  let decoded = UIImage(data: bytes) else { throw ServiceError.sessionChanged }
            note = fetched
            image = decoded
            await markViewed()
        } catch is CancellationError { return }
        catch { message = "Revisá la conexión y que este dibujo pertenezca a la pareja vinculada." }
    }

    private func markViewed() async {
        guard scenePhase == .active, !hasMarkedViewed, let note, image != nil,
              note.recipientID == services.identity?.uid else { return }
        do { try await services.markViewed(note: note); hasMarkedViewed = true } catch { /* retry when active */ }
    }
}
