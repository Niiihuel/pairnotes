import SwiftUI
import UIKit
import PaperKit
import PairNotesCore
import PhotosUI
import ImageIO

@MainActor
final class NativePaperSession: ObservableObject {
    let controller = PaperProbeController()
    @Published var busy = false
    @Published var readOnly = false
    @Published var status = "Tu borrador se guarda en este iPhone."
    @Published var preview: UIImage?
    @Published var title: String { didSet { if title != oldValue { changed() } } }
    @Published var selecting = false {
        didSet { controller.canvas.directTouchMode = selecting ? .selection : .drawing }
    }
    private let store: DraftCatalogStore
    private let documentID: UUID
    private let existing: Bool
    private var loaded = false
    private var revision: UInt64 = 0
    private var mutation: UInt64 = 0
    private var savedMutation: UInt64?
    private var lastArchive: DraftArchive?
    private var autosave: Task<Void, Never>?

    init(store: DraftCatalogStore, draft: DraftSummary?) {
        self.store = store
        documentID = draft?.id ?? UUID()
        existing = draft != nil
        title = draft?.title ?? "Sin título"
        controller.onMarkupChanged = { [weak self] in self?.changed() }
    }

    func load() async {
        guard !loaded else { return }
        busy = true
        defer { busy = false; loaded = true }
        guard existing else { return }
        do {
            guard let archive = try await store.load(id: documentID) else { throw LocalStoreError.corruptData }
            revision = archive.document.revision
            preview = archive.image(for: .final).flatMap { UIImage(data: $0.pngData) }
            lastArchive = archive
            guard archive.document.isEditable else { throw ProbeError.incompatibleDocument }
            let markup = try PaperMarkup(dataRepresentation: archive.source.data)
            guard markup.featureSet.isSubset(of: PaperProbeDocument.supportedFeatures) else {
                throw ProbeError.incompatibleDocument
            }
            controller.canvas.markup = markup
            savedMutation = mutation
            status = "Borrador guardado en este iPhone."
        } catch {
            readOnly = true
            status = "Este borrador no se puede editar con esta versión. Conservamos su archivo y su imagen."
        }
    }

    func changed() {
        guard loaded, !readOnly else { return }
        mutation &+= 1
        status = "Cambios sin guardar…"
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            _ = await self.save()
        }
    }

    /// One immutable native capture produces every render. No local edit writes
    /// the received-note widget or changes a previously published note.
    func save() async -> DraftArchive? {
        guard loaded, !busy else { return nil }
        if readOnly { return lastArchive }
        if savedMutation == mutation, let lastArchive { return lastArchive }
        busy = true
        defer { busy = false }
        let capturedMutation = mutation
        do {
            guard let captured = controller.canvas.markup else { throw ProbeError.missingMarkup }
            let (nextRevision, overflow) = revision.addingReportingOverflow(1)
            guard !overflow else { throw LocalStoreError.obsoleteRevision }
            let source = try await captured.dataRepresentation()
            let persisted = try PaperMarkup(dataRepresentation: source)
            let full = try await PaperProbeDocument.render(persisted, side: 1536)
            let widget = try await PaperProbeDocument.render(persisted, side: 1024)
            let thumb = try await PaperProbeDocument.render(persisted, side: 384)
            let archive = try DraftArchive.make(id: documentID, revision: nextRevision, nativeData: source,
                                                finalPNG: full, widgetPNG: widget, thumbnailPNG: thumb)
            try await store.save(archive, title: title)
            revision = nextRevision
            savedMutation = capturedMutation
            lastArchive = archive
            preview = UIImage(data: full)
            status = "Guardado en este iPhone."
            return archive
        } catch {
            status = "No se pudo guardar. Reintentá antes de cerrar."
            return nil
        }
    }

    func insertPhoto(_ item: PhotosPickerItem) async {
        guard loaded, !busy, !readOnly else { return }
        busy = true
        defer { busy = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), data.count <= 20 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1536
                  ] as CFDictionary), var markup = controller.canvas.markup else {
                status = "No se pudo importar la foto (máximo 20 MB)."
                return
            }
            let width: CGFloat = 900
            let height = width * CGFloat(image.height) / CGFloat(image.width)
            let scale = min(1, 1000 / height)
            markup.insertNewImage(image, frame: CGRect(x: 250, y: 300, width: width * scale, height: height * scale))
            controller.canvas.markup = markup
            changed()
        } catch { status = "No se pudo cargar la foto seleccionada." }
    }
}

