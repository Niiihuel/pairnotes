import PairNotesCore
import SwiftUI
import UIKit

struct DraftLibraryView: View {
    @ObservedObject var model: AppModel
    let openDraft: (DraftSummary?) -> Void
    let openNote: (RemoteNote) -> Void
    @State private var tab = LibraryTab.drafts
    private enum LibraryTab: String, CaseIterable, Identifiable {
        case drafts = "Borradores", sent = "Enviados"
        var id: String { rawValue }
    }
    private var visibleDrafts: [DraftSummary] {
        model.drafts.filter { draft in
            !model.outbox.contains { $0.status == .sent && $0.archive.document.id == draft.id && $0.archive.document.revision == draft.revision }
        }
    }
    private var visibleOperations: [OutboxOperation] {
        model.outbox.reversed().filter { !model.hiddenSentIDs.contains($0.id.uuidString.lowercased()) }
    }
    private var otherSentNotes: [RemoteNote] {
        let localIDs = Set(model.outbox.map { $0.id.uuidString.lowercased() })
        return model.notes.filter {
            $0.authorID == model.identity?.uid && !localIDs.contains($0.id) && !model.hiddenSentIDs.contains($0.id)
        }
    }
    @State private var copyingGuest: UUID?
    @State private var copiedGuest: Set<UUID> = []

    var body: some View {
        List {
            Section {
                Picker("Mis dibujos", selection: $tab) {
                    ForEach(LibraryTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }.pickerStyle(.segmented).accessibilityIdentifier("library.tabs")
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            if tab == .drafts {
            Section {
                Button { openDraft(nil) } label: {
                    Label("Nuevo dibujo", systemImage: "square.and.pencil")
                }
                .disabled(model.catalog == nil)
            } footer: {
                Text(model.identity == nil
                     ? "Privados en este iPhone. Podés copiarlos a tu cuenta después."
                     : "Borradores privados en este iPhone.")
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
                    Text("Copiar conserva los originales.")
                }
            }

            Section("Mis borradores") {
                if visibleDrafts.isEmpty {
                    Text("Sin borradores").foregroundStyle(.secondary)
                }
                ForEach(visibleDrafts) { draft in
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
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
                    .contextMenu {
                        Button("Abrir borrador", systemImage: "pencil") { openDraft(draft) }
                        Button("Eliminar borrador", systemImage: "trash", role: .destructive) {
                            Task { await model.deleteDraft(draft) }
                        }
                    } preview: {
                        if let catalog = model.catalog {
                            DraftThumbnail(catalog: catalog, draft: draft).frame(width: 280, height: 280)
                                .background(Color(uiColor: .systemBackground))
                        }
                    }
                    .swipeActions {
                        Button("Eliminar", role: .destructive) {
                            Task { await model.deleteDraft(draft) }
                        }
                    }
                }
            }

            } else {
            if visibleOperations.isEmpty && otherSentNotes.isEmpty {
                ContentUnavailableView("Sin dibujos enviados", systemImage: "paperplane")
            }
            if !visibleOperations.isEmpty {
                Section {
                    ForEach(visibleOperations) { operation in
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let note = operation.publishedNote { openNote(note) }
                        }
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
                        .contextMenu {
                            if let note = operation.publishedNote {
                                Button("Ver dibujo", systemImage: "eye") { openNote(note) }
                            }
                            if let draft = model.drafts.first(where: { $0.id == operation.archive.document.id }) {
                                Button("Seguir editando", systemImage: "pencil") { openDraft(draft) }
                            }
                            if operation.status == .sent || operation.status == .cancelled {
                                Button("Quitar de esta lista", systemImage: "trash", role: .destructive) {
                                    model.hideSent(id: operation.id.uuidString.lowercased())
                                }
                            }
                            if operation.status == .failed {
                                Button("Reintentar", systemImage: "arrow.clockwise") { Task { await model.retry(operation) } }
                                    .disabled(!model.canSend)
                            }
                        } preview: {
                            if let bytes = operation.archive.image(for: .thumbnail)?.pngData, let image = UIImage(data: bytes) {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 280, height: 280)
                            }
                        }
                    }
                } header: {
                    Text("Tus envíos")
                } footer: {
                    Text("Quitar de la lista conserva la copia compartida.")
                }
            }
            if !otherSentNotes.isEmpty {
                Section("También compartiste") {
                    ForEach(otherSentNotes) { note in
                        Button { openNote(note) } label: {
                            HStack(spacing: 14) {
                                AsyncNoteImage(path: note.assets.thumbnail, services: model.services)
                                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Un dibujo para \(model.membership?.partner.displayName ?? "tu pareja")").font(.headline)
                                    Text(note.serverPublishedAt, format: .dateTime.day().month().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("Ver dibujo", systemImage: "eye") { openNote(note) }
                            Button("Quitar de esta lista", systemImage: "trash", role: .destructive) { model.hideSent(id: note.id) }
                        } preview: {
                            AsyncNoteImage(path: note.assets.widget, services: model.services).frame(width: 280, height: 280)
                        }
                    }
                }
            }
            if model.nextCursor != nil {
                Button("Ver más enviados") { Task { await model.loadMore() } }.disabled(model.isLoadingMore)
            }
            }
            if let status = model.status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let title = model.undoRemovalTitle {
                HStack {
                    Text(title).font(.subheadline)
                    Spacer()
                    Button("Deshacer") { Task { await model.undoLastRemoval() } }.disabled(model.isUndoingRemoval)
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
            }
        }
        .navigationTitle("Dibujos")
        .onChange(of: model.identity?.uid) { _, _ in copiedGuest = []; copyingGuest = nil }
        .refreshable {
            await model.reloadDrafts()
            if tab == .sent { await model.foreground() }
        }
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
