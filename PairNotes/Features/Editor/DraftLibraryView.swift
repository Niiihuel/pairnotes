import PairNotesCore
import SwiftUI
import UIKit

struct DraftLibraryView: View {
    @ObservedObject var model: AppModel
    let openDraft: (DraftSummary?) -> Void
    @State private var copyingGuest: UUID?
    @State private var copiedGuest: Set<UUID> = []

    var body: some View {
        List {
            Section {
                Button { openDraft(nil) } label: {
                    Label("Nuevo dibujo", systemImage: "square.and.pencil")
                }
                .disabled(model.catalog == nil)
            } footer: {
                Text(model.identity == nil
                     ? "Los dibujos de invitado quedan privados en este iPhone. No se transfieren automáticamente al iniciar sesión."
                     : "Tus borradores son privados. Enviar conserva una copia de esa revisión.")
            }

            if !model.guestDrafts.isEmpty {
                Section {
                    ForEach(model.guestDrafts) { draft in
                        Button {
                            guard copyingGuest == nil else { return }
                            copyingGuest = draft.id
                            Task {
                                defer { copyingGuest = nil }
                                if await model.copyGuestDraft(draft) { copiedGuest.insert(draft.id) }
                            }
                        } label: {
                            Label(copiedGuest.contains(draft.id) ? "Copiado: \(draft.title)" : "Copiar: \(draft.title)",
                                  systemImage: copiedGuest.contains(draft.id) ? "checkmark" : "doc.on.doc")
                        }.disabled(copyingGuest != nil || copiedGuest.contains(draft.id))
                    }
                } header: {
                    Text("Dibujos creados como invitado")
                } footer: {
                    Text("Elegí cuáles copiar a esta cuenta para editarlos y enviarlos. Los originales se conservan en este iPhone.")
                }
            }

            Section("Mis borradores") {
                if model.drafts.isEmpty {
                    Text("Todavía no guardaste dibujos. Creá uno para empezar.").foregroundStyle(.secondary)
                }
                ForEach(model.drafts) { draft in
                    Button { openDraft(draft) } label: {
                        HStack(spacing: 14) {
                            if let catalog = model.catalog {
                                DraftThumbnail(catalog: catalog, draft: draft)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(draft.title).font(.headline)
                                Text(draft.updatedAt, format: .dateTime.day().month().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Guardado en este iPhone").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Eliminar", role: .destructive) {
                            Task { await model.deleteDraft(draft) }
                        }
                    }
                }
            }

            if !model.outbox.isEmpty {
                Section {
                    ForEach(model.outbox.reversed()) { operation in
                        HStack(spacing: 14) {
                            if let data = operation.archive.image(for: .thumbnail)?.pngData,
                               let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Label(title(operation.status), systemImage: symbol(operation.status))
                                    .font(.subheadline)
                                Text(operation.enqueuedAt, format: .dateTime.day().month().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if operation.status == .failed {
                                Button("Reintentar") { Task { await model.retry(operation) } }
                                    .buttonStyle(.borderless)
                                    .disabled(!model.canSend)
                                    .accessibilityLabel("Reintentar el envío del dibujo")
                            }
                        }
                    }
                } header: {
                    Text("Envíos")
                } footer: {
                    Text("Enviado significa que el servidor confirmó la publicación. Las notificaciones y los widgets se actualizan según la conexión y los tiempos de iOS.")
                }
            }
            if let status = model.status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Crear")
        .onChange(of: model.identity?.uid) { _, _ in copiedGuest = []; copyingGuest = nil }
        .refreshable { await model.reloadDrafts() }
    }

    private func title(_ status: OutboxStatus) -> String {
        switch status {
        case .queued: return "En cola"
        case .sending: return "Enviando…"
        case .failed: return "No se pudo enviar"
        case .sent: return "Enviado"
        case .cancelled: return "Envío cancelado"
        }
    }

    private func symbol(_ status: OutboxStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .sending: return "arrow.up.circle"
        case .failed: return "exclamationmark.circle"
        case .sent: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }
}

private struct DraftThumbnail: View {
    let catalog: DraftCatalogStore
    let draft: DraftSummary
    @State private var image: UIImage?
    @State private var loadedKey: RequestKey?
    @State private var failedKey: RequestKey?

    private struct RequestKey: Hashable {
        let store: ObjectIdentifier
        let id: UUID
        let revision: UInt64
    }

    private var key: RequestKey {
        RequestKey(store: ObjectIdentifier(catalog), id: draft.id, revision: draft.revision)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if loadedKey == key, let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityHidden(true)
            } else if failedKey == key {
                Image(systemName: "photo.badge.exclamationmark")
                    .accessibilityLabel("No se pudo abrir la miniatura")
            } else { ProgressView().accessibilityLabel("Cargando miniatura") }
        }
        .task(id: key) {
            let request = key
            image = nil
            loadedKey = nil
            failedKey = nil
            do {
                guard let archive = try await catalog.load(id: draft.id),
                      let data = archive.image(for: .thumbnail)?.pngData,
                      let decoded = UIImage(data: data) else { throw LocalStoreError.corruptData }
                try Task.checkCancellation()
                guard request == key else { return }
                image = decoded
                loadedKey = request
            } catch is CancellationError {
                return
            } catch {
                guard request == key, !Task.isCancelled else { return }
                failedKey = request
            }
        }
    }
}
