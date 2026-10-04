import PairNotesCore
import SwiftUI
import UIKit
import WidgetKit

struct CoupleEntry: TimelineEntry {
    let date: Date
    let snapshot: CoupleWidgetSnapshot?
    let avatars: [String: Data]
    let message: String
    let cached: Bool

    static func empty(at date: Date = Date(), message: String = "Abrí PairNotes para conectar el widget.") -> Self {
        Self(date: date, snapshot: nil, avatars: [:], message: message, cached: false)
    }
}

struct CoupleProvider: TimelineProvider {
    func placeholder(in context: Context) -> CoupleEntry { .empty(message: "Su espacio compartido") }

    func getSnapshot(in context: Context, completion: @escaping (CoupleEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task {
            let result = await WidgetRemoteClient.shared.refresh()
            completion(entry(result, at: Date()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoupleEntry>) -> Void) {
        Task {
            let result = await WidgetRemoteClient.shared.refresh()
            let now = Date()
            let expiry = result.expiresAt ?? now.addingTimeInterval(15 * 60)
            var dates: [Date] = [now]
            if let updated = result.couple?.distance.updatedAt {
                dates += [updated.addingTimeInterval(CoupleDistance.freshAge), updated.addingTimeInterval(CoupleDistance.maximumAge)]
                    .filter { $0 > now && $0 < expiry }
            }
            if let midnight = Calendar.current.dateInterval(of: .day, for: now)?.end,
               midnight > now, midnight < expiry { dates.append(midnight) }
            var entries = Array(Set(dates)).sorted().map { entry(result, at: $0) }
            if result.couple != nil, expiry > now { entries.append(.empty(at: expiry)) }
            completion(Timeline(entries: entries, policy: .after(max(now.addingTimeInterval(30), expiry))))
        }
    }

    private func entry(_ result: WidgetRefreshResult, at date: Date) -> CoupleEntry {
        CoupleEntry(date: date, snapshot: result.couple, avatars: result.avatars,
                    message: result.couple == nil ? "Abrí PairNotes para conectar el widget." : result.message,
                    cached: result.cached)
    }
}

private enum CoupleWidgetContent { case message, together, anniversary, distance }

private struct CoupleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CoupleEntry
    let content: CoupleWidgetContent
    private var accessory: Bool { family == .accessoryRectangular }

    private var title: String {
        switch content {
        case .message: return "Un mensaje para vos"
        case .together: return "Juntos desde"
        case .anniversary: return "Su aniversario"
        case .distance: return "Entre ustedes"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: accessory ? 2 : 7) {
            Label(title, systemImage: content == .message ? "heart.text.clipboard" : "heart")
                .font(accessory ? .caption.weight(.semibold) : .headline).lineLimit(1)
            if let snapshot = entry.snapshot {
                contentView(snapshot).privacySensitive()
                if entry.cached {
                    Text("Sin conexión").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(entry.message).font(.caption).lineLimit(accessory ? 2 : 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: content == .message ? "pairnotes://messages" : "pairnotes://couple"))
    }

    @ViewBuilder
    private func contentView(_ snapshot: CoupleWidgetSnapshot) -> some View {
        switch content {
        case .message:
            if let message = snapshot.latestMessage {
                Text(message.text).font(accessory ? .caption : .body).lineLimit(accessory ? 2 : 4)
                if !accessory {
                    Text(snapshot.profiles.first(where: { $0.uid == message.authorID })?.displayName ?? "Tu pareja")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else { Text("Tu próximo mensaje recibido aparecerá acá.").font(.caption).lineLimit(2) }
        case .together:
            if let started = snapshot.startedOn, let days = started.daysTogether(on: entry.date) {
                Text("\(days) días juntos").font(accessory ? .headline : .title2.bold()).minimumScaleFactor(0.7).lineLimit(1)
                if let date = started.date() {
                    Text(date, format: .dateTime.day().month(.abbreviated).year()).font(.caption2).foregroundStyle(.secondary)
                }
            } else { Text("Elegí su fecha en Nosotros.").font(.caption).lineLimit(2) }
        case .anniversary:
            if let days = snapshot.startedOn?.daysUntilAnniversary(on: entry.date) {
                Text(days == 0 ? "¡Hoy es su aniversario!" : "Faltan \(days) días")
                    .font(accessory ? .headline : .title2.bold()).minimumScaleFactor(0.7).lineLimit(2)
                if !accessory { avatars(snapshot) }
            } else { Text("Elegí su fecha en Nosotros.").font(.caption).lineLimit(2) }
        case .distance:
            HStack(spacing: 5) {
                avatars(snapshot)
                VStack(alignment: .leading, spacing: 1) {
                    Text(distanceText(snapshot.distance)).font(accessory ? .caption.weight(.semibold) : .headline).lineLimit(2)
                    if let updated = snapshot.distance.updatedAt,
                       snapshot.distance.displayMeters(at: entry.date) != nil {
                        HStack(spacing: 3) {
                            Text(snapshot.distance.displayStatus(at: entry.date) == .stale ? "Dato anterior" : "Actualizada")
                            Text(updated, style: .relative)
                        }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func distanceText(_ distance: CoupleDistance) -> String {
        switch distance.displayStatus(at: entry.date) {
        case .disabled: return "Ubicación pausada"
        case .waiting: return "Esperando ubicación"
        case .available, .stale:
            guard let meters = distance.displayMeters(at: entry.date) else { return "Sin ubicación reciente" }
            if meters < 100 { return "Aprox. menos de 100 m" }
            if meters < 1_000 { return "Aprox. \(Int((meters / 100).rounded()) * 100) m" }
            return "Aprox. \((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
        }
    }

    private func avatars(_ snapshot: CoupleWidgetSnapshot) -> some View {
        HStack(spacing: -4) {
            ForEach(snapshot.profiles) { profile in
                Group {
                    if let data = entry.avatars[profile.uid], let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Circle().fill(.secondary.opacity(0.18))
                            Text(profile.initials.isEmpty ? "♡" : profile.initials).font(.system(size: accessory ? 9 : 13, weight: .semibold))
                        }
                    }
                }
                .frame(width: accessory ? 22 : 34, height: accessory ? 22 : 34)
                .clipShape(Circle())
                .accessibilityLabel(profile.displayName)
            }
        }
    }
}

struct ReceivedMessageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.messageKind, provider: CoupleProvider()) {
            CoupleWidgetView(entry: $0, content: .message)
        }
        .configurationDisplayName("Tu mensaje")
        .description("El último mensaje privado que tu pareja te envió.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}

struct TogetherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.togetherKind, provider: CoupleProvider()) {
            CoupleWidgetView(entry: $0, content: .together)
        }
        .configurationDisplayName("Juntos desde")
        .description("Días del calendario desde su fecha elegida.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}

struct AnniversaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.anniversaryKind, provider: CoupleProvider()) {
            CoupleWidgetView(entry: $0, content: .anniversary)
        }
        .configurationDisplayName("Nuestro aniversario")
        .description("Días hasta su próximo aniversario.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}

struct DistanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.distanceKind, provider: CoupleProvider()) {
            CoupleWidgetView(entry: $0, content: .distance)
        }
        .configurationDisplayName("Nuestra distancia")
        .description("Distancia aproximada con sus avatares, cuando ambos comparten ubicación. Puede estar desactualizada.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}
