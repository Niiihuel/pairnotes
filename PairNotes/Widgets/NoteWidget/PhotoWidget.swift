import ActivityKit
import ImageIO
import PairNotesCore
import SwiftUI
import UIKit
import WidgetKit

struct PartnerPhotoEntry: TimelineEntry {
    let date: Date
    let photo: CouplePhoto?
    let authorName: String
    let image: UIImage?
    let theme: CoupleTheme
    let cached: Bool
    let message: String
    let interactionMessage: String?

    static func empty(_ message: String = "Las fotos de tu pareja aparecerán acá.", at date: Date = Date()) -> Self {
        Self(date: date, photo: nil, authorName: "Tu pareja", image: nil, theme: .rose, cached: false, message: message, interactionMessage: nil)
    }

    @MainActor
    static func preview(theme: CoupleTheme = .rose, reaction: PhotoReactionKind? = nil,
                        message: String? = nil) -> Self {
        let date = Date()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 320)).image { _ in
            UIColor(red: 0.82, green: 0.61, blue: 0.66, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: 240, height: 320)).fill()
            UIImage(systemName: "heart.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 55, y: 100, width: 130, height: 115))
        }
        let id = "50000000-0000-4000-8000-000000000005"
        let photo = CouplePhoto(id: id, authorId: "preview-partner", recipientId: "preview-viewer",
                                caption: "Pensando en vos ♡",
                                photo: CoupleAvatar(id: "60000000-0000-4000-8000-000000000006",
                                                    sha256: ContentDigest.sha256(image.pngData() ?? Data())),
                                sentAt: date, reaction: reaction.map {
                                    PhotoReaction(authorId: "preview-viewer", photoId: id, kind: $0, updatedAt: date)
                                })
        return Self(date: date, photo: photo, authorName: "Tu pareja", image: image,
                    theme: theme, cached: false, message: "", interactionMessage: message)
    }
}

struct PartnerPhotoProvider: TimelineProvider {
    func placeholder(in context: Context) -> PartnerPhotoEntry { .empty() }

    func getSnapshot(in context: Context, completion: @escaping (PartnerPhotoEntry) -> Void) {
        if context.isPreview {
            Task { @MainActor in completion(.preview()) }
            return
        }
        Task { completion(entry(from: await WidgetRemoteClient.shared.refresh())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PartnerPhotoEntry>) -> Void) {
        Task {
            let result = await WidgetRemoteClient.shared.refresh()
            let now = Date()
            var entries = [entry(from: result)]
            if let expiry = result.expiresAt, expiry > now {
                entries.append(.empty("Esperando conexión para actualizar…", at: expiry))
            }
            completion(Timeline(entries: entries, policy: .after(min(now.addingTimeInterval(15 * 60),
                                                                     max(now.addingTimeInterval(30), result.expiresAt ?? now.addingTimeInterval(15 * 60))))))
        }
    }

    private func entry(from result: WidgetRefreshResult) -> PartnerPhotoEntry {
        guard let couple = result.couple, let photo = couple.latestPhoto else { return .empty(result.message) }
        let fallback = couple.profiles.first(where: { $0.uid == photo.authorId })?.displayName ?? "Tu pareja"
        return PartnerPhotoEntry(date: Date(), photo: photo,
                                 authorName: couple.personalization?.name(for: photo.authorId, fallback: fallback) ?? fallback,
                                 image: result.photoData.flatMap { PhotoWidgetImage.decode($0) },
                                 theme: couple.personalization?.theme ?? .rose, cached: result.cached, message: result.message,
                                 interactionMessage: result.photoInteractionMessage)
    }
}

struct PartnerPhotoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PartnerPhotoEntry
    private var large: Bool { family == .systemLarge }

