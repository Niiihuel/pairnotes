import UIKit
import PaperKit
import PencilKit

// M0 experiment. This is not the production editor or an autosave engine.
@MainActor
enum PaperProbeDocument {
    static let bounds = CGRect(x: 0, y: 0, width: 1536, height: 1536)
    static var supportedFeatures: FeatureSet {
        var features = FeatureSet.version1
        features.colorMaximumLinearExposure = 1
        return features
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

    static func render(_ markup: PaperMarkup, side: Int) async throws -> Data {
        guard (1...2048).contains(side),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProbeError.renderFailed
        }
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(frame)
        let canvas = markup.bounds
        guard canvas.width > 0, canvas.height > 0 else { throw ProbeError.renderFailed }
        // Paper coordinates use a top-left origin. Render in model coordinates
        // with an explicit scale; the output bitmap is only the destination.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: CGFloat(side) / canvas.width, y: -CGFloat(side) / canvas.height)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        // Dedicated context survives suspension; no UIKit drawing closure spans await.
        await markup.draw(in: context, frame: canvas)
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
