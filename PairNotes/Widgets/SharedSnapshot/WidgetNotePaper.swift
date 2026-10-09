import SwiftUI
import UIKit
import WidgetKit

/// The image includes the entire sheet, including its saved background. Its
/// intrinsic size must not expand a widget's remaining space beneath the header.
struct WidgetNotePaper: View {
    @Environment(\.redactionReasons) private var redactionReasons
    let image: UIImage
    let label: String

    private var hidesArtwork: Bool {
        redactionReasons.contains(.privacy) || redactionReasons.contains(.placeholder)
    }

    var body: some View {
        GeometryReader { geometry in
            if hidesArtwork {
                Image(systemName: "doc.text")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                let paper = Self.fittedFrame(imageSize: image.size, availableSize: geometry.size)
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFit()
                    .frame(width: paper.width, height: paper.height)
                    .position(x: paper.midX, y: paper.midY)
            }
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hidesArtwork ? "Dibujo privado" : label)
    }

    static func fittedFrame(imageSize: CGSize, availableSize: CGSize) -> CGRect {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              availableSize.width.isFinite, availableSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              availableSize.width > 0, availableSize.height > 0 else { return .zero }
        let scale = min(availableSize.width / imageSize.width, availableSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (availableSize.width - size.width) / 2,
                      y: (availableSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
