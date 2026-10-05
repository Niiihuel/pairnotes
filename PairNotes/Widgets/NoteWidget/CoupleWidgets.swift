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

    static func empty(at date: Date = Date(), message: String = "Tu espacio aparecerá al iniciar sesión y vincular sus cuentas.") -> Self {
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
            if result.couple != nil, expiry > now { entries.append(.empty(at: expiry, message: "Esperando conexión para actualizar…")) }
            completion(Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(15 * 60), max(now.addingTimeInterval(30), expiry)))))
        }
    }

    private func entry(_ result: WidgetRefreshResult, at date: Date) -> CoupleEntry {
        CoupleEntry(date: date, snapshot: result.couple, avatars: result.avatars,
                    message: result.message,
                    cached: result.cached)
    }
}

private enum CoupleWidgetContent { case message, together, anniversary, distance, gesture }

private struct CoupleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CoupleEntry
    let content: CoupleWidgetContent
    private var theme: CoupleTheme { entry.snapshot?.personalization?.theme ?? .rose }
    private var accessory: Bool { family == .accessoryRectangular }

    private var title: String {
        switch content {
        case .gesture: return "Te estoy pensando"
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
        .foregroundStyle(theme.ink)
        .containerBackground(theme.paper, for: .widget)
        .widgetURL(URL(string: content == .gesture ? "pairnotes://home" : (content == .message ? "pairnotes://messages" : "pairnotes://couple")))
    }

    @ViewBuilder
    private func contentView(_ snapshot: CoupleWidgetSnapshot) -> some View {
        switch content {
        case .gesture:
            if let gesture = snapshot.latestGesture {
                HStack(spacing: 12) {
                    if let sender = snapshot.profiles.first(where: { $0.uid == gesture.authorId }) { avatar(sender, size: accessory ? 24 : 42) }
                    Text(gesture.kind.symbol).font(accessory ? .title3 : .largeTitle)
                }
                Text(gesture.kind.title).font(.headline)
                Text("Tocá para mandar otro detalle").font(.caption2).foregroundStyle(.secondary)
            } else { Text("Un corazón, un abrazo, un beso. Tocá para acercarte.").font(.caption) }
        case .message:
            if let message = snapshot.latestMessage {
                HStack(alignment: .bottom, spacing: 8) {
                    if let sender = snapshot.profiles.first(where: { $0.uid == message.authorID }) {
                        avatar(sender, size: accessory ? 24 : 38)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.text)
                            .font(accessory ? .caption : .body)
                            .lineLimit(accessory ? 2 : 4)
                        if !accessory {
                            Text(snapshot.personalization?.name(for: message.authorID, fallback: snapshot.profiles.first(where: { $0.uid == message.authorID })?.displayName ?? "Tu pareja") ?? snapshot.profiles.first(where: { $0.uid == message.authorID })?.displayName ?? "Tu pareja")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(accessory ? 5 : 10)
                    .background(theme.accent.opacity(0.12), in: UnevenRoundedRectangle(
                        topLeadingRadius: 14, bottomLeadingRadius: 3, bottomTrailingRadius: 14, topTrailingRadius: 14))
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
            VStack(spacing: accessory ? 2 : 10) {
                HStack(spacing: 4) {
                    if let first = snapshot.profiles.first { avatar(first, size: accessory ? 24 : (family == .systemSmall ? 36 : 48)) }
                    VStack(spacing: 5) {
                        Text(distanceText(snapshot.distance))
                            .font(accessory ? .caption2 : .caption.weight(.semibold))
                            .minimumScaleFactor(0.7).lineLimit(2).multilineTextAlignment(.center)
                        GeometryReader { geometry in
                            Path { path in
                                path.move(to: CGPoint(x: 0, y: 3))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: 3))
                            }.stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))
                        }.frame(height: 6)
                    }.frame(maxWidth: .infinity)
                    if let last = snapshot.profiles.last, snapshot.profiles.count > 1 {
                        avatar(last, size: accessory ? 24 : (family == .systemSmall ? 36 : 48))
                    }
                }
                if !accessory { Text("Siempre cerquita").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private func distanceText(_ distance: CoupleDistance) -> String {
        switch distance.displayStatus(at: entry.date) {
        case .disabled: return "Ubicación pausada"
        case .waiting: return "Esperando ubicación"
        case .available, .stale:
            guard let meters = distance.displayMeters(at: entry.date) else { return "Sin ubicación reciente" }
            if meters < 100 { return "< 100 m" }
            if meters < 1_000 { return "\(Int((meters / 100).rounded()) * 100) m" }
            return "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
        }
    }

    private func avatar(_ profile: CoupleProfile, size: CGFloat) -> some View {
        Group {
            if let data = entry.avatars[profile.uid], let image = UIImage(data: data) {
                Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(uiColor: .secondarySystemBackground))
                    Text(profile.initials.isEmpty ? "♡" : profile.initials).font(.system(size: size * 0.35, weight: .semibold))
                }
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityLabel(profile.displayName)
    }

    private func avatars(_ snapshot: CoupleWidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            ForEach(snapshot.profiles) { profile in avatar(profile, size: accessory ? 22 : 34) }
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
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}

struct ThinkingOfYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.gestureKind, provider: CoupleProvider()) {
            CoupleWidgetView(entry: $0, content: .gesture)
        }
        .configurationDisplayName("Te estoy pensando")
        .description("El último corazón, abrazo o beso entre ustedes. Tocá para responder desde Inicio.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}
