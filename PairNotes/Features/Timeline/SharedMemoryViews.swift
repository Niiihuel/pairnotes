import SwiftUI
import PhotosUI
import PairNotesCore

struct SharedMemoriesSection: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    let openNote: (RemoteNote) -> Void
    @State private var adding = false
    @State private var selected: SharedMemory?

    var body: some View {
        if services.membership != nil {
            Section {
                ForEach((services.coupleSpace?.memories ?? []).sorted { $0.date.rawValue > $1.date.rawValue }) { memory in
                    Button { selected = memory } label: {
                        HStack(spacing: 14) {
                            if memory.photo != nil {
                                MemoryPhotoView(services: services, memory: memory).frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                Image(systemName: memory.recursYearly ? "heart.circle.fill" : "calendar.circle.fill")
                                    .font(.system(size: 44)).foregroundStyle(.pink).frame(width: 64, height: 64)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(memory.title).font(.headline)
                                Text(memory.date.date(in: .current)?.formatted(date: .abbreviated, time: .omitted) ?? memory.date.rawValue)
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if memory.recursYearly { Text("Cada año").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
                Button("Agregar una fecha o recuerdo", systemImage: "calendar.badge.plus") { adding = true }
            } header: { Text("Fechas que importan") } footer: {
                Text("Guardá aniversarios, fotos y días especiales. Los dos pueden verlos y editarlos.")
            }
            .sheet(isPresented: $adding) { SharedMemoryEditor(services: services, notes: notes) }
            .sheet(item: $selected) { memory in
                MemoryDetailView(services: services, original: memory, notes: notes, openNote: { note in
                    selected = nil
                    // Avoid presenting the note while the memory sheet dismisses.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard services.membership?.id == note.pairID else { return }
                        openNote(note)
                    }
                })
            }
            .onChange(of: services.identity?.uid) { _, _ in adding = false; selected = nil }
            .onChange(of: services.membership?.id) { _, _ in adding = false; selected = nil }
        }
    }
}

struct MemoryPhotoView: View {
    @ObservedObject var services: AppServices
    let memory: SharedMemory
    @State private var image: UIImage?
    @State private var loadedKey: String?
    @State private var failed = false
    private var key: String { "\(services.identity?.uid ?? "")|\(services.membership?.id ?? "")|\(memory.id)|\(memory.photo?.id ?? "")" }
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if loadedKey == key, let image { Image(uiImage: image).resizable().scaledToFill().privacySensitive() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView() }
        }.clipped().task(id: key) {
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
    let openNote: (RemoteNote) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var calendarSheet = false
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
                } else {
                if memory.photo != nil {
                    MemoryPhotoView(services: services, memory: memory).frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 18)).listRowInsets(EdgeInsets())
                }
                Section {
                    Text(memory.title).font(.title2.bold())
                    Text(memory.date.date(in: .current)?.formatted(date: .long, time: .omitted) ?? memory.date.rawValue)
                        .foregroundStyle(.secondary)
                    if !memory.body.isEmpty { Text(memory.body).privacySensitive() }
                }
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
            .sheet(isPresented: $editing) { SharedMemoryEditor(services: services, notes: notes, memory: memory) }
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
                        do { try await services.deleteMemory(memory); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { Text("El dibujo vinculado y los eventos ya agregados al Calendario se conservan.") }
        }
    }
}

struct SharedMemoryEditor: View {
    @ObservedObject var services: AppServices
    let notes: [RemoteNote]
    let original: SharedMemory?
    private let pairID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var id: String
    @State private var title: String
    @State private var date: Date
    @State private var bodyText: String
    @State private var recursYearly: Bool
    @State private var noteID: String
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var removePhoto = false
    @State private var loadingPhoto = false
    @State private var crop: SelectedPhotoCrop?
    @State private var busy = false
    @State private var discarding = false
    @State private var error: String?
    private let originalDate: CoupleDate?

