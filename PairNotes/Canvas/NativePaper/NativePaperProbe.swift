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
    @Published var paperBackground: PaperBackground = .white {
        didSet {
            controller.paperBackground = paperBackground
            if paperBackground != oldValue { changed() }
        }
    }
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
            let restored = try PaperProbeDocument.decode(archive.source.data,
                                                        editorVersion: archive.document.minimumEditorVersion)
            let markup = restored.markup
            guard markup.featureSet.isSubset(of: PaperProbeDocument.supportedFeatures) else {
                throw ProbeError.incompatibleDocument
            }
            controller.restoreMarkup(markup)
            paperBackground = restored.background
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
            let capturedBackground = paperBackground
            let capturedTitle = title
            let (nextRevision, overflow) = revision.addingReportingOverflow(1)
            guard !overflow else { throw LocalStoreError.obsoleteRevision }
            let source = try await PaperProbeDocument.encode(captured, background: capturedBackground)
            let persisted = try PaperProbeDocument.decode(source, editorVersion: PaperProbeDocument.editorVersion)
            let full = try await PaperProbeDocument.render(persisted.markup, side: 1536, background: persisted.background)
            let widget = try await PaperProbeDocument.render(persisted.markup, side: 1024, background: persisted.background)
            let thumb = try await PaperProbeDocument.render(persisted.markup, side: 384, background: persisted.background)
            let archive = try DraftArchive.make(id: documentID, revision: nextRevision, nativeData: source,
                                                finalPNG: full, widgetPNG: widget, thumbnailPNG: thumb,
                                                minimumEditorVersion: PaperProbeDocument.editorVersion)
            try await store.save(archive, title: capturedTitle)
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
    @State private var choosingPhoto = false
    @State private var choosingBackground = false
    @State private var renaming = false
    @State private var proposedTitle = ""
    @State private var sending = false
    @State private var closing = false
    @State private var exportImage: ExportImage?

    init(store: DraftCatalogStore, draft: DraftSummary?, onSaved: @escaping () -> Void,
         onSend: @escaping (DraftArchive) async -> Bool) {
        _session = StateObject(wrappedValue: NativePaperSession(store: store, draft: draft))
        self.onSaved = onSaved
        self.onSend = onSend
    }

    private var working: Bool { session.busy || sending || closing }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small) }
                    Text(sending ? "Preparando el envío…" : session.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("editor.status")
                    Spacer(minLength: 0)
                }
                if session.readOnly {
                    if let preview = session.preview {
                        Image(uiImage: preview).resizable().scaledToFit()
                    } else { ContentUnavailableView("Borrador conservado", systemImage: "doc.lock") }
                } else {
                    PaperProbeCanvas(controller: session.controller, enabled: !working)
                        .aspectRatio(1, contentMode: .fit)
                        .background(Color(uiColor: session.paperBackground.uiColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .accessibilityIdentifier("editor.paper")
                    Text(session.selecting ? "Tocá el texto o la foto que quieras mover o editar." :
                         "Dibujá con el dedo o elegí una herramienta de la paleta.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The native tool palette owns the lower edge. Essential actions
                // stay in the navigation bar and cannot be covered by the picker.
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Button("Renombrar", systemImage: "pencil") { beginRenaming() }
                    .disabled(session.readOnly || working)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Listo", action: close)
                        .disabled(working)
                        .accessibilityIdentifier("editor.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Enviar", systemImage: "paperplane.fill", action: send)
                        .labelStyle(.iconOnly)
                        .disabled(session.readOnly || working)
                        .accessibilityIdentifier("editor.send")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Guardar borrador", systemImage: "checkmark.circle", action: save)
                            .disabled(session.readOnly)
                        Button("Exportar imagen", systemImage: "square.and.arrow.up", action: export)
                        Divider()
                        Button("Renombrar", systemImage: "pencil", action: beginRenaming)
                            .disabled(session.readOnly)
                        Button("Color de la hoja", systemImage: "paintpalette") { choosingBackground = true }
                            .disabled(session.readOnly)
                        if !session.readOnly {
                            Divider()
                            Button("Agregar texto", systemImage: "textformat") { session.controller.insertText() }
                            Button("Agregar foto", systemImage: "photo.badge.plus") { choosingPhoto = true }
                            Toggle("Seleccionar texto y fotos", isOn: $session.selecting)
                            Divider()
                            Button("Deshacer", systemImage: "arrow.uturn.backward") {
                                session.controller.canvas.undoManager?.undo()
                            }
                            Button("Rehacer", systemImage: "arrow.uturn.forward") {
                                session.controller.canvas.undoManager?.redo()
                            }
                        }
                    } label: {
                        Label("Opciones del dibujo", systemImage: "ellipsis")
                    }
                    .disabled(working)
                    .accessibilityIdentifier("editor.options")
                }
            }
            .interactiveDismissDisabled()
            .task { await session.load() }
            .photosPicker(isPresented: $choosingPhoto, selection: $selectedPhoto, matching: .images)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { await session.insertPhoto(item); selectedPhoto = nil }
            }
            .alert("Renombrar dibujo", isPresented: $renaming) {
                TextField("Título", text: $proposedTitle)
                    .textInputAutocapitalization(.sentences)
                Button("Cancelar", role: .cancel) {}
                Button("Guardar") {
                    session.title = String(proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                    save()
                }
                .disabled(working || proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sheet(isPresented: $choosingBackground) {
                PaperBackgroundPicker(background: $session.paperBackground)
                    .disabled(session.busy)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $exportImage) { ShareImageView(image: $0.image) }
        }
    }

    private func beginRenaming() {
        proposedTitle = session.title
        renaming = true
    }

    private func save() {
        Task { if await session.save() != nil { onSaved() } }
    }

    private func close() {
        guard !working else { return }
        closing = true
        Task {
            defer { closing = false }
            let saved = session.readOnly ? true : (await session.save() != nil)
            if saved {
                onSaved()
                dismiss()
            }
        }
    }

    private func export() {
        Task {
            if let archive = await session.save(), let data = archive.image(for: .final)?.pngData,
               let image = UIImage(data: data) {
                onSaved()
                exportImage = ExportImage(image: image)
            }
        }
    }

    private func send() {
        guard !working else { return }
        sending = true
        Task {
            defer { sending = false }
            guard let archive = await session.save() else { return }
            onSaved()
            if await onSend(archive) { dismiss() }
            else { session.status = "El dibujo está guardado. Revisá la cuenta y la pareja vinculada en Nosotros antes de enviar." }
        }
    }
}

private struct PaperBackgroundPicker: View {
    @Binding var background: PaperBackground
    @Environment(\.dismiss) private var dismiss
    private let presets: [(String, PaperBackground)] = [
        ("Blanco", .white), ("Crema", .cream), ("Rosa", .rose),
        ("Celeste", .sky), ("Menta", .mint), ("Oscuro", .charcoal)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 16) {
                        ForEach(presets, id: \.0) { name, color in
                            Button {
                                background = color
                            } label: {
                                VStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(uiColor: color.uiColor))
                                        .frame(height: 42)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(Color.primary.opacity(background == color ? 0.8 : 0.2),
                                                              lineWidth: background == color ? 3 : 1)
                                        }
                                    Text(name).font(.caption).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(background == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                    ColorPicker("Otro color", selection: Binding(
                        get: { Color(uiColor: background.uiColor) },
                        set: { background = PaperBackground(color: UIColor($0)) }
                    ), supportsOpacity: false)
                } footer: {
                    Text("El color se guarda con el dibujo y también aparece al enviarlo, exportarlo y en el widget.")
                }
            }
            .navigationTitle("Color de la hoja").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } }
            }
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
