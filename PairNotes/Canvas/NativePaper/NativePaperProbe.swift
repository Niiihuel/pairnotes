import SwiftUI
import UIKit
import PaperKit
import PairNotesCore
import WidgetKit
import PhotosUI
import ImageIO

@MainActor
final class PaperProbeSession: ObservableObject {
    let controller = PaperProbeController()
    @Published var busy = false
    @Published var readOnly = false
    @Published var status = "Ejemplo ficticio: texto, imagen y trazo."
    @Published var preview: UIImage?
    @Published var selecting = false {
        didSet { controller.canvas.directTouchMode = selecting ? .selection : .drawing }
    }
    private var didLoad = false
    private var revision: UInt64 = 0
    private var draftStore: FileDraftStore?
    // One local scratch document for the M0 experiment; no published note identity.
    private let documentID = UUID(uuidString: "76F70CBA-2B5D-4CDD-A3A3-0123456789AB")!

    private func store() throws -> FileDraftStore {
        if let draftStore { return draftStore }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        let created = FileDraftStore(directory: support.appendingPathComponent("PaperProbe", isDirectory: true))
        draftStore = created
        return created
    }

    func initialLoad() async {
        guard !didLoad else { return }
        didLoad = true
        await restore()
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let archive = try await store().load(id: documentID) else { return }
            revision = archive.document.revision
            preview = archive.image(for: .final).flatMap { UIImage(data: $0.pngData) }
            guard archive.document.isEditable else {
                readOnly = true
                status = "Esta fuente necesita otra versión. Se conserva su imagen en modo de lectura."
                return
            }
            let restored = try PaperMarkup(dataRepresentation: archive.source.data)
            guard restored.featureSet.isSubset(of: PaperProbeDocument.supportedFeatures) else {
                readOnly = true
                status = "Esta fuente necesita otra versión. Se conserva su imagen en modo de lectura."
                return
            }
            controller.canvas.markup = restored
            readOnly = false
            status = "Borrador local reabierto · revisión \(revision)."
        } catch {
            readOnly = true
            status = "No se pudo abrir el borrador. Se conserva el archivo sin sobrescribirlo."
        }
    }

    func save() async {
        guard !busy, !readOnly else { return }
        busy = true
        defer { busy = false }
        do {
            guard let captured = controller.canvas.markup else { throw ProbeError.missingMarkup }
            let nextRevision = revision + 1
            let source = try await captured.dataRepresentation()
            let full = try await PaperProbeDocument.render(captured, side: 1536)
            let widget = try await PaperProbeDocument.render(captured, side: 1024)
            let thumb = try await PaperProbeDocument.render(captured, side: 384)
            let archive = try DraftArchive.make(id: documentID, revision: nextRevision, nativeData: source,
                                                finalPNG: full, widgetPNG: widget, thumbnailPNG: thumb)
            try await store().save(archive)
            revision = nextRevision
            preview = UIImage(data: full)
            status = "Guardado en este iPhone · revisión \(revision)."
            if let directory = SharedWidgetContainer.directory() {
                do {
                    let snapshot = NoteWidgetSnapshot(noteID: documentID, revision: revision,
                                                      revisionHash: archive.document.revisionHash,
                                                      authorName: "Ejemplo ficticio", updatedAt: Date(), pngData: widget)
                    try await WidgetSnapshotStore(directory: directory).write(snapshot)
                    WidgetCenter.shared.reloadTimelines(ofKind: SharedWidgetContainer.widgetKind)
                    status += " Se solicitó actualizar el widget local."
                } catch {
                    status += " No se pudo escribir la copia del widget."
                }
            } else {
                status += " El widget requiere configurar el grupo compartido en Xcode."
            }
        } catch {
            status = "No se pudo guardar esta revisión. Reintentá antes de cerrar."
        }
    }

    func insertPhoto(_ item: PhotosPickerItem) async {
        guard !busy, !readOnly else { return }
        busy = true
        defer { busy = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  data.count <= 20 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1536
                  ] as CFDictionary),
                  var markup = controller.canvas.markup else {
                status = "No se pudo importar la foto (máximo 20 MB)."
                return
            }
            // Orientation normalized; only decoded pixels enter the native document.
            let width: CGFloat = 900
            let height = width * CGFloat(image.height) / CGFloat(image.width)
            let scale = min(1, 1000 / height)
            markup.insertNewImage(image, frame: CGRect(x: 250, y: 300, width: width * scale, height: height * scale))
            controller.canvas.markup = markup
            status = "Foto agregada al borrador. Guardá para conservarla en este dispositivo."
        } catch {
            status = "No se pudo cargar la foto seleccionada."
        }
    }
}

struct NativePaperProbeView: View {
    @StateObject private var session = PaperProbeSession()
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 12) {
            Text("Prueba local del editor").font(.headline)
            Text(session.status).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("editor.status")
            if session.readOnly {
                if let preview = session.preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .accessibilityLabel("Imagen del borrador conservado")
                }
            } else {
                PaperProbeCanvas(controller: session.controller, enabled: !session.busy)
                    .frame(minHeight: 250).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Toggle("Seleccionar texto e imágenes", isOn: $session.selecting)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Agregar foto", systemImage: "photo.badge.plus")
                }
                Text("Dibujá con el dedo. Usá + en la paleta para agregar elementos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Guardar y renderizar") { Task { await session.save() } }
                    .buttonStyle(.borderedProminent).disabled(session.readOnly)
                Button("Reabrir") { Task { await session.restore() } }.buttonStyle(.bordered)
            }
            if session.busy { ProgressView("Procesando…") }
        }
        .padding().disabled(session.busy)
        .task { await session.initialLoad() }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                await session.insertPhoto(item)
                selectedPhoto = nil
            }
        }
    }
}
