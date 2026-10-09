import SwiftUI
import UIKit
import PaperKit
import PairNotesCore
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

/// The editor shares the app's catalog actor. An injectable boundary also lets
/// persistence races be exercised without replacing PaperKit or its renderer.
protocol NativePaperDraftStore: Sendable {
    func load(id: UUID) async throws -> DraftArchive?
    func save(_ archive: DraftArchive, title: String, at date: Date) async throws -> DraftSummary
    func remove(id: UUID) async throws
}

extension DraftCatalogStore: NativePaperDraftStore {}

/// Photos hands out a temporary file whose lifetime ends with its completion
/// handler. Downsample and copy the result there, before crossing back to UI.
/// This avoids loading an entire RAW/panorama into memory merely to reject it.
enum PaperPhotoImport {
    static let maximumInputBytes = 100 * 1024 * 1024
    static let maximumPixelSide = 1536

    enum Failure: Error {
        case unsupported, tooLarge, unreadable

        var message: String {
            switch self {
            case .unsupported: "Elegí una imagen compatible desde Fotos."
            case .tooLarge: "La foto supera los 100 MB. Elegí una versión más pequeña."
            case .unreadable: "No se pudo abrir esta foto. Probá con otra imagen."
            }
        }
    }

    static func loadData(from provider: NSItemProvider) async throws -> Data {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { throw Failure.unsupported }
        let operation = PaperPhotoLoadOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.begin(continuation) else { return }
                let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw Failure.unreadable }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey])
                        guard let size = values.fileSize, size > 0 else { throw Failure.unreadable }
                        guard size <= maximumInputBytes else { throw Failure.tooLarge }
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                            kCGImageSourceShouldCache: false
                        ] as CFDictionary) else { throw Failure.unreadable }
                        let image = try thumbnail(source)
                        let data = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                            throw Failure.unreadable
                        }
                        CGImageDestinationAddImage(destination, image, nil)
                        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
                        operation.finish(.success(data as Data))
                    } catch { operation.finish(.failure(error)) }
                }
                operation.attach(progress)
            }
        } onCancel: { operation.cancel() }
    }

    @MainActor
    static func decode(_ data: Data) throws -> UIImage {
        guard !data.isEmpty else { throw Failure.unreadable }
        guard data.count <= maximumInputBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { throw Failure.unreadable }
        return UIImage(cgImage: try thumbnail(source))
    }

    private static func thumbnail(_ source: CGImageSource) throws -> CGImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSide
        ] as CFDictionary) else { throw Failure.unreadable }
        return image
    }
}

/// The provider may complete after cancellation, or fail to deliver a callback
/// promptly while downloading from iCloud. Resume the UI waiter exactly once.
private final class PaperPhotoLoadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var progress: Progress?
    private var finished = false

    func begin(_ continuation: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        } else {
            self.continuation = continuation
            lock.unlock()
            return true
        }
    }

    func attach(_ progress: Progress) {
        lock.lock()
        let shouldCancel = finished
        if !finished { self.progress = progress }
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func finish(_ result: Result<Data, Error>, cancelling: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiter = continuation
        let active = progress
        continuation = nil
        progress = nil
        lock.unlock()
        waiter?.resume(with: result)
        if cancelling { active?.cancel() }
    }

    func cancel() {
        // Claim the waiter and its progress under the same lock. Otherwise
        // attach() can install a download between reading progress and finish,
        // releasing the UI while leaving that cloud download uncancelled.
        finish(.failure(CancellationError()), cancelling: true)
    }
}

struct PaperPhotoPicker: UIViewControllerRepresentable {
    let onChoose: (NSItemProvider?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChoose: onChoose) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onChoose: (NSItemProvider?) -> Void
        init(onChoose: @escaping (NSItemProvider?) -> Void) { self.onChoose = onChoose }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onChoose(results.first?.itemProvider)
        }
    }
}

