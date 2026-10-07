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
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: CoupleEntry
    let content: CoupleWidgetContent
    private var theme: CoupleTheme { entry.snapshot?.personalization?.theme ?? .rose }
    private var accessory: Bool { family == .accessoryRectangular || family == .accessoryCircular }

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
            if !(accessory && (content == .distance || content == .message || content == .together)) {
                Label(title, systemImage: content == .message ? "bubble.left.fill" : "heart")
                    .font(accessory ? .caption.weight(.semibold) : .headline).lineLimit(1)
                    .widgetAccentable()
            }
            if let snapshot = entry.snapshot {
                contentView(snapshot).privacySensitive()
                if entry.cached && !accessory {
                    Text("Sin conexión").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(entry.message).font(.caption).lineLimit(accessory ? 2 : 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(accessory || renderingMode != .fullColor ? Color.primary : theme.ink)
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
                HStack(alignment: .center, spacing: accessory ? 5 : 8) {
                    if let sender = snapshot.profiles.first(where: { $0.uid == message.authorID }) {
                        avatar(sender, size: accessory ? 28 : 38)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.text)
                            .font(accessory ? .caption.weight(.semibold) : .body)
                            .lineLimit(accessory ? 2 : 4)
                        if !accessory {
                            Text(snapshot.personalization?.name(for: message.authorID, fallback: snapshot.profiles.first(where: { $0.uid == message.authorID })?.displayName ?? "Tu pareja") ?? snapshot.profiles.first(where: { $0.uid == message.authorID })?.displayName ?? "Tu pareja")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, accessory ? 7 : 10)
                    .padding(.leading, accessory ? 10 : 14)
                    .padding(.trailing, accessory ? 7 : 10)
                    .background {
                        MessageBubbleShape().fill(accessory ? Color.primary.opacity(0.17) : theme.accent.opacity(0.16))
                    }
                }
            } else { Text("Tu próximo mensaje recibido aparecerá acá.").font(.caption).lineLimit(2) }
        case .together:
            if let started = snapshot.startedOn, let days = started.daysTogether(on: entry.date) {
                if accessory {
                    VStack(spacing: 0) {
                        Image(systemName: "heart.fill").font(.caption)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "heart.fill").font(.system(size: 8)).offset(x: 4, y: -2)
                            }
                            .widgetAccentable()
                        Text(days.formatted(.number.grouping(.never))).font(.headline.bold()).lineLimit(1).minimumScaleFactor(0.85)
                        Text("días juntos").font(.caption2).lineLimit(1)
                    }.frame(maxWidth: .infinity)
                } else {
                    Text("\(days) días juntos").font(.title2.bold()).minimumScaleFactor(0.7).lineLimit(1)
                    if let date = started.date() {
                        Text(date, format: .dateTime.day().month(.abbreviated).year()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else { Text("Elegí su fecha en Nosotros.").font(.caption).lineLimit(2) }
        case .anniversary:
            if let days = snapshot.startedOn?.daysUntilAnniversary(on: entry.date) {
                Text(days == 0 ? "¡Hoy es su aniversario!" : "Faltan \(days) días")
                    .font(accessory ? .headline : .title2.bold()).minimumScaleFactor(0.7).lineLimit(2)
                if !accessory { avatars(snapshot) }
            } else { Text("Elegí su fecha en Nosotros.").font(.caption).lineLimit(2) }
        case .distance:
            distanceContent(snapshot)
        }
    }

    private func distanceContent(_ snapshot: CoupleWidgetSnapshot) -> some View {
        let presentation = CoupleDistancePresentation(distance: snapshot.distance, at: entry.date)
        let size: CGFloat = accessory ? 28 : family == .systemSmall ? 36 : 48
        return VStack(spacing: accessory ? 2 : 8) {
            Text(presentation.title).font(accessory ? .caption.bold() : .headline)
                .minimumScaleFactor(0.85).lineLimit(1)
            GeometryReader { geometry in
                let available = max(0, geometry.size.width - size * 2 - (accessory ? 24 : 30))
                let spread = available * presentation.separation
                HStack(spacing: 0) {
                    if let first = snapshot.profiles.first { avatar(first, size: size) }
                    Spacer().frame(width: spread / 2)
                    Image(systemName: "heart.fill").font(.system(size: accessory ? 14 : 20))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "heart.fill").font(.system(size: accessory ? 9 : 13)).offset(x: 4, y: -3)
                        }
                        .frame(width: accessory ? 24 : 30)
                        .foregroundStyle(accessory || renderingMode != .fullColor ? Color.primary : theme.accent)
                        .widgetAccentable()
                        .opacity(presentation.fresh ? 1 : 0.5)
                    Spacer().frame(width: spread / 2)
                    if let last = snapshot.profiles.last, snapshot.profiles.count > 1 { avatar(last, size: size) }
                }
                .frame(width: geometry.size.width, height: size)
            }.frame(height: size)
            Text(presentation.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.profiles.map(\.displayName).joined(separator: " y ")). \(presentation.title). \(presentation.detail)")
    }

    private func avatar(_ profile: CoupleProfile, size: CGFloat) -> some View {
        WidgetProfileAvatar(data: entry.avatars[profile.uid], name: profile.displayName,
                            initials: profile.initials, theme: theme, size: size)
    }

    private func avatars(_ snapshot: CoupleWidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            ForEach(snapshot.profiles) { profile in avatar(profile, size: accessory ? 22 : 34) }
        }
    }
}

