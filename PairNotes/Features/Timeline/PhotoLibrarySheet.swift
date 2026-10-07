import SwiftUI
import UIKit

extension View {
    /// Dismiss the system picker completely before displaying a crop/review
    /// sheet. Every entry point uses the same bounded, orientation-aware import.
    func photoLibrarySheet(isPresented: Binding<Bool>, preparing: Binding<Bool>,
                           onImage: @escaping (UIImage) -> Void, onFailure: @escaping (String) -> Void) -> some View {
        modifier(PhotoLibrarySheet(isPresented: isPresented, preparing: preparing, onImage: onImage, onFailure: onFailure))
    }
}

private struct PhotoLibrarySheet: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var preparing: Bool
    let onImage: (UIImage) -> Void
    let onFailure: (String) -> Void
    @State private var provider: NSItemProvider?
    @State private var importTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: importPhoto) {
            PaperPhotoPicker { value in provider = value; isPresented = false }
        }
        .onDisappear { importTask?.cancel(); importTask = nil }
    }

    private func importPhoto() {
        guard let provider else { return }
        self.provider = nil; importTask?.cancel(); preparing = true
        importTask = Task { @MainActor in
            defer { preparing = false }
            do {
                let bytes = try await PaperPhotoImport.loadData(from: provider)
                guard !Task.isCancelled else { return }
                onImage(try PaperPhotoImport.decode(bytes))
            } catch {
                guard !Task.isCancelled else { return }
                onFailure((error as? PaperPhotoImport.Failure)?.message ?? "No se pudo descargar la foto. Revisá la conexión si está en iCloud y reintentá.")
            }
        }
    }
}
