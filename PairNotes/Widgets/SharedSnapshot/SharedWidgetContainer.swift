import Foundation

/// Compiled by the app and the widget. An App Group must be registered and
/// configured on both targets before the system can provide its container.
enum SharedWidgetContainer {
    static let widgetKind = "PairNotes.LocalNote"
    static let messageKind = "PairNotes.ReceivedMessage"
    static let togetherKind = "PairNotes.Together"
    static let anniversaryKind = "PairNotes.Anniversary"
    static let gestureKind = "PairNotes.ThinkingOfYou"
    static let distanceKind = "PairNotes.Distance"
    static let allWidgetKinds: Set<String> = [widgetKind, messageKind, togetherKind, anniversaryKind, distanceKind, gestureKind]

    static func directory(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> URL? {
        guard let value = bundle.object(forInfoDictionaryKey: "PAIRNOTES_APP_GROUP") as? String else {
            return nil
        }

        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.hasPrefix("group."),
              !identifier.contains("$("),
              let container = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: identifier
              ) else {
            return nil
        }

        return container
            .appendingPathComponent("PairNotes", isDirectory: true)
            .appendingPathComponent("WidgetSnapshot", isDirectory: true)
    }
}
