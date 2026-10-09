import PairNotesCore
import SwiftUI
import UIKit
import WidgetKit

/// Keep portraits out of accentable containers: an accentable ancestor can
/// override the image's full-color treatment and turn opaque photos white.
struct WidgetProfileAvatar: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.colorScheme) private var colorScheme
    let data: Data?
    let name: String
    let initials: String
    let theme: CoupleTheme
    let size: CGFloat

    private var hidesIdentity: Bool {
        redactionReasons.contains(.privacy) || redactionReasons.contains(.placeholder)
    }
    private var fullColor: Bool { renderingMode == .fullColor }
    // In vibrant mode these are input luminance values for the system's
    // adaptive material, not a request to force a fixed Lock Screen color.
    private var monochromeInk: Color { renderingMode == .vibrant ? .white : .primary }
    private var placeholderInk: Color {
        if !fullColor { return monochromeInk }
        return colorScheme == .dark || theme == .night ? Color(rgb: 0x382D35) : .white
    }

    var body: some View {
        Group {
            if hidesIdentity {
                // Only the generic symbol is unredacted. Photos, initials and
                // names continue to respect the person's Lock Screen settings.
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(monochromeInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .unredacted()
            } else if let image = Self.image(from: data) {
                portrait(image)
            } else {
                ZStack {
                    if fullColor { Circle().fill(theme.accent) }
                    Text(initials.isEmpty ? "♡" : initials)
                        .font(.system(size: max(11, size * 0.35), weight: .semibold))
                        .foregroundStyle(placeholderInk)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(fullColor ? theme.ink.opacity(0.45) : monochromeInk,
                                  lineWidth: fullColor ? 1 : 1.5)
        }
        .widgetAccentable(false)
        .accessibilityLabel(hidesIdentity ? "Perfil privado" : name)
    }

    @ViewBuilder
    private func portrait(_ image: UIImage) -> some View {
        let portrait = Image(uiImage: image)
            .renderingMode(.original)
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFill()
        if renderingMode == .vibrant {
            // Dark pixels become weak material on the Lock Screen. Preserve
            // the portrait's tonal detail while lifting its darkest tones.
            // Keep alpha intact: luminanceToAlpha would make dark hair and
            // facial features transparent instead. No opaque matte is added.
            portrait.saturation(0).contrast(0.85).brightness(0.075)
        } else {
            portrait
        }
    }

    static func image(from data: Data?) -> UIImage? {
        guard let data, !data.isEmpty, data.count <= 512 * 1_024 else { return nil }
        // Preserve source colors and alpha, including legitimate PNG cutouts.
        return UIImage(data: data)?.withRenderingMode(.alwaysOriginal)
    }
}
