import PairNotesCore
import SwiftUI
import UIKit

struct TimelineView: View {
    @ObservedObject var model: AppModel
    let openNote: (RemoteNote) -> Void

    private var days: [TimelineDay] {
        NoteTimeline.groupedByDay(model.notes, calendar: .current)
    }

    var body: some View {
        List {
            SharedMemoriesSection(services: model.services, notes: model.notes, openNote: openNote)
            if model.notes.isEmpty {
                Section {
                    if model.isLoading {
                        ProgressView("Cargando recuerdos…")
                    } else {
                        ContentUnavailableView("Sus recuerdos, día por día", systemImage: "calendar",
                            description: Text(model.membership == nil
                                ? "Vinculá las dos cuentas en Nosotros para compartir dibujos."
                                : "Las notas enviadas aparecen acá. Los borradores quedan privados en Crear."))
                    }
                }
            }
            ForEach(days) { day in
                Section(day.id.formatted(date: .long, time: .omitted)) {
                    ForEach(day.notes) { note in
                        Button { openNote(note) } label: {
                            HStack(spacing: 14) {
                                AsyncNoteImage(path: note.assets.thumbnail, services: model.services)
                                    .frame(width: 76, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(note.authorID == model.identity?.uid ? "Tu dibujo" : "De \(model.membership?.partner.displayName ?? "tu pareja")")
                                        .font(.headline)
                                    Text(note.serverPublishedAt, format: .dateTime.hour().minute())
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.nextCursor != nil {
                Section {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        if model.isLoadingMore { ProgressView("Cargando…") }
                        else { Label("Ver días anteriores", systemImage: "clock.arrow.circlepath") }
                    }
                    .disabled(model.isLoading || model.isLoadingMore)
                }
            }
            if let status = model.status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Recuerdos")
        .refreshable { await model.foreground() }
    }
}

/// Decoded images are bound to both path and session. SwiftUI may reuse this view
/// across account changes, so old pixels are hidden before a new task starts.
struct AsyncNoteImage: View {
    let path: String
    @ObservedObject var services: AppServices
    @State private var image: UIImage?
    @State private var loadedKey: RequestKey?
    @State private var failedKey: RequestKey?

    private struct RequestKey: Hashable {
        let path: String
        let uid: String?
        let pairID: String?
        let epoch: UInt64?
    }

    private var requestKey: RequestKey {
        RequestKey(path: path, uid: services.identity?.uid,
                   pairID: services.membership?.id, epoch: services.membership?.pairEpoch)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if loadedKey == requestKey, let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Dibujo compartido")
            } else if failedKey == requestKey {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title2)
                    Text("Imagen no disponible").font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(6)
            } else {
                ProgressView().accessibilityLabel("Cargando dibujo")
            }
        }
        .task(id: requestKey) {
            let key = requestKey
            image = nil
            loadedKey = nil
            failedKey = nil
            do {
                let bytes = try await services.image(path: key.path)
                try Task.checkCancellation()
                guard key == requestKey else { return }
                guard let decoded = UIImage(data: bytes) else { throw LocalStoreError.corruptData }
                image = decoded
                loadedKey = key
            } catch is CancellationError {
                return
            } catch {
                guard key == requestKey, !Task.isCancelled else { return }
                failedKey = key
            }
        }
    }
}
