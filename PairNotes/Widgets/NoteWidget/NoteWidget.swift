import PairNotesCore
import SwiftUI
import UIKit
import WidgetKit

struct LocalNoteEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let authorName: String?
    let updatedAt: Date?
    let emptyMessage: String

    static func empty(_ message: String) -> LocalNoteEntry {
        LocalNoteEntry(
            date: Date(),
            image: nil,
            authorName: nil,
            updatedAt: nil,
            emptyMessage: message
        )
    }
}

struct LocalNoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> LocalNoteEntry {
        .empty("Guardá una prueba desde Crear.")
    }

    func getSnapshot(in context: Context, completion: @escaping (LocalNoteEntry) -> Void) {
        Task { @MainActor in
            completion(await loadEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LocalNoteEntry>) -> Void) {
        Task { @MainActor in
            let entry = await loadEntry()
            // Local proof: the app requests a reload after an explicit snapshot write.
            // Reloads remain subject to WidgetKit's scheduling policy.
            completion(Timeline(entries: [entry], policy: .never))
        }
    }

    @MainActor
    private func loadEntry() async -> LocalNoteEntry {
        guard let directory = SharedWidgetContainer.directory() else {
            return .empty("Compartir con el widget aún no está configurado.")
        }

        do {
            let store = WidgetSnapshotStore(directory: directory)
            guard let snapshot = try await store.read() else {
                return .empty("Guardá una prueba desde Crear.")
            }
            guard let image = UIImage(data: snapshot.pngData) else {
                return .empty("No se pudo leer la imagen local.")
            }
            return LocalNoteEntry(
                date: Date(),
                image: image,
                authorName: snapshot.authorName,
                updatedAt: snapshot.updatedAt,
                emptyMessage: ""
            )
        } catch {
            return .empty("No se pudo abrir la prueba local.")
        }
    }
}

struct LocalNoteWidgetView: View {
    let entry: LocalNoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Render de una nota de prueba guardada en este dispositivo")

                HStack {
                    Text("Prueba local")
                    Spacer(minLength: 4)
                    if let date = entry.updatedAt {
                        Text(date, style: .time)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Label("Sin nota local", systemImage: "note.text")
                    .font(.headline)
                Text(entry.emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "pairnotes://create"))
    }
}

struct NoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.widgetKind, provider: LocalNoteProvider()) { entry in
            LocalNoteWidgetView(entry: entry)
        }
        .configurationDisplayName("PairNotes · prueba local")
        .description("Muestra el render local guardado desde Crear. No recibe notas de otra persona todavía.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
