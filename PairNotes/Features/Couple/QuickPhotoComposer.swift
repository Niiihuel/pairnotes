import AVFoundation
import PairNotesCore
import PhotosUI
import SwiftUI
import UIKit

/// The widget opens this screen; capture and sending always happen in the app.
struct QuickPhotoComposer: View {
    @ObservedObject var services: AppServices
    var opensCamera = false
    var opensPhotoLibrary = false
    let onSent: (CouplePhoto) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var imageData: Data?
    @State private var caption: String
    @State private var photoID: UUID
    @State private var choosingPhoto = false
    @State private var cameraShowing = false
    @State private var preparing = false
    @State private var sending = false
    @State private var error: String?
    @State private var needsSettings = false
    @State private var finished = false
    @State private var attemptedCamera = false
    @State private var attemptedLibrary = false
    @State private var confirmDiscard = false
    private let storage: MemoryCompositionStorage
    private let scope: String

    private struct Draft: Codable { let id: UUID; let caption: String }

    init(services: AppServices, opensCamera: Bool = false, opensPhotoLibrary: Bool = false,
         onSent: @escaping (CouplePhoto) -> Void = { _ in }) {
        self.services = services; self.opensCamera = opensCamera
        self.opensPhotoLibrary = opensPhotoLibrary; self.onSent = onSent
        let key = services.privateImageKey("quick-photo")
        let storage = MemoryCompositionStorage(key: key)
        self.storage = storage; scope = key
        let draft: Draft? = storage.loadValue()
        _photoID = State(initialValue: draft?.id ?? UUID())
        _caption = State(initialValue: draft?.caption ?? "")
        _imageData = State(initialValue: draft == nil ? nil : storage.photo())
    }

    private var current: Bool { scope == services.privateImageKey("quick-photo") && services.membership != nil }
    private var hasDraft: Bool { imageData != nil || !caption.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let imageData, let image = UIImage(data: imageData) {
                        Image(uiImage: image).resizable().scaledToFit().privacySensitive()
                            .frame(maxWidth: .infinity, maxHeight: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    } else {
                        ContentUnavailableView("Para \(services.partnerNickname)", systemImage: "camera")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { photoSources }
                        VStack(spacing: 12) { photoSources }
                    }.disabled(preparing || sending)
                    if preparing { ProgressView("Preparando foto…") }
                    TextField("Mensaje opcional", text: $caption, axis: .vertical)
                        .lineLimit(1...4).padding(16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        .disabled(sending)
                        .onChange(of: caption) { _, _ in photoID = UUID(); persist() }
                    if caption.utf16.count > 400 {
                        Text("\(caption.utf16.count)/500").font(.caption)
                            .foregroundStyle(caption.utf16.count > 500 ? .red : .secondary)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    }
                    if needsSettings {
                        Button("Abrir Configuración") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.bordered)
                    }
                }.padding(20)
            }
            .coupleScreenBackground()
            .navigationTitle("Enviar foto").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { persist(); dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { send() } label: {
                        if sending { ProgressView() } else { Text("Enviar") }
                    }.disabled(imageData == nil || preparing || sending || !current || caption.utf16.count > 500)
                }
                ToolbarItem(placement: .bottomBar) {
                    if hasDraft { Button("Descartar borrador", role: .destructive) { confirmDiscard = true }.disabled(sending) }
                }
            }
            .interactiveDismissDisabled(sending)
            .fullScreenCover(isPresented: $cameraShowing) {
                CoupleCameraView { image in
                    cameraShowing = false
                    guard current else { return }
                    do {
                        guard let bytes = image.jpegData(compressionQuality: 0.9) else { throw ServiceError.invalidResponse }
                        setPhoto(try SelectedPhoto.jpeg(bytes))
                    } catch { self.error = "No se pudo preparar la foto. Volvé a intentarlo." }
                } onCancel: { cameraShowing = false }
                .ignoresSafeArea()
            }
            .photoLibrarySheet(isPresented: $choosingPhoto, preparing: $preparing, onImage: { image in
                guard current else { return }
                guard let bytes = image.jpegData(compressionQuality: 0.85) else {
                    error = "No se pudo preparar la foto. Elegí otra imagen."; return
                }
                setPhoto(bytes)
            }, onFailure: { error = $0 })
            .task(id: scenePhase) {
                guard scenePhase == .active, current else { return }
                if opensCamera, !attemptedCamera {
                    attemptedCamera = true
                    await openCamera()
                } else if opensPhotoLibrary, !opensCamera, !attemptedLibrary {
                    attemptedLibrary = true
                    if imageData == nil { choosingPhoto = true }
                }
            }
            .onDisappear { if !finished { persist() } }
            .confirmationDialog("¿Descartar esta foto y su mensaje?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Descartar", role: .destructive) { storage.clear(); imageData = nil; caption = ""; photoID = UUID(); finished = true; dismiss() }
            }
        }
    }

    @ViewBuilder
    private var photoSources: some View {
        Button("Cámara", systemImage: "camera") { Task { await openCamera() } }
            .buttonStyle(.borderedProminent).frame(minHeight: 44).fixedSize(horizontal: true, vertical: false)
        Button("Fotos", systemImage: "photo.on.rectangle") { choosingPhoto = true }
            .buttonStyle(.bordered).frame(minHeight: 44).fixedSize(horizontal: true, vertical: false)
    }

    private func setPhoto(_ data: Data) {
        imageData = data; photoID = UUID(); error = nil; persist()
    }

    private func persist() {
        guard current, !finished else { return }
        do { try storage.savePhoto(imageData); try storage.saveValue(Draft(id: photoID, caption: caption)) }
        catch { self.error = "No se pudo guardar el borrador en este iPhone. Mantené esta pantalla abierta y reintentá." }
    }

    private func openCamera() async {
        guard current, !sending, !cameraShowing else { return }
        error = nil; needsSettings = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            error = "Este dispositivo no tiene una cámara disponible. Podés elegir una foto de la biblioteca."; return
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard current else { return }
        if allowed { cameraShowing = true }
        else { needsSettings = true; error = "Activá el acceso a la cámara en Configuración para sacar una foto." }
    }

    private func send() {
        guard current, !sending, !preparing, let bytes = imageData, caption.utf16.count <= 500 else { return }
        let id = photoID, text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true; error = nil; persist()
        Task { @MainActor in
            defer { sending = false }
            guard current else { return }
            do {
                let photo = try await services.sendPhoto(id: id, data: bytes, caption: text)
                guard current else { return }
                onSent(photo)
                finished = true; storage.clear(); UINotificationFeedbackGenerator().notificationOccurred(.success); dismiss()
            } catch { if current { self.error = "No se pudo enviar. Tu foto sigue acá; tocá Enviar para reintentar." } }
        }
    }
}

private struct CoupleCameraView: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera; picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CoupleCameraView
        init(parent: CoupleCameraView) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { parent.onCancel(); return }
            parent.onPhoto(image)
        }
    }
}
