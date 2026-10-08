import SwiftUI
import PhotosUI
import PaperKit
import PairNotesCore

struct SharedMemoriesSection: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    var catalog: DraftCatalogStore? = nil
    let openNote: (RemoteNote) -> Void
    @State private var adding = false
    @State private var selected: SharedMemory?
    @Environment(\.coupleModalControl) private var modalControl
    @State private var modalOwner = UUID()

    var body: some View {
        if services.membership != nil {
            Section {
                if services.coupleSpace?.memories.isEmpty != false {
                    ContentUnavailableView("Sin recuerdos", systemImage: "book.closed")
                }
                ForEach((services.coupleSpace?.memories ?? []).sorted { $0.date.rawValue > $1.date.rawValue }) { memory in
                    Button { openMemory(memory) } label: {
                        ScrapbookPage(services: services, memory: memory, compact: true)
                    }.buttonStyle(.plain).listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("Abrir página", systemImage: "book") { openMemory(memory) }
                        } preview: { ScrapbookPage(services: services, memory: memory).frame(width: 320) }
                }
                Button("Nuevo recuerdo", systemImage: "plus") {
                    modalControl.onPresented(modalOwner); adding = true
                }
            } header: { Text("Álbum") }
            .sheet(isPresented: $adding, onDismiss: { modalControl.onDismissed(modalOwner) }) {
                SharedMemoryEditor(services: services, notes: notes, catalog: catalog)
            }
            .sheet(item: $selected, onDismiss: { modalControl.onDismissed(modalOwner) }) { memory in
                MemoryDetailView(services: services, original: memory, notes: notes, catalog: catalog, openNote: { note in
                    // Root queues the drawing until this sheet finishes closing.
                    openNote(note)
                })
            }
            .onChange(of: modalControl.dismissalVersion) { _, _ in adding = false; selected = nil }
            .onChange(of: services.identity?.uid) { _, _ in adding = false; selected = nil }
            .onChange(of: services.privateImageKey("memories")) { _, _ in adding = false; selected = nil }
        }
    }

    private func openMemory(_ memory: SharedMemory) {
        modalControl.onPresented(modalOwner); selected = memory
    }
}

struct MemoryPhotoView: View {
    @ObservedObject var services: AppServices
    let memory: SharedMemory
    var allowsExpansion = false
    @State private var image: UIImage?
    @State private var loadedKey: String?
    @State private var failed = false
    @State private var expanded = false
    @Environment(\.coupleModalControl) private var modalControl
    @State private var modalOwner = UUID()
    private var key: String { "\(services.identity?.uid ?? "")|\(services.membership?.id ?? "")|\(services.membership?.pairEpoch ?? 0)|\(memory.id)|\(memory.photo?.id ?? "")|\(memory.photo?.sha256 ?? "")" }
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if loadedKey == key, let image { Image(uiImage: image).resizable().scaledToFit().privacySensitive() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView() }
        }.clipped()
            .gesture(TapGesture().onEnded {
                if loadedKey == key, image != nil { modalControl.onPresented(modalOwner); expanded = true }
            },
                including: allowsExpansion ? .all : .none)
            .sheet(isPresented: $expanded, onDismiss: { modalControl.onDismissed(modalOwner) }) {
                if loadedKey == key, let image { PhotoViewer(image: image) }
            }
            .onChange(of: modalControl.dismissalVersion) { _, _ in expanded = false }
            .onChange(of: key) { _, _ in expanded = false }
            .task(id: key) {
            let captured = key; image = nil; loadedKey = nil; failed = false
            do {
                let bytes = try await services.memoryPhoto(memory)
                guard !Task.isCancelled, captured == key else { return }
                image = UIImage(data: bytes); loadedKey = captured
            } catch { if captured == key, !Task.isCancelled { failed = true } }
        }
    }
}

