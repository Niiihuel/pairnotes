import AVFoundation
import PairNotesCore
import PhotosUI
import SwiftUI

struct LetterComposition: Codable, Equatable {
    var id: String
    var title: String
    var body: String
    var opensAt: Date
    var noteID: String
    var removePhoto = false
    var serverSaved: Bool?
    var removeDrawing: Bool?
    var removeAudio = false
    var sealAttempted = false
}

struct LetterComposer: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    let original: TimeCapsuleLetter?
    let catalog: DraftCatalogStore?
    private let storage: MemoryCompositionStorage
    private let scope: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var voice = VoiceNoteController()
    @State private var draft: LetterComposition
    @State private var photoDirty = false
    @State private var audioDirty = false
    @State private var drawingDirty = false
    @State private var makingDrawing = false
    @State private var drawing: Data?
    @State private var photo: Data?
    @State private var audio: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var crop: SelectedPhotoCrop?
    @State private var loadingPhoto = false
    @State private var busy = false
    @State private var finished = false
    @State private var confirm = false
    @State private var confirmDiscard = false
    @State private var confirmRerecord = false
    @FocusState private var writing: Bool
    @State private var error: String?

    init(services: AppServices, notes: [RemoteNote], catalog: DraftCatalogStore? = nil, original: TimeCapsuleLetter? = nil) {
        self.services = services; self.notes = notes; self.original = original; self.catalog = catalog
        scope = services.privateImageKey("letters")
        let storage = MemoryCompositionStorage(key: services.privateImageKey("letter-composition:" + (original?.id ?? "new")))
        self.storage = storage
        _draft = State(initialValue: storage.loadValue() ?? LetterComposition(id: original?.id ?? UUID().uuidString.lowercased(),
            title: original?.title ?? "", body: original?.body ?? "", opensAt: original?.opensAt ?? Date().addingTimeInterval(86400), noteID: original?.noteId ?? ""))
        _drawing = State(initialValue: storage.drawing())
        _photo = State(initialValue: storage.photo()); _audio = State(initialValue: storage.audio())
    }
    private var canSend: Bool {
        !busy && !voice.recording && !voice.requestingPermission && !loadingPhoto &&
        (draft.sealAttempted || (!draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.title.utf16.count <= 120 &&
            draft.body.utf16.count <= 6000 && draft.opensAt > Date() &&
            (!draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil || audio != nil || drawing != nil || (original?.drawing != nil && draft.removeDrawing != true) ||
             !draft.noteID.isEmpty || (original?.photo != nil && !draft.removePhoto) || (original?.audio != nil && !draft.removeAudio))))
    }
    private var sendHint: String {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Poné un título para reconocer esta carta." }
        if draft.title.utf16.count > 120 { return "El título puede tener hasta 120 caracteres." }
        if draft.body.utf16.count > 6000 { return "Tu carta puede tener hasta 6000 caracteres." }
        if draft.opensAt <= Date() { return "Elegí una fecha futura para abrir el sobre." }
        if loadingPhoto { return "Estamos preparando la foto." }
        return "Sumá unas palabras, una foto, un dibujo o tu voz."
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Para " + services.partnerNickname, systemImage: "envelope.badge")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(services.personalization.theme.accent)
                        Text("Algo tuyo, para su momento").font(.system(.title2, design: .serif))
                        Text("Escribí con calma. El borrador se conserva en este iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }.listRowBackground(services.personalization.theme.paper)
                Section {
                    TextField("Un título sólo para ustedes", text: $draft.title)
                        .font(.system(.title3, design: .serif)).focused($writing)
                    TextField("Querido amor…", text: $draft.body, axis: .vertical).lineLimit(6...18).font(.system(.body, design: .serif)).lineSpacing(5).focused($writing)
                    Text("\(draft.body.utf16.count)/6000").font(.caption).foregroundStyle(.secondary)
                } header: { Label("Tu carta", systemImage: "text.alignleft") }
                  .disabled(busy || draft.sealAttempted)
                Section {
                    Menu("Elegir un momento", systemImage: "calendar.badge.clock") {
                        Button("Mañana a esta hora") { draft.opensAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86400) }
                        Button("Dentro de una semana") { draft.opensAt = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date().addingTimeInterval(604800) }
                    }
                    DatePicker("Se abre", selection: $draft.opensAt, in: Date()...Date().addingTimeInterval(5 * 365 * 86400))
                    Text("Hora de " + (TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Tu pareja verá un sobre cerrado. El contenido aparecerá a la hora elegida.").font(.footnote).foregroundStyle(.secondary)
                }.disabled(busy || draft.sealAttempted)
                Section("Detalles para acompañarla") {
                    if let photo, let image = UIImage(data: photo) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    } else if original?.photo != nil && !draft.removePhoto { Label("Foto adjunta guardada", systemImage: "photo") }
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Agregar foto", systemImage: "photo.badge.plus") }
                    if photo != nil || (original?.photo != nil && !draft.removePhoto) {
                        Button("Quitar foto", role: .destructive) { photo = nil; draft.removePhoto = true; persistPhoto() }
                    }
                    if loadingPhoto { ProgressView("Preparando foto…") }
                    if let drawing, let image = UIImage(data: drawing) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    } else if original?.drawing != nil && draft.removeDrawing != true { Label("Dibujo privado adjunto", systemImage: "paintpalette") }
                    if catalog != nil {
                        Button("Crear dibujo privado para la carta", systemImage: "pencil.tip.crop.circle") { makingDrawing = true }
                    }
                    if drawing != nil || (original?.drawing != nil && draft.removeDrawing != true) {
                        Button("Quitar dibujo privado", role: .destructive) {
                            drawing = nil; draft.removeDrawing = true
                            drawingDirty = true; _ = persist()
                        }
                    }
                    Picker("Dibujo compartido", selection: $draft.noteID) {
                        Text("Ninguno").tag("")
                        if !draft.noteID.isEmpty && !notes.contains(where: { $0.id == draft.noteID }) { Text("Dibujo adjunto guardado").tag(draft.noteID) }
                        ForEach(notes) { note in Text(note.serverPublishedAt.formatted(date: .abbreviated, time: .shortened)).tag(note.id) }
                    }
                }.disabled(busy || draft.sealAttempted)
                Section {
                    if voice.recording {
                        VoiceRecordingMeter(controller: voice)
                    } else {
                        if let audio {
                            VoicePlaybackControls(player: voice, data: audio, title: "Así va a escuchar tu voz")
                        } else if let original, original.audio != nil && !draft.removeAudio && !voice.requestingPermission {
                            LetterVoicePlayer(services: services, letter: original)
                        } else {
                            Label("A veces, escucharte lo dice todo.", systemImage: "waveform")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button(audio == nil && original?.audio == nil ? "Grabar mi voz" : "Grabar otra vez", systemImage: "mic.fill") {
                            writing = false
                            if audio != nil || (original?.audio != nil && !draft.removeAudio) { confirmRerecord = true }
                            else { Task { await voice.record() } }
                        }.disabled(voice.requestingPermission)
                        if voice.requestingPermission { ProgressView("Esperando permiso del micrófono…") }
                        if audio != nil || (original?.audio != nil && !draft.removeAudio) {
                            Button("Quitar audio", role: .destructive) { voice.stopAll(); audio = nil; draft.removeAudio = true; persistAudio() }
                        }
                    }
                    if let error = voice.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: { Label("Un poquito de tu voz", systemImage: "waveform") }
                  footer: { Text("Opcional · hasta 1 minuto. Tu pareja lo escuchará al abrir la carta.") }
                  .disabled(busy || draft.sealAttempted)
                if let error { Text(error).foregroundStyle(.secondary) }
                if draft.sealAttempted { Text("El envío quedó sin confirmar. Verificá su estado antes de seguir editando para evitar dos cartas.").font(.footnote) }
                if busy { ProgressView("Preparando tu sorpresa…") }
                if !draft.sealAttempted {
                    Section { Button("Descartar borrador", role: .destructive) { confirmDiscard = true }.disabled(busy) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(services.personalization.theme.canvas)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !canSend && !busy && !voice.recording && !draft.sealAttempted {
                        Text(sendHint).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        writing = false
                        if draft.sealAttempted { send() } else { confirm = true }
                    } label: {
                        Label(busy ? "Preparando tu sorpresa…" : draft.sealAttempted ? "Confirmar envío" : "Revisar y cerrar el sobre",
                              systemImage: "envelope.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canSend)
                }.padding().background(.regularMaterial)
            }
            .navigationTitle("Una carta para después").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Guardar y salir") { voice.stopAll(); if persist() { dismiss() } }.disabled(busy) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Listo") { writing = false } }
            }
            .confirmationDialog("¿Grabar una nueva nota de voz?", isPresented: $confirmRerecord, titleVisibility: .visible) {
                Button("Grabar otra vez") { Task { await voice.record() } }
                Button("Conservar la actual", role: .cancel) {}
            } message: { Text("La grabación actual se reemplazará cuando termines la nueva.") }
            .confirmationDialog("¿Cerrar y enviar esta carta?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Enviar para el \(draft.opensAt.formatted(date: .abbreviated, time: .shortened))") { send() }
                Button("Seguir escribiendo", role: .cancel) {}
            } message: { Text("Para " + services.partnerNickname + " · " + draft.title + "\nSe abre el " + draft.opensAt.formatted(date: .long, time: .shortened) + ".\nUna vez enviada, no se puede cambiar el contenido ni la fecha.") }
            .confirmationDialog("¿Descartar esta carta en borrador?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Descartar borrador", role: .destructive) { deleteDraft() }
                Button("Seguir escribiendo", role: .cancel) {}
            }
            .interactiveDismissDisabled(busy || voice.recording || draft.sealAttempted)
            .onChange(of: draft) { _, _ in if !finished { _ = persist() } }
            .onAppear {
                voice.didRecord = { data in audio = data; draft.removeAudio = false; persistAudio() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background || (phase == .inactive && !voice.requestingPermission) { voice.suspend(); _ = persist() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in voice.suspend() }
            .onDisappear { voice.stopAll(); if !finished { _ = persist() }; voice.didRecord = nil }
            .onChange(of: services.privateImageKey("letters")) { _, value in if value != scope { voice.stopAll(); dismiss() } }
            .sheet(isPresented: $makingDrawing) {
                if let catalog {
                    NativePaperEditorView(store: catalog, draft: nil, theme: services.personalization.theme,
                        sendTitle: "Usar en la carta", onSavedArchive: attachDrawing, onSaved: {},
                        onSend: { archive in attachDrawing(archive); return drawing != nil })
                }
            }
            .sheet(item: $crop, onDismiss: { photoItem = nil }) { selection in
                PhotoCropEditor(image: selection.image, onCancel: { crop = nil }, onConfirm: { image in
                    photo = image.jpegData(compressionQuality: 0.85); draft.removePhoto = false; persistPhoto(); crop = nil
                })
            }
            .task(id: photoItem) {
                guard let photoItem else { return }
                loadingPhoto = true; defer { loadingPhoto = false }
                do {
                    guard let bytes = try await photoItem.loadTransferable(type: Data.self), !Task.isCancelled,
                          let image = UIImage(data: try SelectedPhoto.jpeg(bytes)) else { return }
                    crop = SelectedPhotoCrop(image: image)
                } catch { self.error = "No se pudo cargar la foto." }
            }
        }
    }
    @discardableResult private func persist() -> Bool {
        guard !finished else { return true }
        do {
            if photoDirty { try storage.savePhoto(photo); photoDirty = false }
            if audioDirty { try storage.saveAudio(audio); audioDirty = false }
            if drawingDirty { try storage.saveDrawing(drawing); drawingDirty = false }
            try storage.saveValue(draft); return true
        }
        catch { self.error = "No se pudo guardar el borrador en este iPhone."; return false }
    }
    private func persistPhoto() {
        photoDirty = true; _ = persist()
    }
    private func persistAudio() {
        audioDirty = true; _ = persist()
    }
    private func attachDrawing(_ archive: DraftArchive) {
        guard services.privateImageKey("letters") == scope, let bytes = archive.image(for: .final)?.pngData else { return }
        drawing = bytes; draft.removeDrawing = false
        drawingDirty = true; _ = persist()
    }
    private func completed() { finished = true; storage.clear(); dismiss() }
    private func send() {
        guard canSend, services.privateImageKey("letters") == scope else { return }
        voice.stopAll(); guard persist() else { return }; busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                if draft.sealAttempted {
                    let existing = try await services.openLetter(id: draft.id)
                    if existing.status == "sealed" { completed(); return }
                    draft.sealAttempted = false
                }
                _ = try await services.saveLetterDraft(id: draft.id, title: draft.title, body: draft.body,
                    opensAt: draft.opensAt, noteID: draft.noteID.isEmpty ? nil : draft.noteID)
                draft.serverSaved = true; guard persist() else { return }
                if let photo { try await services.uploadLetterAsset(id: draft.id, role: "photo", data: photo) }
                else if draft.removePhoto { try await services.removeLetterAsset(id: draft.id, role: "photo") }
                if let drawing { try await services.uploadLetterAsset(id: draft.id, role: "drawing", data: drawing) }
                else if draft.removeDrawing == true { try await services.removeLetterAsset(id: draft.id, role: "drawing") }
                if let audio { try await services.uploadLetterAsset(id: draft.id, role: "audio", data: audio) }
                else if draft.removeAudio { try await services.removeLetterAsset(id: draft.id, role: "audio") }
                draft.sealAttempted = true
                guard persist() else { return }
                _ = try await services.sealLetter(id: draft.id)
                completed()
            } catch {
                if draft.sealAttempted, let known = try? await services.openLetter(id: draft.id), known.status == "draft" {
                    draft.sealAttempted = false; _ = persist()
                }
                self.error = "No se pudo confirmar la carta. Revisá que la fecha siga siendo futura; tu borrador y adjuntos se conservan."
            }
        }
    }
    private func deleteDraft() {
        guard !busy, services.privateImageKey("letters") == scope else { return }
        voice.stopAll()
        if original == nil && draft.serverSaved != true { completed(); return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await services.deleteLetterDraft(id: draft.id); completed() }
            catch { self.error = "No se pudo eliminar el borrador." }
        }
    }
}
