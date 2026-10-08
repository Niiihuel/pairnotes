import PairNotesCore
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
    let startsWithVoice: Bool
    private let storage: MemoryCompositionStorage
    private let scope: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var voice = VoiceNoteController()
    @State private var draft: LetterComposition
    @State private var photoDirty = false
    @State private var audioDirty = false
    @State private var drawingDirty = false
    @State private var makingDrawing = false
    @State private var drawing: Data?
    @State private var photo: Data?
    @State private var audio: Data?
    @State private var choosingPhoto = false
    @State private var crop: SelectedPhotoCrop?
    @State private var loadingPhoto = false
    @State private var busy = false
    @State private var finished = false
    @State private var confirm = false
    @State private var confirmDiscard = false
    @State private var confirmRerecord = false
    @State private var showingAttachments = false
    @FocusState private var writing: Bool
    @State private var error: String?

    init(services: AppServices, notes: [RemoteNote], catalog: DraftCatalogStore? = nil, original: TimeCapsuleLetter? = nil, startsWithVoice: Bool = false) {
        self.services = services; self.notes = notes; self.original = original; self.catalog = catalog
        self.startsWithVoice = startsWithVoice
        scope = services.privateImageKey("letters")
        let draftKey = original?.id ?? (startsWithVoice ? "voice" : "new")
        let storage = MemoryCompositionStorage(key: services.privateImageKey("letter-composition:" + draftKey))
        self.storage = storage
        _draft = State(initialValue: storage.loadValue() ?? LetterComposition(id: original?.id ?? UUID().uuidString.lowercased(),
            title: original?.title ?? (startsWithVoice ? "Mi voz para vos" : ""), body: original?.body ?? "", opensAt: original?.opensAt ?? Date().addingTimeInterval(86400), noteID: original?.noteId ?? ""))
        _drawing = State(initialValue: storage.drawing())
        _photo = State(initialValue: storage.photo()); _audio = State(initialValue: storage.audio())
    }
    private var canSend: Bool {
        !busy && !voice.recording && !voice.requestingPermission && !loadingPhoto &&
        (draft.sealAttempted || (!draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.title.utf16.count <= 120 &&
            draft.body.utf16.count <= 6000 && draft.opensAt > Date() &&
            hasContent))
    }
    private var hasAudio: Bool { audio != nil || (original?.audio != nil && !draft.removeAudio) }
    private var hasContent: Bool {
        if startsWithVoice { return hasAudio }
        return !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil || hasAudio ||
            drawing != nil || (original?.drawing != nil && draft.removeDrawing != true) ||
            !draft.noteID.isEmpty || (original?.photo != nil && !draft.removePhoto)
    }
    private var sendHint: String {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Agregá un título." }
        if draft.title.utf16.count > 120 { return "El título puede tener hasta 120 caracteres." }
        if draft.body.utf16.count > 6000 { return "Tu carta puede tener hasta 6000 caracteres." }
        if draft.opensAt <= Date() { return "Elegí una fecha futura para abrir el sobre." }
        if loadingPhoto { return "Estamos preparando la foto." }
        return startsWithVoice ? "Grabá tu audio para enviarlo." : "Sumá unas palabras o un adjunto."
    }
    private var sealSummary: String {
        let date = draft.opensAt.formatted(date: .long, time: .shortened)
        return "Para \(services.partnerNickname) · \(draft.title)\nSe abre el \(date).\nUna vez enviada, no se puede cambiar el contenido ni la fecha."
    }
    private var stationery: LetterStationeryPalette { LetterStationeryPalette(dark: colorScheme == .dark) }
    private var authorName: String {
        guard let identity = services.identity else { return "Yo" }
        return services.personalization.name(for: identity.uid, fallback: identity.displayName)
    }
    private var attachmentCount: Int {
        (photo != nil || (original?.photo != nil && !draft.removePhoto) ? 1 : 0) +
        (audio != nil || (original?.audio != nil && !draft.removeAudio) ? 1 : 0) +
        (drawing != nil || (original?.drawing != nil && draft.removeDrawing != true) ? 1 : 0) +
        (draft.noteID.isEmpty ? 0 : 1)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if startsWithVoice { audioEditor }
                    else {
                        LetterPaper {
                            VStack(alignment: .leading, spacing: 22) {
                                recipientSection
                                writingSection
                                Text(authorName).font(.system(.title3, design: .serif).italic())
                                    .foregroundStyle(stationery.accent)
                            }
                        }
                    }
                    scheduleSection
                    if !startsWithVoice {
                        Button {
                            writing = false; showingAttachments = true
                        } label: {
                            HStack {
                                Label(attachmentCount == 0 ? "Adjuntar" : "Adjuntos · \(attachmentCount)", systemImage: "paperclip")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }.padding(.vertical, 12)
                        }.buttonStyle(.plain).foregroundStyle(stationery.accent)
                            .disabled(busy || draft.sealAttempted)
                            .accessibilityIdentifier("letter.attachments")
                    }
                    statusSection
                }.frame(maxWidth: 640).padding(20).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(stationery.canvas)
            .safeAreaInset(edge: .bottom) { sendBar }
            .navigationTitle(startsWithVoice ? "Tu voz" : "Escribir carta").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Listo") { voice.stopAll(); if persist() { dismiss() } }.disabled(busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Descartar borrador", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Opciones del borrador").disabled(busy || draft.sealAttempted)
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Listo") { writing = false } }
            }
            .confirmationDialog(startsWithVoice ? "¿Enviar este audio?" : "¿Cerrar y enviar esta carta?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Enviar para el \(draft.opensAt.formatted(date: .abbreviated, time: .shortened))") { send() }
                Button("Seguir editando", role: .cancel) {}
            } message: { Text(sealSummary) }
            .confirmationDialog(startsWithVoice ? "¿Descartar el audio en borrador?" : "¿Descartar esta carta en borrador?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Descartar borrador", role: .destructive) { deleteDraft() }
                Button("Seguir editando", role: .cancel) {}
            }
            .interactiveDismissDisabled(busy || voice.recording || draft.sealAttempted)
            .onChange(of: draft) { _, _ in if !finished { _ = persist() } }
            .onAppear {
                voice.didRecord = { data in audio = data; draft.removeAudio = false; persistAudio() }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background || (phase == .inactive && !voice.requestingPermission) { voice.suspend(); _ = persist() } }
            .onDisappear { voice.stopAll(); if !finished { _ = persist() }; voice.didRecord = nil }
            .onChange(of: services.privateImageKey("letters")) { _, value in if value != scope { voice.stopAll(); dismiss() } }
            .sheet(isPresented: $showingAttachments, onDismiss: { voice.stopAll() }) { attachmentEditor }
        }.tint(stationery.accent)
    }

    private var audioEditor: some View {
        VStack(alignment: .leading, spacing: 22) {
            recipientSection
            TextField("Título del audio", text: $draft.title,
                      prompt: Text("Título del audio").foregroundStyle(stationery.secondaryInk))
                .font(.title3).focused($writing).accessibilityLabel("Título del audio").accessibilityIdentifier("voice.title")
            voiceContents
            Text("Hasta 1 minuto").font(.caption).foregroundStyle(stationery.secondaryInk)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(stationery.ink).background(stationery.paper, in: RoundedRectangle(cornerRadius: 18))
        .disabled(busy || draft.sealAttempted)
        .confirmationDialog("¿Grabar otra vez?", isPresented: $confirmRerecord, titleVisibility: .visible) {
            Button("Grabar otra vez") { Task { await voice.record() } }
            Button("Conservar audio", role: .cancel) {}
        } message: { Text("Tu audio actual se conserva hasta terminar la nueva toma.") }
    }

    private var attachmentEditor: some View {
        NavigationStack {
            Form {
                attachmentsSection
                voiceSection
            }
            .scrollContentBackground(.hidden).background(stationery.canvas)
            .navigationTitle("Adjuntos").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { showingAttachments = false }.disabled(voice.recording || voice.requestingPermission || busy)
                }
            }
            .interactiveDismissDisabled(voice.recording || voice.requestingPermission || busy)
            .confirmationDialog("¿Grabar otra vez?", isPresented: $confirmRerecord, titleVisibility: .visible) {
                Button("Grabar otra vez") { Task { await voice.record() } }
                Button("Conservar audio", role: .cancel) {}
            } message: { Text("Tu audio actual se conserva hasta terminar la nueva toma.") }
            .sheet(isPresented: $makingDrawing) {
                if let catalog {
                    NativePaperEditorView(store: catalog, draft: nil, theme: services.personalization.theme,
                        sendTitle: "Usar en la carta", onSavedArchive: attachDrawing, onSaved: {},
                        onSend: { archive in attachDrawing(archive); return drawing != nil })
                }
            }
            .sheet(item: $crop) { selection in
                PhotoCropEditor(image: selection.image, onCancel: { crop = nil }, onConfirm: { image in
                    photo = image.jpegData(compressionQuality: 0.85); draft.removePhoto = false; persistPhoto(); crop = nil
                })
            }
            .photoLibrarySheet(isPresented: $choosingPhoto, preparing: $loadingPhoto, onImage: { image in
                guard scope == services.privateImageKey("letters") else { return }
                crop = SelectedPhotoCrop(image: image)
            }, onFailure: { error = $0 })
        }
    }
    @ViewBuilder private var recipientSection: some View {
        Text("Para " + services.partnerNickname)
            .font(.subheadline.weight(.medium)).foregroundStyle(stationery.accent)
    }

    @ViewBuilder private var writingSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            TextField("Un título", text: $draft.title,
                      prompt: Text("Un título").foregroundStyle(stationery.secondaryInk))
                .font(.system(.title2, design: .serif)).focused($writing)
                .accessibilityLabel("Título de la carta").accessibilityIdentifier("letter.title")
            TextField("Querido amor…", text: $draft.body,
                      prompt: Text("Querido amor…").foregroundStyle(stationery.secondaryInk), axis: .vertical)
                .lineLimit(8...30).font(.system(.body, design: .serif)).lineSpacing(8).focused($writing)
                .accessibilityLabel("Contenido de la carta").accessibilityIdentifier("letter.body")
            if draft.body.utf16.count >= 5400 {
                Text("\(draft.body.utf16.count)/6000").font(.caption).foregroundStyle(stationery.secondaryInk)
            }
        }.disabled(busy || draft.sealAttempted)
    }

    @ViewBuilder private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                Text("Se abre").font(.subheadline)
                openingDatePicker.labelsHidden().accessibilityLabel("Fecha y hora de apertura")
            } else { openingDatePicker }
            Text(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
                .font(.caption).foregroundStyle(stationery.secondaryInk)
        }.padding(16).background(stationery.paper, in: RoundedRectangle(cornerRadius: 12))
            .disabled(busy || draft.sealAttempted)
    }

    private var openingDatePicker: some View {
        DatePicker("Se abre", selection: $draft.opensAt, in: Date()...Date().addingTimeInterval(5 * 365 * 86400))
            .datePickerStyle(.compact).accessibilityIdentifier("letter.opensAt")
    }

    @ViewBuilder private var attachmentsSection: some View {
        Section("Foto o dibujo") {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
            } else if original?.photo != nil && !draft.removePhoto { Label("Foto adjunta guardada", systemImage: "photo") }
            Button("Agregar foto", systemImage: "photo.badge.plus") { choosingPhoto = true }.disabled(loadingPhoto || busy)
            if photo != nil || (original?.photo != nil && !draft.removePhoto) {
                Button("Quitar foto", role: .destructive) { photo = nil; draft.removePhoto = true; persistPhoto() }
            }
            if loadingPhoto { ProgressView("Preparando foto…") }
            if let drawing, let image = UIImage(data: drawing) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
            } else if original?.drawing != nil && draft.removeDrawing != true { Label("Dibujo privado adjunto", systemImage: "paintpalette") }
            if catalog != nil {
                Button("Dibujar", systemImage: "pencil.tip.crop.circle") { makingDrawing = true }
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
    }

    @ViewBuilder private var voiceSection: some View {
        Section {
            voiceContents
        } header: { Label("Voz", systemImage: "waveform") }
          footer: { Text("Hasta 1 minuto") }
          .disabled(busy || draft.sealAttempted)
    }

    @ViewBuilder private var voiceContents: some View {
        if voice.recording {
            VoiceRecordingMeter(controller: voice)
        } else {
            if let audio {
                VoicePlaybackControls(player: voice, data: audio, title: "Tu voz", displaysNotice: false)
            } else if let original, original.audio != nil && !draft.removeAudio && !voice.requestingPermission {
                LetterVoicePlayer(services: services, letter: original)
            } else {
                EmptyView()
            }
            Button(hasAudio ? "Grabar otra vez" : "Grabar mi voz", systemImage: "mic.fill") {
                writing = false
                if hasAudio { confirmRerecord = true }
                else { Task { await voice.record() } }
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .foregroundStyle(colorScheme == .dark ? stationery.canvas : .white)
                .disabled(voice.requestingPermission).accessibilityIdentifier("voice.record")
            if voice.requestingPermission { ProgressView("Esperando permiso del micrófono…") }
            if hasAudio {
                Button("Quitar audio", role: .destructive) { voice.stopAll(); audio = nil; draft.removeAudio = true; persistAudio() }
                    .frame(minHeight: 44)
            }
        }
        VoiceControllerNotice(controller: voice)
    }

    @ViewBuilder private var statusSection: some View {
        if let error { Text(error).font(.footnote).foregroundStyle(stationery.secondaryInk) }
        if draft.sealAttempted { Text("El envío está pendiente de confirmación.").font(.footnote).foregroundStyle(stationery.secondaryInk) }
        if busy { ProgressView("Enviando…") }
    }

    private var sendBar: some View {
        VStack(spacing: 8) {
            if !canSend && !busy && !voice.recording && !draft.sealAttempted {
                Text(sendHint).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                writing = false
                if draft.sealAttempted { send() } else { confirm = true }
            } label: {
                Label(busy ? "Enviando…" : draft.sealAttempted ? "Confirmar envío" : startsWithVoice ? "Enviar audio" : "Enviar carta",
                      systemImage: startsWithVoice ? "paperplane.fill" : "envelope.fill").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canSend)
                .foregroundStyle(canSend ? (colorScheme == .dark ? stationery.canvas : .white) : stationery.secondaryInk)
        }.padding().background(.regularMaterial)
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
                self.error = startsWithVoice ? "No se pudo confirmar el audio. Revisá la fecha de apertura; tu grabación se conserva." :
                    "No se pudo confirmar la carta. Revisá que la fecha siga siendo futura; tu borrador y adjuntos se conservan."
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