    var body: some View {
        Group {
            if let photo = entry.photo {
                if large {
                    VStack(alignment: .leading, spacing: 10) {
                        metadata(photo)
                        Link(destination: photoURL(photo.id)) {
                            PhotoWidgetImageView(image: entry.image)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                        if !photo.caption.isEmpty {
                            Text(photo.caption).font(.headline).lineLimit(2)
                        }
                        if let message = entry.interactionMessage { Text(message).font(.caption).lineLimit(2) }
                        controls(photo)
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Link(destination: photoURL(photo.id)) {
                            PhotoWidgetImageView(image: entry.image)
                                .frame(width: 86, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 6) {
                            metadata(photo)
                            Text(entry.interactionMessage ?? (photo.caption.isEmpty ? "Una foto para vos" : photo.caption))
                                .font(.headline).lineLimit(2).minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            controls(photo)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Una foto para vos", systemImage: "photo.on.rectangle.angled").font(.headline)
                    Text(entry.message.isEmpty ? "Las fotos de tu pareja aparecerán acá." : entry.message)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Link(destination: URL(string: "pairnotes://camera")!) {
                        Label("Enviar una foto", systemImage: "camera.fill").font(.subheadline.bold())
                    }
                }
            }
        }
        .privacySensitive()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(entry.theme.ink)
        .containerBackground(entry.theme.paper, for: .widget)
        .widgetURL(entry.photo.map { photoURL($0.id) } ?? URL(string: "pairnotes://camera"))
    }

    private func metadata(_ photo: CouplePhoto) -> some View {
        HStack(spacing: 4) {
            Text(entry.authorName).fontWeight(.semibold).lineLimit(1)
            Text("·")
            Text(photo.sentAt, style: .time).lineLimit(1)
            if entry.cached { Image(systemName: "wifi.slash").accessibilityLabel("Sin conexión") }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func controls(_ photo: CouplePhoto) -> some View {
        ViewThatFits(in: .horizontal) {
            controlRow(photo, size: 34, spacing: 5)
            controlRow(photo, size: 29, spacing: 3)
        }
    }

    private func controlRow(_ photo: CouplePhoto, size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(PhotoReactionKind.allCases, id: \.rawValue) { kind in
                Button(intent: PhotoWidgetReactionIntent(photoID: photo.id, assetID: photo.photo.id, kind: kind)) {
                    PhotoReactionLabel(kind: kind, selected: photo.reaction?.kind == kind, size: size)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.title)
                .accessibilityValue(photo.reaction?.kind == kind ? "Reacción enviada" : "")
            }
            Link(destination: URL(string: "pairnotes://camera")!) {
                Image(systemName: "camera.fill").font(.system(size: size / 2, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(entry.theme.accent.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sacar una foto y enviársela a tu pareja")
        }
    }
}

private struct PhotoReactionLabel: View {
    let kind: PhotoReactionKind
    let selected: Bool
    let size: CGFloat

    var body: some View {
        Text(kind.symbol).font(.system(size: size * 0.59))
            .frame(width: size, height: size)
            .background(.primary.opacity(selected ? 0.20 : 0.06), in: Circle())
            .overlay { Circle().strokeBorder(.primary.opacity(selected ? 0.7 : 0.12), lineWidth: selected ? 2 : 1) }
    }
}

private struct PhotoWidgetImageView: View {
    let image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    .accessibilityLabel("Foto recibida de tu pareja")
            } else {
                ZStack {
                    Rectangle().fill(.primary.opacity(0.06))
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }.accessibilityLabel("Foto pendiente de descargar")
            }
        }
    }
}

private enum PhotoWidgetImage {
    static func decode(_ data: Data, maximumPixelSize: Int = 900, scale: CGFloat = 1) -> UIImage? {
        guard data.count <= 5 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}

struct PartnerPhotoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedWidgetContainer.photoKind, provider: PartnerPhotoProvider()) {
            PartnerPhotoWidgetView(entry: $0)
        }
        .configurationDisplayName("La foto de tu pareja")
        .description("Mirá su última foto, reaccioná o enviá una nueva con la cámara.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .pushHandler(PairNotesWidgetPushHandler.self)
    }
}

struct PairPhotoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairPhotoActivityAttributes.self) { context in
            PhotoActivityCard(context: context)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhotoActivityImageView(context: context, maximumPointSize: 70)
                        .frame(width: 60, height: 70).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.isStale ? "Foto finalizada" : context.state.authorName).font(.caption.bold()).lineLimit(1)
                        Text(context.isStale ? "Abrí PairNotes para volver a verla." :
                                context.state.interactionMessage ?? (context.state.caption.isEmpty ? "Una foto para vos" : context.state.caption))
                            .font(.subheadline).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) { PhotoActivityControls(context: context) }
            } compactLeading: {
                Image(systemName: "photo.fill").accessibilityLabel("Foto de tu pareja")
            } compactTrailing: {
                Text(context.isStale ? "♡" : PhotoReactionKind(rawValue: context.state.reactionKind ?? "")?.symbol ?? "♡").font(.caption)
            } minimal: {
                Image(systemName: "heart.fill")
            }
            .widgetURL(photoURL(context.attributes.photoID))
        }
    }
}