@MainActor
final class NativePaperSession: ObservableObject {
    let controller = PaperProbeController()
    @Published private(set) var layers: [PaperLayer] = []
    @Published private(set) var activeLayerID: UUID?
    @Published var busy = false
    @Published var readOnly = false
    @Published var status = "Tu borrador se guarda en este iPhone."
    @Published var preview: UIImage?
    @Published private(set) var hasChanges = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var title: String { didSet { if title != oldValue { changed() } } }
    @Published var paperBackground: PaperBackground = .white {
        didSet {
            controller.paperBackground = paperBackground
            if paperBackground != oldValue { changed() }
        }
    }
    @Published var selecting = false {
        didSet { controller.selectionMode = selecting }
    }
    private let store: any NativePaperDraftStore
    private let documentID: UUID
    private let existing: Bool
    private var loaded = false
    private var revision: UInt64 = 0
    private var mutation: UInt64 = 0
    private var savedMutation: UInt64?
    private var lastArchive: DraftArchive?
    private var autosave: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveWaiters: [UUID: CheckedContinuation<DraftArchive?, Never>] = [:]
    private var baselineArchive: DraftArchive?
    private var baselineTitle: String
    private var autosaveSuspended = false
    private var finished = false

    init(store: any NativePaperDraftStore, draft: DraftSummary?, theme: CoupleTheme? = nil) {
        self.store = store
        documentID = draft?.id ?? UUID()
        existing = draft != nil
        title = draft?.title ?? "Sin título"
        baselineTitle = draft?.title ?? "Sin título"
        if draft == nil, let theme {
            paperBackground = PaperBackground(red: UInt8((theme.paperRGB >> 16) & 255),
                green: UInt8((theme.paperRGB >> 8) & 255), blue: UInt8(theme.paperRGB & 255))
            controller.paperBackground = paperBackground
        }
        controller.onLayersChanged = { [weak self] layers, active in
            self?.layers = layers
            self?.activeLayerID = active
        }
        controller.onMarkupChanged = { [weak self] in self?.changed() }
        controller.onHistoryChanged = { [weak self] undo, redo in
            self?.canUndo = undo
            self?.canRedo = redo
        }
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
            baselineArchive = archive
            guard archive.document.isEditable else { throw ProbeError.incompatibleDocument }
            let restored = try PaperProbeDocument.decode(archive.source.data,
                                                        editorVersion: archive.document.minimumEditorVersion)
            let markup = restored.markup
            guard markup.featureSet.isSubset(of: PaperProbeDocument.supportedFeatures),
                  restored.layers?.allSatisfy({ $0.markup.featureSet.isSubset(of: PaperProbeDocument.supportedFeatures) }) != false else {
                throw ProbeError.incompatibleDocument
            }
            controller.restoreLayers(restored.layers ?? [PaperLayer(name: "Dibujo original", markup: markup)])
            paperBackground = restored.background
            savedMutation = mutation
            status = "Borrador guardado en este iPhone."
        } catch {
            readOnly = true
            status = "Este borrador no se puede editar con esta versión. Conservamos su archivo y su imagen."
        }
    }

    func changed() {
        guard loaded, !readOnly, !finished else { return }
        hasChanges = true
        mutation &+= 1
        status = "Cambios sin guardar…"
        scheduleAutosave()
    }

    func suspendAutosave() {
        autosaveSuspended = true
        autosave?.cancel()
        autosave = nil
    }

    func resumeAutosave() {
        autosaveSuspended = false
        if hasChanges { scheduleAutosave() }
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        autosave = nil
        guard !autosaveSuspended, !finished else { return }
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            // This task owns only the debounce. A later edit may cancel its
            // timer, but must never cancel a capture already being persisted.
            self.autosave = nil
            _ = await self.save()
        }
    }

    /// One immutable native capture produces every render. No local edit writes
    /// the received-note widget or changes a previously published note.
    func save() async -> DraftArchive? {
        guard loaded, !finished, !Task.isCancelled else { return nil }
        if readOnly { return lastArchive }
        if saveTask == nil {
            guard !busy else { return nil }
            if savedMutation == mutation, let lastArchive { return lastArchive }
        }
        autosave?.cancel()
        autosave = nil
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                saveWaiters[requestID] = continuation
                guard saveTask == nil else { return }
                saveTask = Task { [self] in
                    var result: DraftArchive?
                    repeat {
                        result = await writeCurrentCapture()
                    } while result != nil && savedMutation != mutation && !finished
                    saveTask = nil
                    let waiters = Array(saveWaiters.values)
                    saveWaiters.removeAll()
                    for waiter in waiters { waiter.resume(returning: result) }
                }
            }
        } onCancel: {
            // Cancel only this caller's wait. Other Save/Send requests, and
            // recovery persistence itself, still need the shared writer.
            Task { @MainActor [weak self] in
                self?.saveWaiters.removeValue(forKey: requestID)?.resume(returning: nil)
            }
        }
    }

    /// Exactly one task writes revisions. If a native callback or edit arrives
    /// during a capture, save() captures again before releasing any caller.
    private func writeCurrentCapture() async -> DraftArchive? {
        let capturedMutation = mutation
        do {
            let capturedLayers = controller.capturedLayers()
            let captured = controller.composedMarkup()
            let capturedBackground = paperBackground
            let capturedTitle = title
            let (nextRevision, overflow) = revision.addingReportingOverflow(1)
            guard !overflow else { throw LocalStoreError.obsoleteRevision }
            let source = try await PaperProbeDocument.encode(captured, background: capturedBackground, layers: capturedLayers)
            let persisted = try PaperProbeDocument.decode(source, editorVersion: PaperProbeDocument.editorVersion)
            let full = try await PaperProbeDocument.render(persisted.markup, side: 1536, background: persisted.background)
            let widget = try await PaperProbeDocument.render(persisted.markup, side: 1024, background: persisted.background)
            let thumb = try await PaperProbeDocument.render(persisted.markup, side: 384, background: persisted.background)
            let archive = try DraftArchive.make(id: documentID, revision: nextRevision, nativeData: source,
                                                finalPNG: full, widgetPNG: widget, thumbnailPNG: thumb,
                                                minimumEditorVersion: PaperProbeDocument.editorVersion)
            _ = try await store.save(archive, title: capturedTitle, at: Date())
            revision = nextRevision
            savedMutation = capturedMutation
            lastArchive = archive
            preview = UIImage(data: full)
            status = capturedMutation == mutation ? "Guardado en este iPhone." : "Cambios sin guardar…"
            return archive
        } catch {
            status = "No se pudo guardar. Reintentá antes de cerrar."
            return nil
        }
    }

    /// Explicit Save or a successful Send establishes the next discard point.
    /// Autosave only protects recovery; it never silently accepts this session.
    func commit(_ archive: DraftArchive) {
        guard archive == lastArchive, savedMutation == mutation else { return }
        baselineArchive = archive
        baselineTitle = title
        hasChanges = false
    }

    /// Roll back autosaved edits as a new monotonic revision. Never overwrite an
    /// older archive or mutate a publication that already captured those bytes.
    func discardChanges() async -> Bool {
        guard loaded, !busy, !finished else { return false }
        suspendAutosave()
        busy = true
        defer { busy = false }
        // Drain any recovery write before restoring or deleting the draft.
        await saveTask?.value
        do {
            if let baseline = baselineArchive {
                if lastArchive != baseline {
                    let (next, overflow) = revision.addingReportingOverflow(1)
                    guard !overflow else { throw LocalStoreError.obsoleteRevision }
                    guard let full = baseline.image(for: .final), let widget = baseline.image(for: .widget),
                          let thumb = baseline.image(for: .thumbnail) else { throw LocalStoreError.corruptData }
                    let restored = try DraftArchive.make(id: documentID, revision: next,
                        nativeData: baseline.source.data, finalPNG: full.pngData,
                        widgetPNG: widget.pngData, thumbnailPNG: thumb.pngData,
                        canvasSize: baseline.document.canvasSize,
                        minimumEditorVersion: baseline.document.minimumEditorVersion)
                    _ = try await store.save(restored, title: baselineTitle, at: Date())
                    revision = next
                    lastArchive = restored
                }
            } else {
                try await store.remove(id: documentID)
                lastArchive = nil
            }
            finished = true
            hasChanges = false
            status = "Cambios descartados."
            return true
        } catch {
            status = "No se pudieron descartar los cambios. El borrador sigue conservado. Reintentá."
            resumeAutosave()
            return false
        }
    }

    func loadPhoto(_ provider: NSItemProvider) async -> UIImage? {
        guard loaded, !busy, !readOnly, !finished else { return nil }
        busy = true
        status = "Cargando la foto… Si está en iCloud, puede tardar un momento."
        defer { busy = false }
        do {
            let data = try await PaperPhotoImport.loadData(from: provider)
            try Task.checkCancellation()
            guard !finished else { return nil }
            let image = try PaperPhotoImport.decode(data)
            status = "Elegí el recorte y tocá Usar foto."
            return image
        } catch is CancellationError { status = "Carga de foto cancelada. Podés seguir dibujando."; return nil }
        catch {
            status = (error as? PaperPhotoImport.Failure)?.message ??
                "No se pudo descargar la foto. Revisá la conexión y volvé a elegirla."
            return nil
        }
    }

    @discardableResult
    func insertPhoto(_ image: UIImage, sticker: Bool = false) -> Bool {
        guard loaded, !busy, !readOnly, !finished else { return false }
        let normalized = PhotoCropGeometry.normalized(image)
        guard let image = normalized.cgImage, image.width > 0, image.height > 0 else {
            status = "No se pudo preparar la foto. Volvé a elegirla."
            return false
        }
        controller.addLayer(name: sticker ? "Mi sticker" : "Foto")
        guard var markup = controller.canvas.markup else { return false }
        let width: CGFloat = sticker ? 360 : 900
        let height = width * CGFloat(image.height) / CGFloat(image.width)
        let scale = min(1, 1000 / height)
        let size = CGSize(width: width * scale, height: height * scale)
        let bounds = markup.bounds
        markup.insertNewImage(image, frame: CGRect(x: bounds.midX - size.width / 2,
                                                  y: bounds.midY - size.height / 2,
                                                  width: size.width, height: size.height))
        controller.replaceMarkup(markup, actionName: "Agregar foto")
        selecting = true
        controller.fitPaper()
        status = "Tocá la foto para moverla o cambiar su tamaño."
        return true
    }

}