struct MemoryDetailView: View {
    @ObservedObject var services: AppServices
    let original: SharedMemory
    let notes: [RemoteNote]
    var catalog: DraftCatalogStore? = nil
    let openNote: (RemoteNote) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var calendarSheet = false
    @State private var undoUntil: Date?
    @State private var deleting = false
    @State private var busy = false
    @State private var error: String?
    private var memory: SharedMemory { services.coupleSpace?.memories.first { $0.id == original.id } ?? original }
    private var removed: Bool { services.coupleSpace.map { !$0.memories.contains(where: { $0.id == original.id }) } ?? false }
    var body: some View {
        NavigationStack {
            List {
                if removed {
                    ContentUnavailableView("Recuerdo eliminado", systemImage: "calendar.badge.minus")
                    if let undoUntil {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            if context.date < undoUntil {
                                Button("Deshacer eliminación", systemImage: "arrow.uturn.backward") {
                                    busy = true
                                    Task { @MainActor in
                                        defer { busy = false }
                                        do { try await services.restoreMemory(original); self.undoUntil = nil; error = nil }
                                        catch { self.error = "No se pudo restaurar. Reintentá antes de que termine el minuto." }
                                    }
                                }
                            } else { Text("El plazo para deshacer terminó.").foregroundStyle(.secondary) }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                } else {
                ScrapbookPage(services: services, memory: memory)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    if let noteID = memory.noteId {
                        Button("Abrir dibujo vinculado", systemImage: "paintpalette") {
                            busy = true
                            Task { @MainActor in
                                defer { busy = false }
                                do { let note = try await services.note(id: noteID); openNote(note) }
                                catch { self.error = "No se pudo abrir el dibujo vinculado." }
                            }
                        }
                    }
                    Button("Agregar al Calendario", systemImage: "calendar.badge.plus") { calendarSheet = true }
                }
                Section { Button("Eliminar recuerdo", systemImage: "trash", role: .destructive) { deleting = true } }
                if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(busy)
            .navigationTitle("Recuerdo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Editar") { editing = true }.disabled(removed) }
            }
            .onChange(of: removed) { _, value in if value { editing = false; calendarSheet = false; deleting = false } }
            .sheet(isPresented: $editing) { SharedMemoryEditor(services: services, notes: notes, memory: memory, catalog: catalog) }
            .sheet(isPresented: $calendarSheet) {
                if let date = memory.date.date(in: .current) {
                    CalendarEventEditor(title: memory.title, date: date, recursYearly: memory.recursYearly)
                }
            }
            .confirmationDialog("¿Eliminar este recuerdo para los dos?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Eliminar recuerdo", role: .destructive) {
                    busy = true
                    Task { @MainActor in
                        defer { busy = false }
                        do {
                            let deadline = Date().addingTimeInterval(60)
                            try await services.deleteMemory(memory); undoUntil = deadline
                        }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { Text("Podés deshacer durante un minuto en esta pantalla. El dibujo vinculado y los eventos ya agregados al Calendario se conservan.") }
        }
    }
}

struct SharedMemoryEditor: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    var catalog: DraftCatalogStore? = nil
    let original: SharedMemory?
    private let pairID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var id: String
    @State private var title: String
    @State private var date: Date
    @State private var bodyText: String
    @State private var recursYearly: Bool
    @State private var noteID: String
    @State private var choosingPhoto = false
    @State private var photoData: Data?
    @State private var photoNeedsSaving = false
    @State private var removePhoto = false
    @State private var loadingPhoto = false
    @State private var crop: SelectedPhotoCrop?
    @State private var busy = false
    @State private var discarding = false
    @State private var error: String?
    private let originalDate: CoupleDate?
    private let storage: MemoryCompositionStorage
    @State private var decoration: MemoryDecoration
    @State private var finished = false
    @State private var recovered: Bool
    @State private var canvasDraft: DraftSummary?
    private var canvasStorage: MemoryCompositionStorage {
        MemoryCompositionStorage(key: services.privateImageKey("scrapbook-source:" + id))
    }
    @Environment(\.scenePhase) private var scenePhase
    private var composition: MemoryCompositionDraft {
        MemoryCompositionDraft(id: id, title: title, date: date, body: bodyText,
            recursYearly: recursYearly, noteID: noteID, removePhoto: removePhoto, decoration: decoration)
    }


    init(services: AppServices, notes: [RemoteNote], memory: SharedMemory? = nil, catalog: DraftCatalogStore? = nil) {
        self.catalog = catalog
        self.services = services; self.notes = notes; original = memory; pairID = services.membership?.id
        let storage = MemoryCompositionStorage(key: services.privateImageKey("composition:\(memory?.id ?? "new")"))
        self.storage = storage
        let draft = storage.load()
        _recovered = State(initialValue: draft != nil)
        _id = State(initialValue: draft?.id ?? memory?.id ?? UUID().uuidString.lowercased())
        _title = State(initialValue: draft?.title ?? memory?.title ?? "")
        let initialDate = memory?.date.date(in: .current) ?? Date()
        _date = State(initialValue: draft?.date ?? initialDate)
        originalDate = CoupleDate(date: initialDate, calendar: .current)
        _bodyText = State(initialValue: draft?.body ?? memory?.body ?? "")
        _recursYearly = State(initialValue: draft?.recursYearly ?? memory?.recursYearly ?? false)
        _noteID = State(initialValue: draft?.noteID ?? memory?.noteId ?? "")
        _decoration = State(initialValue: draft?.decoration ?? memory?.decoration ?? MemoryDecoration())
        _removePhoto = State(initialValue: draft?.removePhoto ?? false)
        _photoData = State(initialValue: draft == nil ? nil : storage.photo())
    }
    private var changed: Bool {
        title != (original?.title ?? "") || CoupleDate(date: date, calendar: .current) != originalDate ||
        bodyText != (original?.body ?? "") || recursYearly != (original?.recursYearly ?? false) ||
        (original == nil && (canvasStorage.loadValue() as ScrapbookSourceReference?) != nil) || decoration != (original?.decoration ?? MemoryDecoration()) || noteID != (original?.noteId ?? "") || photoData != nil || removePhoto
    }
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !busy && !loadingPhoto && (1...120).contains(cleanTitle.utf16.count) && bodyText.utf16.count <= 2_000 && changed }
    var body: some View {
        NavigationStack {
            Form {
                if recovered {
                    Label("Retomaste tu borrador privado", systemImage: "arrow.counterclockwise")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Estilo") {
                    Picker("Formato", selection: $decoration.layout) {
                        ForEach(MemoryDecoration.Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Sticker", selection: $decoration.sticker) {
                        ForEach(MemoryDecoration.Sticker.allCases, id: \.self) {
                            Text($0 == .none ? "Sin sticker" : $0.symbol).tag($0)
                        }
                    }
                    Menu("Empezar con una idea", systemImage: "sparkles") {
                        ForEach(["Nuestra primera salida", "Ese finde", "Nuestro viaje"], id: \.self) { idea in
                            Button(idea) { title = idea }
                        }
                    }
                }
                Section {
                    TextField("Título", text: $title).textInputAutocapitalization(.sentences)
                    DatePicker("Fecha", selection: $date, displayedComponents: .date)
                    Toggle("Se celebra cada año", isOn: $recursYearly)
                    TextField("Texto opcional", text: $bodyText, axis: .vertical).lineLimit(3...7)
                }
                Section {
                    if catalog != nil {
                        Button("Diseñar página", systemImage: "square.3.layers.3d") { openCanvas() }
                    }
                }
                Section("Foto") {
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let original, original.photo != nil, !removePhoto {
                        MemoryPhotoView(services: services, memory: original).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button("Elegir foto", systemImage: "photo.badge.plus") { choosingPhoto = true }.disabled(loadingPhoto || busy)
                    if photoData != nil || (original?.photo != nil && !removePhoto) {
                        Button("Quitar foto", systemImage: "trash", role: .destructive) { photoData = nil; removePhoto = true; canvasStorage.clear() }
                    }
                    if loadingPhoto { ProgressView("Preparando foto…") }
                }
                Section {
                    Picker("Dibujo vinculado", selection: $noteID) {
                        Text("Ninguno").tag("")
                        if !noteID.isEmpty, !notes.contains(where: { $0.id == noteID }) { Text("Dibujo guardado").tag(noteID) }
                        ForEach(notes) { note in
                            Text("\(note.authorID == services.identity?.uid ? "Tu dibujo" : "De tu pareja") · \(note.serverPublishedAt.formatted(date: .abbreviated, time: .shortened))").tag(note.id)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView("Guardando recuerdo…") }
            }
            .disabled(busy)
            .navigationTitle(original == nil ? "Nuevo recuerdo" : "Editar recuerdo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { if changed { discarding = true } else { finished = true; storage.clear(); dismiss() } }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { save() }.disabled(!canSave) }
            }
            .interactiveDismissDisabled(busy || changed)
            .confirmationDialog("Tu página todavía no está compartida", isPresented: $discarding, titleVisibility: .visible) {
                Button("Guardar borrador y salir") { if persist() { dismiss() } }
                Button("Descartar cambios", role: .destructive) { finished = true; storage.clear(); dismiss() }
                Button("Seguir editando", role: .cancel) {}
            }
            .onChange(of: composition) { _, _ in _ = persist() }
            .onChange(of: photoData) { _, _ in
                guard !finished else { return }
                photoNeedsSaving = true
                _ = persist()
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { _ = persist() } }
            .onDisappear { if !finished { _ = persist() } }
            .fullScreenCover(item: $canvasDraft) { draft in
                if let catalog {
                    NativePaperEditorView(store: catalog, draft: draft, theme: services.personalization.theme,
                        sendTitle: "Usar página", onSavedArchive: attachCanvas, onSaved: {},
                        onSend: { archive in attachCanvas(archive); return true })
                }
            }
            .sheet(item: $crop) { selection in
                PhotoCropEditor(image: selection.image, onCancel: { crop = nil }, onConfirm: { image in
                    photoData = image.jpegData(compressionQuality: 0.85); removePhoto = false; crop = nil
                    // A replacement photo starts a new composition. The prior source remains in Crear.
                    canvasStorage.clear()
                })
            }
            .photoLibrarySheet(isPresented: $choosingPhoto, preparing: $loadingPhoto, onImage: { image in
                guard services.membership?.id == pairID,
                      storage.key == services.privateImageKey("composition:\(original?.id ?? "new")") else { return }
                crop = SelectedPhotoCrop(image: image)
            }, onFailure: { error = $0 })
        }
    }
    private func attachCanvas(_ archive: DraftArchive) {
        guard let bytes = archive.image(for: .final)?.pngData,
              let image = UIImage(data: bytes), let jpeg = image.jpegData(compressionQuality: 0.92) else {
            error = "No se pudo preparar la página. El original sigue en tus borradores."; return
        }
        photoData = jpeg; removePhoto = false; photoNeedsSaving = true
        _ = persist()
    }

    private func openCanvas() {
        guard let catalog, !busy else { return }
        busy = true; error = nil
        let scope = storage.key
        Task { @MainActor in
            defer { busy = false }
            do {
                let reference: ScrapbookSourceReference? = canvasStorage.loadValue()
                if let reference, reference.publishedPhotoID == original?.photo?.id,
                   let summary = try await catalog.list().first(where: { $0.id == reference.draftID }) {
                    guard scope == services.privateImageKey("composition:\(original?.id ?? "new")") else { return }
                    canvasDraft = summary; return
                }
                var markup = PaperMarkup(bounds: PaperProbeDocument.bounds)
                var imageBytes = photoData
                if imageBytes == nil, let original, original.photo != nil, !removePhoto {
                    imageBytes = try await services.memoryPhoto(original)
                }
                if let imageBytes, let cg = UIImage(data: imageBytes)?.cgImage {
                    let ratio = CGFloat(cg.width) / CGFloat(cg.height)
                    let size = ratio > 1 ? CGSize(width: 1300, height: 1300 / ratio) : CGSize(width: 1300 * ratio, height: 1300)
                    markup.insertNewImage(cg, frame: CGRect(x: (1536 - size.width) / 2, y: (1536 - size.height) / 2,
                                                           width: size.width, height: size.height))
                }
                let theme = services.personalization.theme
                let background = PaperBackground(red: UInt8((theme.paperRGB >> 16) & 255),
                    green: UInt8((theme.paperRGB >> 8) & 255), blue: UInt8(theme.paperRGB & 255))
                let source = try await PaperProbeDocument.encode(markup, background: background,
                    layers: [PaperLayer(name: imageBytes == nil ? "Página" : "Foto inicial", markup: markup)])
                let full = try await PaperProbeDocument.render(markup, side: 1536, background: background)
                let widget = try await PaperProbeDocument.render(markup, side: 1024, background: background)
                let thumbnail = try await PaperProbeDocument.render(markup, side: 384, background: background)
                let archive = try DraftArchive.make(id: UUID(), revision: 1, nativeData: source,
                    finalPNG: full, widgetPNG: widget, thumbnailPNG: thumbnail,
                    minimumEditorVersion: PaperProbeDocument.editorVersion)
                let summary = try await catalog.save(archive, title: cleanTitle.isEmpty ? "Página del álbum" : cleanTitle)
                guard scope == services.privateImageKey("composition:\(original?.id ?? "new")") else { return }
                try canvasStorage.saveValue(ScrapbookSourceReference(draftID: summary.id, publishedPhotoID: original?.photo?.id))
                // Commit the memory ID too, so reopening an unsaved page can find its native source.
                try storage.save(composition)
                canvasDraft = summary
            } catch { self.error = "No se pudo abrir la página. Tus cambios siguen guardados; reintentá." }
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard !finished else { return true }
        guard changed else { storage.clear(); return true }
        do {
            if photoNeedsSaving { try storage.savePhoto(photoData); photoNeedsSaving = false }
            try storage.save(composition)
            return true
        }
        catch { self.error = "No se pudo guardar el borrador en este iPhone. No cierres hasta reintentar."; return false }
    }
    private func save() {
        guard canSave, services.membership?.id == pairID,
              storage.key == services.privateImageKey("composition:\(original?.id ?? "new")"), let selectedDate = CoupleDate(date: date, calendar: .current) else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await services.saveMemory(id: id, title: cleanTitle, date: selectedDate, body: bodyText,
                    recursYearly: recursYearly, noteID: noteID.isEmpty ? nil : noteID, photo: photoData, removePhoto: removePhoto, decoration: decoration)
                if var reference: ScrapbookSourceReference = canvasStorage.loadValue() {
                    reference.publishedPhotoID = services.coupleSpace?.memories.first(where: { $0.id == id })?.photo?.id
                    try canvasStorage.saveValue(reference)
                }
                finished = true; storage.clear(); dismiss()
            } catch { self.error = "No se pudo completar el guardado. Reintentá para conservar también la foto." }
        }
    }
}
