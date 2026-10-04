import SwiftUI
import UIKit
import WidgetKit
import PairNotesCore

private enum AppTab: Hashable { case home, create, memories, couple }
private struct EditorRoute: Identifiable {
    let id = UUID()
    let store: DraftCatalogStore
    let draft: DraftSummary?
}
private struct NoteRoute: Identifiable { let id: String }

struct RootView: View {
    @StateObject private var services = AppServices.shared
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .home
    @State private var editor: EditorRoute?
    @State private var noteRoute: NoteRoute?
    @State private var pendingNoteID: String?
    @State private var widgetMessage: String?
    @State private var widgetConnecting = false
    @State private var widgetGeneration: UInt64 = 0

    private var scope: String {
        [services.identity?.uid ?? "guest", services.membership?.id ?? "none",
         String(services.membership?.pairEpoch ?? 0), String(services.membershipResolved)].joined(separator: ":")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(model: model, createNote: { selectedTab = .create }, openNote: openNote)
            }.tabItem { Label("Inicio", systemImage: "house") }.tag(AppTab.home)
            NavigationStack {
                DraftLibraryView(model: model, openDraft: openDraft)
            }.tabItem { Label("Crear", systemImage: "pencil.tip.crop.circle") }.tag(AppTab.create)
            NavigationStack {
                TimelineView(model: model, openNote: openNote)
            }.tabItem { Label("Recuerdos", systemImage: "rectangle.stack") }.tag(AppTab.memories)
            NavigationStack {
                CoupleView(services: services, widgetMessage: widgetMessage,
                           widgetConnecting: widgetConnecting, connectWidget: { await connectWidget(force: true) })
            }.tabItem { Label("Nosotros", systemImage: "person.2") }.tag(AppTab.couple)
        }
        .sheet(item: $editor, onDismiss: { Task { await model.reloadDrafts() } }) { route in
            NativePaperEditorView(store: route.store, draft: route.draft,
                                  onSaved: { Task { await model.reloadDrafts() } },
                                  onSend: { archive in
                let queued = await model.queue(archive: archive)
                if queued { selectedTab = .create }
                return queued
            })
        }
        .sheet(item: $noteRoute) { route in
            NavigationStack { ReceivedNoteDetailView(noteID: route.id, services: services) }
        }
        .task {
            services.onOpenNote = { id in routeNote(id) }
            services.onSessionInvalidated = {
                widgetGeneration &+= 1
                WidgetAccessStore.clear()
                noteRoute = nil
                widgetMessage = nil
                Task {
                    await WidgetRemoteClient.shared.clearCache()
                    WidgetCenter.shared.reloadTimelines(ofKind: SharedWidgetContainer.widgetKind)
                }
            }
            services.onReceivedNote = {
                Task {
                    await model.foreground()
                    _ = await WidgetRemoteClient.shared.refresh()
                    WidgetCenter.shared.reloadTimelines(ofKind: SharedWidgetContainer.widgetKind)
                }
            }
            await model.start()
        }
        .task(id: scope) {
            await model.reconcileSession()
            if services.membershipResolved, services.membership != nil {
                await connectWidget(force: false)
                if let pendingNoteID { routeNote(pendingNoteID) }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.foreground()
            await connectWidget(force: false)
            // Foreground polling covers missed alerts and installations without
            // notification permission. iOS background execution is not assumed.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard !Task.isCancelled else { return }
                await model.foreground()
            }
        }
        .onChange(of: services.identity?.uid) { _, _ in editor = nil; noteRoute = nil }
        .onOpenURL { url in
            if services.handle(url: url) { return }
            guard url.scheme == "pairnotes" else { return }
            switch url.host {
            case "create": selectedTab = .create
            case "couple": selectedTab = .couple
            case "note": routeNote(url.lastPathComponent)
            default: break
            }
        }
    }

    private func openDraft(_ draft: DraftSummary?) {
        guard model.identity?.uid == services.identity?.uid, let store = model.catalog else { return }
        editor = EditorRoute(store: store, draft: draft)
    }

    private func openNote(_ note: RemoteNote) { routeNote(note.id) }

    private func routeNote(_ id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        guard services.identity != nil, services.membershipResolved, services.membership != nil else {
            pendingNoteID = uuid.uuidString.lowercased()
            selectedTab = .couple
            return
        }
        pendingNoteID = nil
        noteRoute = NoteRoute(id: uuid.uuidString.lowercased())
    }

    private func connectWidget(force: Bool) async {
        guard !widgetConnecting, let uid = services.identity?.uid, let pair = services.membership,
              services.membershipResolved else { return }
        guard SharedWidgetContainer.directory() != nil else {
            if force { widgetMessage = "El widget requiere una instalación firmada con su grupo compartido." }
            return
        }
        widgetConnecting = true
        let generation = widgetGeneration
        defer { widgetConnecting = false }
        do {
            let existing = WidgetAccessStore.load()
            if force || existing?.uid != uid || existing?.pairID != pair.id || existing?.pairEpoch != pair.pairEpoch ||
                (existing?.expiresAt.timeIntervalSinceNow ?? 0) < 86_400 {
                let authorization = try await services.issueWidgetSession()
                guard generation == widgetGeneration, services.identity?.uid == uid,
                      services.membership?.id == pair.id, services.membership?.pairEpoch == pair.pairEpoch else { return }
                try WidgetAccessStore.save(authorization)
            }
            if let push = await WidgetCenter.shared.currentPushInfo {
                guard generation == widgetGeneration else { return }
                try await services.registerWidgetPushToken(push.token)
            }
            guard generation == widgetGeneration else { return }
            _ = await WidgetRemoteClient.shared.refresh()
            WidgetCenter.shared.reloadTimelines(ofKind: SharedWidgetContainer.widgetKind)
            widgetMessage = "Widget conectado. Agregá «Último dibujo» desde la pantalla de inicio. iOS decide cuándo actualiza su contenido."
        } catch {
            guard generation == widgetGeneration else { return }
            if force { widgetMessage = error.localizedDescription }
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
                    Button("Exportar imagen", systemImage: "square.and.arrow.up") { exporting = true }
                        .buttonStyle(.bordered)
                }
                if let message {
                    ContentUnavailableView("No se pudo abrir", systemImage: "lock.doc", description: Text(message))
                    Button("Reintentar") { Task { await load() } }
                }
            }.padding()
        }
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
