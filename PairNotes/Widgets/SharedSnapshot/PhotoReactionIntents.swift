import ActivityKit
import AppIntents
import Foundation
import PairNotesCore
import WidgetKit

struct PhotoWidgetReactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Reaccionar a la foto de tu pareja"
    static let description = IntentDescription("Enviá una reacción sin abrir PairNotes.")

    @Parameter(title: "Foto") var photoID: String
    @Parameter(title: "Imagen") var assetID: String
    @Parameter(title: "Reacción") var kind: String

    init() {}
    init(photoID: String, assetID: String, kind: PhotoReactionKind) {
        self.photoID = photoID; self.assetID = assetID; self.kind = kind.rawValue
    }

    func perform() async throws -> some IntentResult {
        do {
            guard let reaction = PhotoReactionKind(rawValue: kind) else { throw PhotoIntentError.invalidReaction }
            _ = try await WidgetRemoteClient.shared.reactToPhoto(photoID: photoID, assetID: assetID, kind: reaction)
        } catch {
            await WidgetRemoteClient.shared.recordPhotoInteractionFailure(photoID: photoID)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: SharedWidgetContainer.photoKind)
        return .result()
    }
}

/// LiveActivityIntent runs in the app process so ActivityKit can update the
/// selected reaction after the server has accepted it.
struct PhotoActivityReactionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Reaccionar a la foto en vivo"

    @Parameter(title: "Foto") var photoID: String
    @Parameter(title: "Imagen") var assetID: String
    @Parameter(title: "Reacción") var kind: String

    init() {}
    init(photoID: String, assetID: String, kind: PhotoReactionKind) {
        self.photoID = photoID; self.assetID = assetID; self.kind = kind.rawValue
    }

    func perform() async throws -> some IntentResult {
        var confirmed: PhotoReaction?
        var failureMessage: String?
        var authorizationRejected = false
        do {
            guard let reaction = PhotoReactionKind(rawValue: kind) else { throw PhotoIntentError.invalidReaction }
            confirmed = try await WidgetRemoteClient.shared.reactToPhoto(photoID: photoID, assetID: assetID, kind: reaction)
        } catch {
            if let error = error as? WidgetAccessError, case .invalidCredential = error {
                authorizationRejected = true
            }
            await WidgetRemoteClient.shared.recordPhotoInteractionFailure(photoID: photoID)
            failureMessage = "No se envió. Tocá la reacción para reintentar."
        }
        if authorizationRejected {
            // Revocation must also remove the image already archived by
            // ActivityKit, without clearing a newly renewed account credential.
            for activity in Activity<PairPhotoActivityAttributes>.activities where
                activity.attributes.photoID == photoID && activity.attributes.assetID == assetID {
                await dismissPhotoActivity(activity)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: SharedWidgetContainer.photoKind)
            return .result()
        }
        guard let authorization = WidgetAccessStore.load(), authorization.isUsable() else { return .result() }
        for activity in Activity<PairPhotoActivityAttributes>.activities where
            activity.attributes.photoID == photoID && activity.attributes.assetID == assetID &&
            activity.attributes.viewerID == authorization.uid && activity.attributes.pairID == authorization.pairID &&
            activity.attributes.pairEpoch == authorization.pairEpoch {
            var state = activity.content.state
            if let confirmed { state.reactionKind = confirmed.kind.rawValue }
            state.interactionMessage = failureMessage
            await activity.update(ActivityContent(state: state, staleDate: state.expiresAt))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: SharedWidgetContainer.photoKind)
        return .result()
    }
}

struct DismissPhotoActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cerrar la foto en vivo"
    @Parameter(title: "Actividad") var activityID: String

    init() {}
    init(activityID: String) { self.activityID = activityID }

    func perform() async throws -> some IntentResult {
        if let activity = Activity<PairPhotoActivityAttributes>.activities.first(where: { $0.id == activityID }) {
            await dismissPhotoActivity(activity)
        }
        return .result()
    }
}

private func dismissPhotoActivity(_ activity: Activity<PairPhotoActivityAttributes>) async {
    let imageFileName = activity.content.state.imageFileName
    await activity.end(nil, dismissalPolicy: .immediate)
    let prefix = "photo-activity-"
    if imageFileName.hasPrefix(prefix), imageFileName.hasSuffix(".png"),
       UUID(uuidString: String(imageFileName.dropFirst(prefix.count).dropLast(4))) != nil,
       let directory = SharedWidgetContainer.directory() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(imageFileName))
    }
}

private enum PhotoIntentError: Error { case invalidReaction }
