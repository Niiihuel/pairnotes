import ActivityKit
import Foundation
import PairNotesCore
import UIKit

/// Live Activities are temporary. Widgets continue to show the latest photo
/// after the activity expires, without starting it again behind the user's back.
@MainActor
final class PairPhotoActivityController {
    static let shared = PairPhotoActivityController()
    private var generation: UInt64 = 0
    private var working = false

    enum Failure: LocalizedError {
        case disabled, unavailable, changed
        var errorDescription: String? {
            switch self {
            case .disabled: return "Activá Actividades en vivo para PairNotes en Configuración."
            case .unavailable: return "No se pudo mostrar la tarjeta. Reintentá desde esta foto."
            case .changed: return "Llegó una foto nueva. Abrila desde Inicio para mostrarla en pantalla bloqueada."
            }
        }
    }

    func show(photo: CouplePhoto, services: AppServices) async throws {
        removeOrphanImages()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Failure.disabled }
        guard !working, let uid = services.identity?.uid, let pair = services.membership,
              photo.recipientId == uid, let directory = SharedWidgetContainer.directory() else { throw Failure.unavailable }
        working = true
        let captured = generation
        defer { working = false }
        let result = await WidgetRemoteClient.shared.refresh()
        guard services.identity?.uid == uid, services.membership?.id == pair.id,
              services.membership?.pairEpoch == pair.pairEpoch, captured == generation else { throw ServiceError.sessionChanged }
        guard !result.needsAuthorization, let validUntil = result.expiresAt, validUntil > Date(),
              let latest = result.couple?.latestPhoto else { throw Failure.unavailable }
        guard latest.id == photo.id, latest.photo.id == photo.photo.id else { throw Failure.changed }
        let bytes = try await services.photoImage(photo)
        guard captured == generation, services.identity?.uid == uid,
              services.membership?.id == pair.id, services.membership?.pairEpoch == pair.pairEpoch,
              let image = UIImage(data: bytes), let png = image.pngData() else { throw ServiceError.sessionChanged }
        let expires = min(Date().addingTimeInterval(8 * 60 * 60), validUntil)
        let file = "photo-activity-\(UUID().uuidString.lowercased()).png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        for activity in Activity<PairPhotoActivityAttributes>.activities { await finish(activity) }
        guard captured == generation else {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)); throw ServiceError.sessionChanged
        }
        let state = PairPhotoActivityAttributes.ContentState(
            authorName: services.partnerNickname, caption: photo.caption, sentAt: photo.sentAt,
            reactionKind: result.couple?.latestPhoto?.reaction?.kind.rawValue, imageFileName: file, expiresAt: expires)
        let attributes = PairPhotoActivityAttributes(pairID: pair.id, pairEpoch: pair.pairEpoch,
            viewerID: uid, photoID: photo.id, assetID: photo.photo.id)
        do {
            _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: expires), pushType: nil)
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)); throw Failure.unavailable
        }
    }

    func synchronize(services: AppServices) async {
        removeOrphanImages()
        let activities = Activity<PairPhotoActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let captured = generation
        let result = await WidgetRemoteClient.shared.refresh()
        guard captured == generation else { return }
        for activity in activities {
            let attributes = activity.attributes
            guard attributes.viewerID == services.identity?.uid, attributes.pairID == services.membership?.id,
                  attributes.pairEpoch == services.membership?.pairEpoch, !result.needsAuthorization,
                  let expiry = result.expiresAt, expiry > Date(),
                  let photo = result.couple?.latestPhoto, photo.id == attributes.photoID,
                  photo.photo.id == attributes.assetID,
                  activity.content.state.expiresAt > Date() else {
                await finish(activity); continue
            }
            var state = activity.content.state
            state.reactionKind = photo.reaction?.kind.rawValue
            state.interactionMessage = result.photoInteractionMessage
            state.caption = photo.caption; state.authorName = services.partnerNickname
            state.expiresAt = min(state.expiresAt, expiry)
            if state != activity.content.state {
                await activity.update(ActivityContent(state: state, staleDate: state.expiresAt))
            }
        }
    }

    /// Called synchronously when the account/pair changes, before any await.
    func invalidate() {
        generation &+= 1
        let activities = Activity<PairPhotoActivityAttributes>.activities
        Task { for activity in activities { await finish(activity) }; removeOrphanImages() }
    }

    private func finish(_ activity: Activity<PairPhotoActivityAttributes>) async {
        await activity.end(nil, dismissalPolicy: .immediate)
        let file = activity.content.state.imageFileName
        if file.hasPrefix("photo-activity-"), file.hasSuffix(".png"), !file.contains("/"),
           let directory = SharedWidgetContainer.directory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// A swipe or the system's duration limit can dismiss an activity without
    /// executing our Close intent. Retain only files used by current activities.
    private func removeOrphanImages() {
        guard !working, let directory = SharedWidgetContainer.directory(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let retained = Set(Activity<PairPhotoActivityAttributes>.activities.map { $0.content.state.imageFileName })
        let prefix = "photo-activity-"
        for file in files {
            let name = file.lastPathComponent
            guard !retained.contains(name), name.hasPrefix(prefix), name.hasSuffix(".png"),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
