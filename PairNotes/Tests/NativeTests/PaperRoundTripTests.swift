import XCTest
import PaperKit
import UIKit
@testable import PairNotes

final class PaperRoundTripTests: XCTestCase {
    @MainActor
    func testMixedCompositionSurvivesNativeRoundTrip() async throws {
        let original = PaperProbeDocument.fixture()
        let bytes = try await original.dataRepresentation()
        XCTAssertFalse(bytes.isEmpty)
        let restored = try PaperMarkup(dataRepresentation: bytes)
        XCTAssertTrue(restored.featureSet.isSubset(of: PaperProbeDocument.supportedFeatures))
        let beforeData = try await PaperProbeDocument.render(original, side: 384)
        let afterData = try await PaperProbeDocument.render(restored, side: 384)
        // Keep the actual images in xcresult so they can be inspected from Linux.
        attachPNG(beforeData, name: "mixed-note-before")
        attachPNG(afterData, name: "mixed-note-restored")
        let before = try XCTUnwrap(UIImage(data: beforeData)?.cgImage)
        let after = try XCTUnwrap(UIImage(data: afterData)?.cgImage)
        XCTAssertEqual(before.width, 384)
        XCTAssertEqual(before.height, 384)
        XCTAssertEqual(after.width, before.width)
        XCTAssertEqual(after.height, before.height)
        // Same renderer and device: compare raster bytes, not PNG compression metadata.
        let beforePixels = try XCTUnwrap(before.dataProvider?.data) as Data
        let afterPixels = try XCTUnwrap(after.dataProvider?.data) as Data
        XCTAssertEqual(beforePixels, afterPixels)
        XCTAssertGreaterThan(Set(beforePixels).count, 8, "A blank render must not pass.")
        // Separate regions ensure all three fixture components survived. These
        // checks also expose an upside-down render rather than accepting it twice.
        try assertInk(in: CGRect(x: 25, y: 25, width: 325, height: 45), image: after, label: "text")
        try assertInk(in: CGRect(x: 80, y: 110, width: 200, height: 140), image: after, label: "image")
        try assertInk(in: CGRect(x: 30, y: 300, width: 325, height: 35), image: after, label: "stroke")
    }

    private func attachPNG(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCorruptNativeBytesAreRejected() {
        XCTAssertThrowsError(try PaperMarkup(dataRepresentation: Data("not-paperkit".utf8)))
    }

    private func assertInk(in region: CGRect, image: CGImage, label: String) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var coloredPixels = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let offset = y * context.bytesPerRow + x * 4
                if pixels[offset] < 240 || pixels[offset + 1] < 240 || pixels[offset + 2] < 240 {
                    coloredPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(coloredPixels, 30, "Missing or misplaced fixture component: \(label)")
    }
}
