import AVFoundation
import PairNotesCore
import PhotosUI
import SwiftUI
import UIKit

/// The widget opens this screen; capture and sending always happen in the app.
struct QuickPhotoComposer: View {
    @ObservedObject var services: AppServices
    var opensCamera = false
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
    @State private var confirmDiscard = false
    private let storage: MemoryCompositionStorage
    private let scope: String

    private struct Draft: Codable { let id: UUID; let caption: String }

    init(services: AppServices, opensCamera: Bool = false) {
        self.services = services; self.opensCamera = opensCamera
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
                        ContentUnavailableView("Un momento para compartir", systemImage: "camera.fill",
                            description: Text("Sacá una foto o elegí una de tu biblioteca para \(services.partnerNickname)."))
                    }
                    HStack(spacing: 12) {
                        Button("Sacar foto", systemImage: "camera.fill") { Task { await openCamera() } }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        Button("Biblioteca", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }.disabled(preparing || sending)
                    if preparing { ProgressView("Preparando foto…") }
                    TextField("Un mensaje para acompañarla", text: $caption, axis: .vertical)
                        .lineLimit(2...4).padding(16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        .disabled(sending)
                        .onChange(of: caption) { _, _ in photoID = UUID(); persist() }
                    Text("Sólo para ustedes. Podés revisarla antes de enviarla.")
                        .font(.footnote).foregroundStyle(.secondary)
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
            .navigationTitle("Una foto para vos").navigationBarTitleDisplayMode(.inline)
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
                guard scenePhase == .active, opensCamera, !attemptedCamera else { return }
                attemptedCamera = true
                await openCamera()
            }
            .onDisappear { if !finished { persist() } }
            .confirmationDialog("¿Descartar esta foto y su mensaje?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Descartar", role: .destructive) { storage.clear(); imageData = nil; caption = ""; photoID = UUID(); finished = true; dismiss() }
            }
        }
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
            do {
                _ = try await services.sendPhoto(id: id, data: bytes, caption: text)
                guard current else { return }
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
