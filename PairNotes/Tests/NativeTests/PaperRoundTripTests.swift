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
        print("Paper fixture bounds: original=\(original.bounds), restored=\(restored.bounds)")
        print("Paper fixture contents: original=\(original.contentsRenderFrame), restored=\(restored.contentsRenderFrame)")
        let nativeAttachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.data")
        nativeAttachment.name = "mixed-note-native-source"
        nativeAttachment.lifetime = .keepAlways
        add(nativeAttachment)
        XCTAssertEqual(original.bounds, restored.bounds, "Native roundtrip must preserve canvas bounds")
        XCTAssertTrue(restored.featureSet.isSubset(of: PaperProbeDocument.supportedFeatures))
        let originalText = await original.indexableContent
        let restoredText = await restored.indexableContent
        XCTAssertTrue(originalText?.contains("Un recuerdo inventado") == true)
        XCTAssertTrue(restoredText?.contains("Un recuerdo inventado") == true)
        XCTAssertEqual(originalText, restoredText, "Native roundtrip must preserve editable text")
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
        let beforeRaster = try rgbaRaster(before)
        let afterRaster = try rgbaRaster(after)
        let textRegion = CGRect(x: 25, y: 25, width: 325, height: 45)
        assertRoundTripPixels(beforeRaster, afterRaster, textRegion: textRegion)
        XCTAssertGreaterThan(Set(beforeRaster.pixels).count, 8, "A blank render must not pass.")
        XCTAssertGreaterThan(Set(afterRaster.pixels).count, 8, "A blank restored render must not pass.")
        // Separate regions ensure all three fixture components survived. These
        // checks also expose an upside-down render rather than accepting it twice.
        assertInk(in: textRegion, raster: afterRaster, label: "text")
        assertInk(in: CGRect(x: 80, y: 110, width: 200, height: 140), raster: afterRaster, label: "image")
        assertInk(in: CGRect(x: 30, y: 300, width: 325, height: 35), raster: afterRaster, label: "stroke")

        // The first load may normalize text layout. It must not drift further
        // every time a person saves and reopens the same native document.
        let repeatedBytes = try await restored.dataRepresentation()
        XCTAssertFalse(repeatedBytes.isEmpty)
        let restoredAgain = try PaperMarkup(dataRepresentation: repeatedBytes)
        XCTAssertEqual(restored.bounds, restoredAgain.bounds)
        let repeatedData = try await PaperProbeDocument.render(restoredAgain, side: 384)
        attachPNG(repeatedData, name: "mixed-note-restored-again")
        let repeatedImage = try XCTUnwrap(UIImage(data: repeatedData)?.cgImage)
        let repeatedRaster = try rgbaRaster(repeatedImage)
        XCTAssertEqual(afterRaster.width, repeatedRaster.width)
        XCTAssertEqual(afterRaster.height, repeatedRaster.height)
        XCTAssertEqual(afterRaster.pixels, repeatedRaster.pixels,
                       "Native text layout must remain stable after the first roundtrip")
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

    private struct Raster {
        let width: Int
        let height: Int
        let pixels: Data

        func offset(x: Int, y: Int) -> Int { (y * width + x) * 4 }
    }

    private func rgbaRaster(_ image: CGImage) throws -> Raster {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        // Use the same explicit RGBA8 layout for every image. PNG decoders may
        // otherwise choose different channel order or padding for identical art.
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: colorSpace,
                                              bitmapInfo: bitmapInfo))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data)
        return Raster(width: image.width, height: image.height,
                      pixels: Data(bytes: bytes, count: image.width * image.height * 4))
    }

    private func pixelsEqual(_ before: Raster, at beforeOffset: Int,
                             _ after: Raster, at afterOffset: Int) -> Bool {
        (0..<4).allSatisfy { before.pixels[beforeOffset + $0] == after.pixels[afterOffset + $0] }
    }

    private func assertRoundTripPixels(_ before: Raster, _ after: Raster, textRegion: CGRect) {
        guard before.width == after.width, before.height == after.height else {
            XCTFail("Roundtrip changed the raster dimensions")
            return
        }
        let minX = Int(textRegion.minX)
        let maxX = Int(textRegion.maxX)
        let minY = Int(textRegion.minY)
        let maxY = Int(textRegion.maxY)
        guard minX >= 0, maxX <= before.width, minY >= 1, maxY < before.height else {
            XCTFail("Text comparison requires a one-pixel vertical margin")
            return
        }

        var differencesOutsideText = 0
        for y in 0..<before.height {
            for x in 0..<before.width {
                if (minX..<maxX).contains(x), (minY..<maxY).contains(y) { continue }
                let offset = before.offset(x: x, y: y)
                if !pixelsEqual(before, at: offset, after, at: offset) { differencesOutsideText += 1 }
            }
        }
        XCTAssertEqual(differencesOutsideText, 0,
                       "Images, strokes and background must survive the roundtrip pixel-exactly")

        // iOS 26.2 evidence: the first roundtrip moves all fixture text down by
        // exactly one output pixel; glyph pixels, photo and ink are unchanged.
        // Allow only a single uniform vertical shift, never per-pixel tolerance
        // or horizontal movement. Whitespace around the text prevents clipping.
        let matchingShift = (-1...1).first { dy in
            for y in minY..<maxY {
                for x in minX..<maxX {
                    guard pixelsEqual(before, at: before.offset(x: x, y: y),
                                      after, at: after.offset(x: x, y: y + dy)) else { return false }
                }
            }
            return true
        }
        XCTAssertNotNil(matchingShift,
                        "Text must preserve every RGBA pixel with at most one uniform vertical pixel of layout normalization")
    }

    private func assertInk(in region: CGRect, raster: Raster, label: String) {
        var coloredPixels = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let offset = raster.offset(x: x, y: y)
                if raster.pixels[offset] < 240 || raster.pixels[offset + 1] < 240 || raster.pixels[offset + 2] < 240 {
                    coloredPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(coloredPixels, 30, "Missing or misplaced fixture component: \(label)")
    }
}