    init(services: AppServices, notes: [RemoteNote], memory: SharedMemory? = nil) {
        self.services = services; self.notes = notes; original = memory; pairID = services.membership?.id
        _id = State(initialValue: memory?.id ?? UUID().uuidString.lowercased())
        _title = State(initialValue: memory?.title ?? "")
        let initialDate = memory?.date.date(in: .current) ?? Date()
        _date = State(initialValue: initialDate)
        originalDate = CoupleDate(date: initialDate, calendar: .current)
        _bodyText = State(initialValue: memory?.body ?? "")
        _recursYearly = State(initialValue: memory?.recursYearly ?? false)
        _noteID = State(initialValue: memory?.noteId ?? "")
    }
    private var changed: Bool {
        title != (original?.title ?? "") || CoupleDate(date: date, calendar: .current) != originalDate ||
        bodyText != (original?.body ?? "") || recursYearly != (original?.recursYearly ?? false) ||
        noteID != (original?.noteId ?? "") || photoData != nil || removePhoto
    }
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !busy && !loadingPhoto && (1...120).contains(cleanTitle.utf16.count) && bodyText.utf16.count <= 2_000 && changed }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Por ejemplo, nuestro aniversario", text: $title).textInputAutocapitalization(.sentences)
                    DatePicker("Fecha", selection: $date, displayedComponents: .date)
                    Toggle("Se celebra cada año", isOn: $recursYearly)
                    TextField("Unas palabras sobre este día", text: $bodyText, axis: .vertical).lineLimit(3...7)
                }
                Section("Una foto") {
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let original, original.photo != nil, !removePhoto {
                        MemoryPhotoView(services: services, memory: original).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) { Label("Elegir foto", systemImage: "photo.badge.plus") }
                    if photoData != nil || (original?.photo != nil && !removePhoto) {
                        Button("Quitar foto", systemImage: "trash", role: .destructive) { photoData = nil; removePhoto = true }
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
                } footer: { Text("La fecha se guarda en PairNotes. Después podés agregarla al Calendario de Apple con su formulario nativo.") }
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView("Guardando recuerdo…") }
            }
            .disabled(busy)
            .navigationTitle(original == nil ? "Nuevo recuerdo" : "Editar recuerdo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { if changed { discarding = true } else { dismiss() } }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { save() }.disabled(!canSave) }
            }
            .interactiveDismissDisabled(busy || changed)
            .confirmationDialog("¿Descartar los cambios?", isPresented: $discarding, titleVisibility: .visible) {
                Button("Descartar cambios", role: .destructive) { dismiss() }
                Button("Seguir editando", role: .cancel) {}
            }
            .sheet(item: $crop) { selection in
                PhotoCropEditor(image: selection.image, onCancel: { crop = nil }, onConfirm: { image in
                    photoData = image.jpegData(compressionQuality: 0.85); removePhoto = false; crop = nil
                })
            }
            .task(id: photoItem) {
                guard let photoItem else { return }
                loadingPhoto = true
                defer { if self.photoItem == photoItem { loadingPhoto = false } }
                do {
                    guard let bytes = try await photoItem.loadTransferable(type: Data.self), !Task.isCancelled, self.photoItem == photoItem,
                          let image = UIImage(data: try SelectedPhoto.jpeg(bytes)) else { return }
                    crop = SelectedPhotoCrop(image: image)
                } catch { self.error = "No se pudo abrir esta foto. Elegí otra imagen." }
            }
        }
    }
    private func save() {
        guard canSave, services.membership?.id == pairID, let selectedDate = CoupleDate(date: date, calendar: .current) else { return }
        busy = true; error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await services.saveMemory(id: id, title: cleanTitle, date: selectedDate, body: bodyText,
                    recursYearly: recursYearly, noteID: noteID.isEmpty ? nil : noteID, photo: photoData, removePhoto: removePhoto)
                dismiss()
            } catch { self.error = "No se pudo completar el guardado. Reintentá para conservar también la foto." }
        }
    }
}