struct NativePaperEditorView: View {
    @StateObject private var session: NativePaperSession
    let sendTitle: String
    let stickerStore: DraftCatalogStore
    let onSavedArchive: ((DraftArchive) -> Void)?
    let onSaved: () -> Void
    let onSend: (DraftArchive) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingPhotoProvider: NSItemProvider?
    @State private var photoImportTask: Task<Void, Never>?
    @State private var photoImportID: UUID?
    @State private var choosingPhoto = false
    @State private var choosingBackground = false
    @State private var showingLayers = false
    @State private var showingGuides = false
    @State private var showingStickers = false
    @State private var eyedropperImage: ExportImage?
    @State private var preparingTool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renaming = false
    @State private var proposedTitle = ""
    @State private var sending = false
    @State private var closing = false
    @State private var confirmingClose = false
    @State private var exportImage: ExportImage?
    @State private var cropPhoto: ExportImage?

    init(store: DraftCatalogStore, draft: DraftSummary?, theme: CoupleTheme? = nil, sendTitle: String = "Enviar dibujo", onSavedArchive: ((DraftArchive) -> Void)? = nil, onSaved: @escaping () -> Void,
         onSend: @escaping (DraftArchive) async -> Bool) {
        _session = StateObject(wrappedValue: NativePaperSession(store: store, draft: draft, theme: theme))
        self.sendTitle = sendTitle; self.onSavedArchive = onSavedArchive; self.stickerStore = store
        self.onSaved = onSaved
        self.onSend = onSend
    }