private struct PhotoActivityCard: View {
    let context: ActivityViewContext<PairPhotoActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Link(destination: photoURL(context.attributes.photoID)) {
                PhotoActivityImageView(context: context, maximumPointSize: 126)
                    .frame(width: 86, height: 126).clipShape(RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(context.isStale ? "Foto finalizada" : context.state.authorName).fontWeight(.semibold).lineLimit(1)
                    if !context.isStale {
                        Text("·")
                        Text(context.state.sentAt, style: .time).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(intent: DismissPhotoActivityIntent(activityID: context.activityID)) {
                        Image(systemName: "xmark").font(.caption2.bold()).frame(width: 26, height: 26)
                            .background(.white.opacity(0.12), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Cerrar la foto en vivo")
                }.font(.caption).foregroundStyle(.white.opacity(0.75))
                Text(context.isStale ? "Abrí PairNotes para volver a verla." :
                        context.state.interactionMessage ?? (context.state.caption.isEmpty ? "Una foto para vos" : context.state.caption))
                    .font(.headline).lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                PhotoActivityControls(context: context)
            }
        }
        .padding(12).frame(height: 150)
        .foregroundStyle(.white)
        .privacySensitive()
        .widgetURL(photoURL(context.attributes.photoID))
    }
}

private struct PhotoActivityImageView: View {
    @Environment(\.displayScale) private var displayScale
    let context: ActivityViewContext<PairPhotoActivityAttributes>
    let maximumPointSize: CGFloat

    var body: some View {
        if context.isStale {
            ZStack {
                Rectangle().fill(.primary.opacity(0.06))
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(.secondary)
            }.accessibilityLabel("Foto finalizada")
        } else {
            PhotoWidgetImageView(image: activityImage(context, maximumPointSize: maximumPointSize, scale: displayScale))
        }
    }
}

private struct PhotoActivityControls: View {
    let context: ActivityViewContext<PairPhotoActivityAttributes>

    var body: some View {
        HStack(spacing: 5) {
            ForEach(PhotoReactionKind.allCases, id: \.rawValue) { kind in
                Button(intent: PhotoActivityReactionIntent(photoID: context.attributes.photoID,
                                                         assetID: context.attributes.assetID, kind: kind)) {
                    PhotoReactionLabel(kind: kind, selected: context.state.reactionKind == kind.rawValue, size: 34)
                }
                .buttonStyle(.plain).disabled(context.isStale)
                .accessibilityLabel(kind.title)
                .accessibilityValue(context.state.reactionKind == kind.rawValue ? "Reacción enviada" : "")
            }
            Link(destination: URL(string: "pairnotes://camera")!) {
                Image(systemName: "camera.fill").font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Sacar una foto para tu pareja")
        }
    }
}

private func activityImage(_ context: ActivityViewContext<PairPhotoActivityAttributes>,
                           maximumPointSize: CGFloat, scale: CGFloat) -> UIImage? {
    let attributes = context.attributes
    guard !context.isStale, let authorization = WidgetAccessStore.load(), authorization.isUsable(),
          authorization.uid == attributes.viewerID, authorization.pairID == attributes.pairID,
          authorization.pairEpoch == attributes.pairEpoch,
          context.state.expiresAt > Date(),
          context.state.imageFileName.count <= 100,
          context.state.imageFileName.hasSuffix(".png"),
          context.state.imageFileName.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
          let directory = SharedWidgetContainer.directory(),
          let data = try? Data(contentsOf: directory.appendingPathComponent(context.state.imageFileName)) else { return nil }
    // ActivityKit requires image assets no larger than their presentation. A
    // decoded bitmap has both bounded pixels and the actual display scale.
    let imageScale = max(1, scale)
    return PhotoWidgetImage.decode(data, maximumPixelSize: Int((maximumPointSize * imageScale).rounded(.up)), scale: imageScale)
}

private func photoURL(_ id: String) -> URL { URL(string: "pairnotes://photo/\(id)")! }

#Preview("Foto · mediano", as: .systemMedium) {
    PartnerPhotoWidget()
} timeline: {
    PartnerPhotoEntry.preview()
    PartnerPhotoEntry.preview(theme: .night, reaction: .heart)
    PartnerPhotoEntry.preview(message: "No se envió. Tocá la reacción para reintentar.")
}

#Preview("Foto · grande", as: .systemLarge) {
    PartnerPhotoWidget()
} timeline: {
    PartnerPhotoEntry.preview()
    PartnerPhotoEntry.preview(theme: .night, reaction: .tear)
}
