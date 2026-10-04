import PairNotesCore
import SwiftUI
import UIKit
import WidgetKit

struct ReceivedNoteEntry: TimelineEntry {
    let date: Date
    let image: UIImage?
    let noteID: UUID?
    let authorName: String?
    let publishedAt: Date?
    let message: String

    static func empty(_ message: String, at date: Date = Date()) -> Self {
        Self(date: date, image: nil, noteID: nil, authorName: nil, publishedAt: nil, message: message)
    }
}

struct ReceivedNoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReceivedNoteEntry {
        .empty("Un dibujo para vos.")
    }

    func getSnapshot(in context: Context, completion: @escaping (ReceivedNoteEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { @MainActor in
            completion(entry(from: await WidgetRemoteClient.shared.refresh()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReceivedNoteEntry>) -> Void) {
        Task { @MainActor in
            let result = await WidgetRemoteClient.shared.refresh()
            let now = Date()
            var entries = [entry(from: result)]
            if let expiry = result.expiresAt, expiry > now {
                entries.append(.empty("Abrí PairNotes para volver a conectar el widget.", at: expiry))
            }
            // Push complements this request; WidgetKit chooses actual execution.
            let next = min(now.addingTimeInterval(30 * 60), result.expiresAt ?? now.addingTimeInterval(15 * 60))
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    @MainActor
    private func entry(from result: WidgetRefreshResult) -> ReceivedNoteEntry {
        guard let snapshot = result.snapshot, let image = UIImage(data: snapshot.pngData) else {
            return .empty(result.message.isEmpty ? "Todavía no recibiste dibujos." : result.message)
        }
        return ReceivedNoteEntry(date: Date(), image: image, noteID: snapshot.noteID,
            authorName: snapshot.authorName, publishedAt: snapshot.updatedAt, message: result.message)
    }
}

struct PairNotesWidgetPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let enabled = widgets.contains { SharedWidgetContainer.allWidgetKinds.contains($0.kind) }
        Task { await WidgetRemoteClient.shared.registerPushToken(pushInfo.token, enabled: enabled) }
    }
}

struct ReceivedNoteWidgetView: View {
    let entry: ReceivedNoteEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = entry.image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Último dibujo recibido de \(entry.authorName ?? "tu pareja")")
                    .privacySensitive()
                HStack {
                    Text(entry.authorName ?? "Para vos").lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = entry.publishedAt { Text(date, style: .relative).lineLimit(1) }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if !entry.message.isEmpty {
                    Text(entry.message).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Label("PairNotes", systemImage: "heart.text.clipboard").font(.headline)
                Text(entry.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.noteID.flatMap { URL(string: "pairnotes://note/\($0.uuidString.lowercased())") }
                   ?? URL(string: "pairnotes://couple"))
    }
}

struct NoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.widgetKind, provider: ReceivedNoteProvider()) { entry in
            ReceivedNoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Último dibujo")
        .description("La última nota que tu pareja te envió. Tocala para abrir el recuerdo.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}