    private var working: Bool { session.busy || sending || closing || preparingTool }
    private var presentingTools: Bool {
        showingStickers || eyedropperImage != nil || showingLayers || choosingPhoto || choosingBackground || renaming || confirmingClose || exportImage != nil || cropPhoto != nil
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let paperSide = max(100, min(640, geometry.size.width - 32, geometry.size.height - 210))
                VStack(spacing: 10) {
                    if !session.readOnly { editingControls }
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(sending ? "Preparando el envío…" : session.status)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .accessibilityIdentifier("editor.status")
                        Spacer(minLength: 0)
                        if photoImportTask != nil {
                            Button("Cancelar carga") { photoImportTask?.cancel() }
                                .font(.caption).frame(minHeight: 44)
                                .accessibilityIdentifier("editor.cancelPhotoImport")
                        }
                    }
                    if session.readOnly {
                        if let preview = session.preview {
                            Image(uiImage: preview).resizable().scaledToFit()
                        } else { ContentUnavailableView("Borrador conservado", systemImage: "doc.lock") }
                        Button("Exportar imagen", systemImage: "square.and.arrow.up", action: export)
                            .disabled(working)
                    } else {
                        PaperProbeCanvas(controller: session.controller, enabled: !session.busy && !sending && !closing && !confirmingClose)
                            .allowsHitTesting(!preparingTool)
                            .frame(width: paperSide, height: paperSide)
                            .background(Color(uiColor: session.paperBackground.uiColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                            .accessibilityIdentifier("editor.paper")
                        Text(session.selecting ? "Tocá una foto o texto y arrastrá para mover. Usá sus tiradores para cambiar el tamaño." :
                             "Dibujá con el dedo. Usá dos dedos para desplazar o ampliar la hoja.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // PencilKit owns the lower edge; all actions remain above the paper.
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .coupleScreenBackground()
            .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.readOnly ? "Cerrar" : "Cancelar", action: requestClose)
                        .disabled(working).accessibilityIdentifier("editor.cancel")
                }
                ToolbarItem(placement: .principal) {
                    Button(action: beginRenaming) {
                        Text(session.title).font(.headline).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: 120).foregroundStyle(.primary)
                    }
                    .disabled(session.readOnly || working)
                    .accessibilityLabel("Renombrar dibujo: \(session.title)")
                    .accessibilityIdentifier("editor.rename")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar y cerrar", systemImage: "checkmark", action: saveAndClose)
                        .labelStyle(.iconOnly).disabled(session.readOnly || working)
                        .accessibilityIdentifier("editor.done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(sendTitle, systemImage: "paperplane.fill", action: send)
                        .labelStyle(.iconOnly).disabled(session.readOnly || working)
                        .accessibilityIdentifier("editor.send")
                }
            }
            .interactiveDismissDisabled()
            .task { await session.load() }
            .onAppear { session.resumeAutosave() }
            .onDisappear { session.suspendAutosave(); photoImportTask?.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    session.resumeAutosave()
                    if !presentingTools && !working { session.controller.resumeCanvasInput() }
                } else { session.suspendAutosave() }
            }
            .onChange(of: confirmingClose) { _, showing in
                if !showing && !closing { session.resumeAutosave() }
            }
            .onChange(of: presentingTools) { _, presented in
                session.controller.setPaletteVisible(!presented && !session.selecting)
            }
            .onChange(of: session.selecting) { _, selecting in
                session.controller.setPaletteVisible(!selecting && !presentingTools)
            }
            .sheet(isPresented: $choosingPhoto, onDismiss: importSelectedPhoto) {
                PaperPhotoPicker { provider in
                    pendingPhotoProvider = provider
                    choosingPhoto = false
                }
            }
            .alert("Renombrar dibujo", isPresented: $renaming) {
                TextField("Título", text: $proposedTitle).textInputAutocapitalization(.sentences)
                Button("Cancelar", role: .cancel) {}
                Button("Guardar") {
                    session.title = String(proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
                }.disabled(working || proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("¿Guardar los cambios del dibujo?", isPresented: $confirmingClose, titleVisibility: .visible) {
                Button("Guardar y cerrar", action: saveAndClose)
                Button("Descartar cambios", role: .destructive, action: discardAndClose)
                Button("Seguir editando", role: .cancel) { session.resumeAutosave() }
            } message: {
                Text("Descartar vuelve al último guardado que confirmaste, aunque haya una copia automática de recuperación.")
            }
            .sheet(isPresented: $showingLayers, onDismiss: session.controller.resumeCanvasInput) { layerSheet }
            .sheet(isPresented: $showingStickers, onDismiss: session.controller.resumeCanvasInput) {
                PersonalStickerLibrary(store: stickerStore) { image in _ = session.insertPhoto(image, sticker: true) }
            }
            .sheet(item: $eyedropperImage, onDismiss: session.controller.resumeCanvasInput) { item in
                PaperEyedropper(image: item.image) { color in
                    session.controller.useInkColor(color); session.selecting = false
                    session.status = "Color elegido. Ya podés dibujar con él."
                }
            }
            .sheet(isPresented: $choosingBackground, onDismiss: session.controller.resumeCanvasInput) {
                PaperBackgroundPicker(background: $session.paperBackground)
                    .disabled(session.busy).presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $cropPhoto, onDismiss: session.controller.resumeCanvasInput) { item in
                PhotoCropEditor(image: item.image, onCancel: { cropPhoto = nil }) { image in
                    if session.insertPhoto(image) { cropPhoto = nil }
                }
            }
            .sheet(item: $exportImage, onDismiss: session.controller.resumeCanvasInput) { ShareImageView(image: $0.image) }
        }
    }

    private var layerSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(session.layers.reversed())) { layer in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button {
                                    session.controller.selectLayer(layer.id)
                                    session.selecting = true; showingLayers = false
                                } label: {
                                    Image(systemName: session.activeLayerID == layer.id ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.borderless).accessibilityLabel("Editar " + layer.name)
                                TextField("Nombre de la capa", text: Binding(
                                    get: { session.layers.first(where: { $0.id == layer.id })?.name ?? layer.name },
                                    set: { session.controller.renameLayer(layer.id, name: $0) }))
                            }
                            HStack {
                                Button("Subir", systemImage: "arrow.up") { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { session.controller.moveLayer(layer.id, by: 1) } }
                                    .disabled(session.layers.last?.id == layer.id)
                                Button("Bajar", systemImage: "arrow.down") { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { session.controller.moveLayer(layer.id, by: -1) } }
                                    .disabled(session.layers.first?.id == layer.id)
                                Spacer()
                                Button("Eliminar", systemImage: "trash", role: .destructive) { session.controller.removeLayer(layer.id) }
                                    .labelStyle(.iconOnly).disabled(session.layers.count < 2)
                            }.font(.caption).buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                } footer: {
                    Text("Las capas de arriba cubren las de abajo. Elegí una capa para editar sus textos, fotos y trazos.")
                }
                Button("Agregar capa", systemImage: "plus") { session.controller.addLayer() }
            }
            .coupleScreenBackground()
            .navigationTitle("Capas").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { showingLayers = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }


