import UIKit
import PaperKit
import PencilKit

/// Opaque sRGB paper color, independent of the phone's appearance and included
/// in the source digest. A sheet can never become transparent when exported.
struct PaperBackground: Codable, Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let white = PaperBackground(red: 255, green: 255, blue: 255)
    static let cream = PaperBackground(red: 255, green: 245, blue: 219)
    static let rose = PaperBackground(red: 255, green: 225, blue: 232)
    static let sky = PaperBackground(red: 220, green: 239, blue: 255)
    static let mint = PaperBackground(red: 224, green: 246, blue: 231)
    static let charcoal = PaperBackground(red: 38, green: 40, blue: 46)

    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }

    var contrastingInkColor: UIColor {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > 0.179 ? .black : .white
    }

    @MainActor
    init(color: UIColor) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Self.channel(red), green: Self.channel(green), blue: Self.channel(blue))
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    private static func channel(_ value: CGFloat) -> UInt8 {
        guard value.isFinite else { return 255 }
        return UInt8((min(1, max(0, value)) * 255).rounded())
    }
}

@MainActor
enum PaperProbeDocument {
    static let editorVersion = 2
    static let bounds = CGRect(x: 0, y: 0, width: 1536, height: 1536)
    static var supportedFeatures: FeatureSet {
        var features = FeatureSet.version1
        features.colorMaximumLinearExposure = 1
        return features
    }

    private struct SourceEnvelope: Codable {
        let format: String
        let version: Int
        let background: PaperBackground
        let nativeData: Data
    }

    static func encode(_ markup: PaperMarkup, background: PaperBackground) async throws -> Data {
        let nativeData = try await markup.dataRepresentation()
        let envelope = SourceEnvelope(format: "pairnotes.paper", version: 1,
                                      background: background, nativeData: nativeData)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    static func decode(_ source: Data, editorVersion: Int) throws -> (markup: PaperMarkup, background: PaperBackground) {
        switch editorVersion {
        case 1:
            // TestFlight 1.0 (3.1) stored raw PaperKit bytes and exported on white.
            return (try PaperMarkup(dataRepresentation: source), .white)
        case Self.editorVersion:
            let envelope = try PropertyListDecoder().decode(SourceEnvelope.self, from: source)
            guard envelope.format == "pairnotes.paper", envelope.version == 1,
                  !envelope.nativeData.isEmpty else { throw ProbeError.incompatibleDocument }
            return (try PaperMarkup(dataRepresentation: envelope.nativeData), envelope.background)
        default:
            throw ProbeError.incompatibleDocument
        }
    }

    static func fixture() -> PaperMarkup {
        var markup = PaperMarkup(bounds: bounds)
        markup.insertNewTextbox(
            attributedText: NSAttributedString(string: "Un recuerdo inventado", attributes: [
                .font: UIFont.systemFont(ofSize: 80), .foregroundColor: UIColor.black
            ]), frame: CGRect(x: 100, y: 100, width: 1300, height: 180))

        // Synthetic image, drawn locally: no personal photo, EXIF or permissions.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let illustration = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.systemYellow.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 260, y: 30, width: 90, height: 90))
            UIColor.white.setFill()
            context.fill(CGRect(x: 20, y: 240, width: 360, height: 20))
        }
        if let image = illustration.cgImage {
            markup.insertNewImage(image, frame: CGRect(x: 300, y: 400, width: 900, height: 675))
        }
        let points: [PKStrokePoint] = (0...20).map { index -> PKStrokePoint in
            let x = CGFloat(150 + index * 60)
            let y = CGFloat(1250 + (index % 3) * 30)
            let location = CGPoint(x: x, y: y)
            let size = CGSize(width: 18, height: 18)
            return PKStrokePoint(location: location, timeOffset: Double(index) * 0.02,
                                 size: size, opacity: 1, force: 1, azimuth: 0,
                                 altitude: CGFloat.pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemPink), path: path)
        markup.append(contentsOf: PKDrawing(strokes: [stroke]))
        return markup
    }

    static func render(_ markup: PaperMarkup, side: Int, background: PaperBackground = .white) async throws -> Data {
        guard (1...2048).contains(side),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProbeError.renderFailed
        }
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(background.uiColor.cgColor)
        context.fill(frame)
        let canvas = markup.bounds
        guard canvas.width > 0, canvas.height > 0 else { throw ProbeError.renderFailed }
        // Paper coordinates use a top-left origin. Render in model coordinates
        // with an explicit scale; the output bitmap is only the destination.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: CGFloat(side) / canvas.width, y: -CGFloat(side) / canvas.height)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        // Dedicated context survives suspension; no UIKit drawing closure spans await.
        await markup.draw(in: context, frame: canvas,
                          options: RenderingOptions(darkUserInterfaceStyle: false, layoutRightToLeft: false))
        guard let image = context.makeImage(), let png = UIImage(cgImage: image).pngData() else {
            throw ProbeError.renderFailed
        }
        return png
    }
}

enum ProbeError: Error {
    case renderFailed
    case missingMarkup
    case incompatibleDocument
}
