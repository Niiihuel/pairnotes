import PairNotesCore
import SwiftUI
import WidgetKit

// Read privacy redaction inside the privacySensitive content boundary so the
// spacing and connector cannot disclose a hidden distance on the Lock Screen.
struct WidgetDistanceContent: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.redactionReasons) private var redactionReasons
    let date: Date
    let avatars: [String: Data]
    let snapshot: CoupleWidgetSnapshot
    private var theme: CoupleTheme { snapshot.personalization?.theme ?? .rose }
    private var accessory: Bool { family == .accessoryRectangular || family == .accessoryCircular }

    var body: some View {
        let hidden = redactionReasons.contains(.privacy)
        let presentation = CoupleDistancePresentation(
            distance: hidden ? CoupleDistance(status: .waiting) : snapshot.distance, at: date)
        let size: CGFloat = accessory ? 28 : family == .systemSmall ? 36 : 48
        return VStack(spacing: accessory ? 2 : 8) {
            Text(presentation.title).font(accessory ? .caption.bold() : .title3.bold())
                .minimumScaleFactor(0.85).lineLimit(1)
            GeometryReader { geometry in
                let layout = CoupleDistanceAvatarLayout(width: geometry.size.width,
                    preferredAvatarSize: size, separation: presentation.separation, compact: accessory)
                let symbolSize: CGFloat = accessory ? 12 : 18
                HStack(spacing: 0) {
                    if layout.avatarDiameter > 0, let first = snapshot.profiles.first {
                        avatar(first, size: layout.avatarDiameter)
                    }
                    ZStack {
                        if presentation.hasDistance {
                            DistanceConnectionLine(symbolWidth: symbolSize)
                                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round,
                                                          dash: presentation.fresh ? [] : [2, 3]))
                                .foregroundStyle(.secondary)
                        }
                        if layout.connectorWidth >= symbolSize {
                            Image(systemName: presentation.symbol).font(.system(size: symbolSize))
                                .foregroundStyle(accessory || renderingMode != .fullColor ? Color.primary : theme.accent)
                                .widgetAccentable()
                        }
                    }
                    .frame(width: layout.connectorWidth, height: layout.avatarDiameter)
                    .accessibilityHidden(true)
                    if layout.avatarDiameter > 0, let last = snapshot.profiles.last, snapshot.profiles.count > 1 {
                        avatar(last, size: layout.avatarDiameter)
                    }
                }
                .frame(width: layout.width, height: size)
            }.frame(height: size)
            Group {
                if let updated = presentation.updatedAt {
                    Text(presentation.fresh ? "Hace " : "Anterior · hace ") + Text(updated, style: .relative)
                } else {
                    Text(presentation.detail)
                }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(distanceAccessibilityLabel(presentation, snapshot: snapshot, hidden: hidden))
    }

    private func distanceAccessibilityLabel(_ presentation: CoupleDistancePresentation,
                                            snapshot: CoupleWidgetSnapshot, hidden: Bool) -> Text {
        if hidden { return Text("Distancia privada") }
        let names = snapshot.profiles.map(\.displayName).joined(separator: " y ")
        let label = Text("\(names). \(presentation.title). \(presentation.detail).")
        if let updated = presentation.updatedAt {
            return label + Text(" Medida el ") + Text(updated, format: .dateTime.day().month().hour().minute())
        }
        return label
    }

    private func avatar(_ profile: CoupleProfile, size: CGFloat) -> some View {
        WidgetProfileAvatar(data: avatars[profile.uid], name: profile.displayName,
                            initials: profile.initials, theme: theme, size: size)
    }
}

private struct DistanceConnectionLine: Shape {
    let symbolWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let half = min(rect.width / 2, symbolWidth / 2 + 3)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: max(0, rect.midX - half), y: rect.midY))
        path.move(to: CGPoint(x: min(rect.width, rect.midX + half), y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