    private var editingControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                tool("Deshacer", icon: "arrow.uturn.backward", id: "editor.undo", action: session.controller.undo)
                    .disabled(!session.canUndo)
                tool("Rehacer", icon: "arrow.uturn.forward", id: "editor.redo", action: session.controller.redo)
                    .disabled(!session.canRedo)
                Picker("Modo de edición", selection: $session.selecting) {
                    Text("Dibujar").tag(false)
                    Text("Seleccionar").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("editor.selection")
            }
            HStack(spacing: 4) {
                Button("Foto", systemImage: "photo.badge.plus") { choosingPhoto = true }
                    .frame(minHeight: 44).padding(.horizontal, 8)
                    .accessibilityLabel("Agregar foto y recortar").accessibilityIdentifier("editor.photo")
                tool("Agregar texto", icon: "textformat", id: "editor.text", action: session.controller.insertText)
                tool("Color de la hoja", icon: "paintpalette", id: "editor.background") { choosingBackground = true }
                Spacer(minLength: 0)
                Menu {
                    Button("Capas", systemImage: "square.3.layers.3d") { showingLayers = true }
                        .accessibilityIdentifier("editor.layers")
                    Button("Exportar imagen", systemImage: "square.and.arrow.up", action: export)
                        .accessibilityIdentifier("editor.export")
                    Section("Vista de la hoja") {
                        Button("Alejar", systemImage: "minus.magnifyingglass") { session.controller.zoom(by: 1 / 1.35) }
                        Button("Ajustar hoja", systemImage: "arrow.up.left.and.arrow.down.right", action: session.controller.fitPaper)
                        Button("Acercar", systemImage: "plus.magnifyingglass") { session.controller.zoom(by: 1.35) }
                    }
                    Section("Stickers") {
                        ForEach(["♡", "✨", "🌸", "⭐️", "🌙", "💌"], id: \.self) { symbol in
                            Button(symbol) { session.controller.insertSticker(symbol); session.selecting = true }
                        }
                    }
                    Button("Mis stickers", systemImage: "face.smiling") { showingStickers = true }
                    Menu("Plantillas", systemImage: "rectangle.on.rectangle") {
                        ForEach(PaperTemplate.allCases, id: \.self) { style in
                            Button(style.rawValue) { session.controller.insertPostcardFrame(style: style) }
                        }
                    }
                    Button("Cuentagotas", systemImage: "eyedropper") {
                        preparingTool = true
                        Task { @MainActor in
                            defer { preparingTool = false }
                            do {
                                let bytes = try await PaperProbeDocument.render(session.controller.composedMarkup(), side: 1024, background: session.paperBackground)
                                guard let image = UIImage(data: bytes) else { throw ProbeError.renderFailed }
                                eyedropperImage = ExportImage(image: image)
                            } catch { session.status = "No se pudo preparar el cuentagotas. Reintentá." }
                        }
                    }
                    Menu("Alinear capa", systemImage: "align.horizontal.center") {
                        ForEach(PaperAlignment.allCases, id: \.self) { alignment in
                            Button(alignment.rawValue) {
                                preparingTool = true
                                Task { @MainActor in
                                    defer { preparingTool = false }
                                    await session.controller.alignActiveLayer(alignment)
                                }
                            }
                        }
                    }
                    Toggle("Guías de centrado", isOn: $showingGuides)
                } label: { Label("Más", systemImage: "ellipsis.circle").font(.subheadline).frame(minWidth: 44, minHeight: 44) }
                .onChange(of: showingGuides) { _, value in session.controller.showsAlignmentGuides = value; session.controller.snapsToGuides = value }
            }
        }.disabled(working || confirmingClose)
    }

    private func tool(_ label: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.borderless).accessibilityLabel(label).help(label).accessibilityIdentifier(id)
    }

    private func beginRenaming() {
        proposedTitle = session.title
        renaming = true
    }

    private func importSelectedPhoto() {
        guard let provider = pendingPhotoProvider else {
            session.controller.resumeCanvasInput()
            return
        }
        pendingPhotoProvider = nil
        photoImportTask?.cancel()
        let importID = UUID()
        photoImportID = importID
        // Wait for the native picker to finish dismissing before presenting
        // the cropper. Fast local photos used to race these two presentations.
        photoImportTask = Task { @MainActor in
            defer {
                if photoImportID == importID { photoImportTask = nil; photoImportID = nil }
            }
            guard let image = await session.loadPhoto(provider), !Task.isCancelled, photoImportID == importID else { return }
            cropPhoto = ExportImage(image: image)
        }
    }

    private func requestClose() {
        guard !working else { return }
        session.suspendAutosave()
        if session.hasChanges { confirmingClose = true }
        else { dismiss() }
    }

    private func saveAndClose() {
        guard !working else { return }
        closing = true
        Task {
            defer { closing = false }
            if let archive = await session.save() {
                session.commit(archive)
                onSavedArchive?(archive)
                onSaved()
                dismiss()
            } else { session.resumeAutosave() }
        }
    }

    private func discardAndClose() {
        guard !working else { return }
        closing = true
        Task {
            defer { closing = false }
            if await session.discardChanges() { onSaved(); dismiss() }
        }
    }

    private func export() {
        guard !working else { return }
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
            if await onSend(archive) {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                session.commit(archive)
                dismiss()
            } else { session.status = "El dibujo está guardado. Revisá la cuenta y la pareja vinculada en Nosotros antes de enviar." }
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
            .coupleScreenBackground()
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