private struct MessageBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 5
        let radius = min(12, rect.height / 3)
        let body = CGRect(x: tail, y: 0, width: max(0, rect.width - tail), height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: radius)
        path.move(to: CGPoint(x: tail + radius, y: rect.height - 3))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height - 1), control: CGPoint(x: tail / 2, y: rect.height + 1))
        path.addQuadCurve(to: CGPoint(x: tail + 1, y: rect.height - radius - 2), control: CGPoint(x: tail + 2, y: rect.height - 5))
        path.closeSubpath()
        return path
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
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
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

private enum CoupleWidgetPreviewData {
    @MainActor
    static func entry(missingAvatars: Bool = false, stale: Bool = false) -> CoupleEntry {
        let now = Date()
        let first = portrait(background: UIColor(red: 0.16, green: 0.32, blue: 0.51, alpha: 1))
        let second = portrait(background: UIColor(red: 0.54, green: 0.23, blue: 0.32, alpha: 1))
        let profiles = [CoupleProfile(uid: "preview-alex", displayName: "Alex"),
                        CoupleProfile(uid: "preview-sam", displayName: "Sam")]
        let snapshot = CoupleWidgetSnapshot(profiles: profiles,
            startedOn: CoupleDate(rawValue: "2023-05-07"),
            latestMessage: CoupleMessage(id: "preview-message", authorID: "preview-sam", recipientID: "preview-alex",
                                         text: "Te extraño demasiado ♡", sentAt: now),
            distance: CoupleDistance(status: .available, meters: 2500,
                updatedAt: stale ? now.addingTimeInterval(-20 * 60) : now, accuracyMeters: 20))
        return CoupleEntry(date: now, snapshot: snapshot,
            avatars: missingAvatars ? [:] : ["preview-alex": first, "preview-sam": second],
            message: "", cached: stale)
    }

    @MainActor
    private static func portrait(background: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { _ in
            background.setFill(); UIBezierPath(rect: CGRect(x: 0, y: 0, width: 96, height: 96)).fill()
            UIColor(red: 0.91, green: 0.69, blue: 0.53, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 28, y: 17, width: 40, height: 47)).fill()
            UIColor(white: 0.13, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 18, y: 62, width: 60, height: 64)).fill()
            UIBezierPath(ovalIn: CGRect(x: 36, y: 36, width: 4, height: 4)).fill()
            UIBezierPath(ovalIn: CGRect(x: 56, y: 36, width: 4, height: 4)).fill()
        }.pngData() ?? Data()
    }
}

struct CoupleWidgetAvatar_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CoupleWidgetView(entry: CoupleWidgetPreviewData.entry(), content: .distance)
                .environment(\.widgetRenderingMode, .fullColor)
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Avatares · color")
            CoupleWidgetView(entry: CoupleWidgetPreviewData.entry(), content: .distance)
                .environment(\.widgetRenderingMode, .accented)
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Avatares · inicio con tinte")
            CoupleWidgetView(entry: CoupleWidgetPreviewData.entry(), content: .distance)
                .environment(\.widgetRenderingMode, .vibrant)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Avatares · bloqueo")
            CoupleWidgetView(entry: CoupleWidgetPreviewData.entry(missingAvatars: true), content: .distance)
                .environment(\.widgetRenderingMode, .vibrant)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Avatares · iniciales visibles")
            CoupleWidgetView(entry: CoupleWidgetPreviewData.entry(stale: true), content: .distance)
                .environment(\.widgetRenderingMode, .vibrant)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Avatares · distancia desactualizada")
            CoupleWidgetView(entry: CoupleWidgetPreviewData.entry(), content: .message)
                .environment(\.widgetRenderingMode, .vibrant)
                .redacted(reason: .privacy)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Avatares · contenido privado")
        }
    }
}