struct NativePaperEditorView: View {
    @StateObject private var session: NativePaperSession
    let onSaved: () -> Void
    let onSend: (DraftArchive) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var sending = false
    @State private var closing = false
    @State private var exportImage: ExportImage?

    init(store: DraftCatalogStore, draft: DraftSummary?, onSaved: @escaping () -> Void,
         onSend: @escaping (DraftArchive) async -> Bool) {
        _session = StateObject(wrappedValue: NativePaperSession(store: store, draft: draft))
        self.onSaved = onSaved
        self.onSend = onSend
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                TextField("Título del borrador", text: $session.title).textFieldStyle(.roundedBorder)
                    .disabled(session.readOnly)
                if session.readOnly {
                    if let preview = session.preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                    } else { ContentUnavailableView("Borrador conservado", systemImage: "doc.lock") }
                } else {
                    PaperProbeCanvas(controller: session.controller, enabled: !session.busy && !sending && !closing)
                        .frame(minHeight: 250).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Toggle("Seleccionar texto e imágenes", isOn: $session.selecting)
                    HStack {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Foto", systemImage: "photo.badge.plus")
                        }
                        Button("Deshacer", systemImage: "arrow.uturn.backward") { session.controller.canvas.undoManager?.undo() }
                        Button("Rehacer", systemImage: "arrow.uturn.forward") { session.controller.canvas.undoManager?.redo() }
                    }.labelStyle(.iconOnly).buttonStyle(.bordered)
                    Text("Dibujá con el dedo. Agregá texto desde la paleta.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(session.status).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("editor.status")
                HStack {
                    Button("Guardar") { Task { if await session.save() != nil { onSaved() } } }
                        .buttonStyle(.bordered).disabled(session.readOnly)
                    Button("Exportar", systemImage: "square.and.arrow.up") {
                        Task {
                            if let archive = await session.save(), let data = archive.image(for: .final)?.pngData,
                               let image = UIImage(data: data) {
                                onSaved()
                                exportImage = ExportImage(image: image)
                            }
                        }
                    }.labelStyle(.iconOnly).buttonStyle(.bordered)
                    Button("Enviar", systemImage: "paperplane.fill") {
                        guard !sending else { return }
                        sending = true
                        Task {
                            defer { sending = false }
                            guard let archive = await session.save() else { return }
                            onSaved()
                            if await onSend(archive) { dismiss() }
                            else { session.status = "El dibujo está guardado. Revisá la cuenta y la pareja vinculada en Nosotros antes de enviar." }
                        }
                    }.buttonStyle(.borderedProminent).disabled(session.readOnly)
                }
                if session.busy || sending { ProgressView("Guardando…") }
            }
            .padding().disabled(session.busy || sending || closing)
            .navigationTitle("Tu dibujo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo") {
                        closing = true
                        Task {
                            defer { closing = false }
                            let saved = session.readOnly ? true : (await session.save() != nil)
                            if saved {
                                onSaved()
                                dismiss()
                            }
                        }
                    }.disabled(session.busy || sending || closing)
                }
            }
            .interactiveDismissDisabled()
            .task { await session.load() }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await session.insertPhoto(item); selectedPhoto = nil }
            }
            .sheet(item: $exportImage) { ShareImageView(image: $0.image) }
        }
    }
}

private struct ExportImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ShareImageView: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
