import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import PairNotes

final class WidgetNotePaperTests: XCTestCase {
    @MainActor
    func testWholeSheetKeepsFourCornersAndBackgroundInEveryWidgetShape() throws {
        // These are the remaining paper slots beneath the header, not fixed
        // WidgetKit dimensions. WidgetKit can propose other sizes on iPad/Mac.
        let slots: [(String, CGSize)] = [
            ("small", CGSize(width: 134, height: 112)),
            ("medium", CGSize(width: 314, height: 112)),
            ("large", CGSize(width: 314, height: 280))
        ]
        let sheets: [(String, CGSize)] = [
            ("square", CGSize(width: 400, height: 400)),
            ("portrait", CGSize(width: 400, height: 600)),
            ("landscape", CGSize(width: 600, height: 400))
        ]
        for (sheetName, sheetSize) in sheets {
            let paper = fixture(size: sheetSize)
            for (slotName, slotSize) in slots {
                for scheme in [ColorScheme.light, .dark] {
                    let name = "whole-paper-\(slotName)-\(sheetName)-\(scheme)"
                    let image = try render(paper, size: slotSize, scheme: scheme)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name; attachment.lifetime = .keepAlways
                    add(attachment)
                    let bitmap = try pixels(image)
                    let markers = markerPixels(in: bitmap)
                    for color in 0..<4 {
                        XCTAssertGreaterThan(markers[color].count, 8, "\(name): a corner was cropped")
                    }
                    let all = markers.flatMap { $0 }
                    let minX = try XCTUnwrap(all.map(\.x).min())
                    let maxX = try XCTUnwrap(all.map(\.x).max())
                    let minY = try XCTUnwrap(all.map(\.y).min())
                    let maxY = try XCTUnwrap(all.map(\.y).max())
                    let scale = min(slotSize.width / sheetSize.width, slotSize.height / sheetSize.height)
                    let expectedWidth = sheetSize.width * scale
                    let expectedHeight = sheetSize.height * scale
                    XCTAssertEqual(CGFloat(maxX - minX + 1), expectedWidth, accuracy: 2, name)
                    XCTAssertEqual(CGFloat(maxY - minY + 1), expectedHeight, accuracy: 2, name)
                    XCTAssertEqual(CGFloat(minX), (slotSize.width - expectedWidth) / 2, accuracy: 2, name)
                    XCTAssertEqual(CGFloat(minY), (slotSize.height - expectedHeight) / 2, accuracy: 2, name)
                    assertCreamCenter(bitmap, name: name)
                }
            }
        }
    }

    @MainActor
    func testAccentedModeKeepsOriginalPaperAndInkColors() throws {
        let image = try render(fixture(size: CGSize(width: 400, height: 600)),
                               size: CGSize(width: 314, height: 112), mode: .accented)
        let bitmap = try pixels(image)
        assertCreamCenter(bitmap, name: "accented")
        for marker in markerPixels(in: bitmap) {
            XCTAssertGreaterThan(marker.count, 8, "Parent foreground/accent must not turn the drawing into a template")
        }
        // ImageRenderer checks our SwiftUI treatment. WidgetKit still controls
        // the final tinted/vibrant compositor on the person's device.
    }

    @MainActor
    func testRedactionHidesArtworkAndItsAspectRatio() throws {
        for reason in [RedactionReasons.privacy, .placeholder] {
            let first = try render(fixture(size: CGSize(width: 400, height: 600)),
                                   size: CGSize(width: 134, height: 112), reasons: reason)
            let second = try render(fixture(size: CGSize(width: 600, height: 400), background: .magenta),
                                    size: CGSize(width: 134, height: 112), reasons: reason)
            XCTAssertEqual(try pixels(first).bytes, try pixels(second).bytes,
                           "Private sheets must produce the same generic placeholder")
        }
    }

    @MainActor
    private func render(_ paper: UIImage, size: CGSize, scheme: ColorScheme = .light,
                        mode: WidgetRenderingMode = .fullColor, reasons: RedactionReasons = []) throws -> UIImage {
        let content = WidgetNotePaper(image: paper, label: "Dibujo de prueba")
            .frame(width: size.width, height: size.height)
            .foregroundStyle(.white)
            .background(Color(red: 0.15, green: 0.15, blue: 0.15))
            .environment(\.widgetRenderingMode, mode)
            .environment(\.redactionReasons, reasons)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1; renderer.isOpaque = true
        return try XCTUnwrap(renderer.uiImage)
    }

    @MainActor
    private func fixture(size: CGSize, background: UIColor = UIColor(red: 1, green: 245 / 255, blue: 219 / 255, alpha: 1)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let side: CGFloat = 48
            let corners: [(UIColor, CGPoint)] = [
                (.red, .zero), (.green, CGPoint(x: size.width - side, y: 0)),
                (.blue, CGPoint(x: 0, y: size.height - side)),
                (.yellow, CGPoint(x: size.width - side, y: size.height - side))
            ]
            for (color, origin) in corners {
                color.setFill(); context.fill(CGRect(origin: origin, size: CGSize(width: side, height: side)))
            }
        }
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private func markerPixels(in bitmap: Bitmap) -> [[CGPoint]] {
        var result = [[CGPoint]](repeating: [], count: 4)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let i = (y * bitmap.width + x) * 4
                let r = bitmap.bytes[i], g = bitmap.bytes[i + 1], b = bitmap.bytes[i + 2]
                let marker: Int?
                if r > 220 && g < 30 && b < 30 { marker = 0 }
                else if r < 30 && g > 220 && b < 30 { marker = 1 }
                else if r < 30 && g < 30 && b > 220 { marker = 2 }
                else if r > 220 && g > 220 && b < 30 { marker = 3 }
                else { marker = nil }
                if let marker { result[marker].append(CGPoint(x: x, y: y)) }
            }
        }
        return result
    }

    private func assertCreamCenter(_ bitmap: Bitmap, name: String, file: StaticString = #filePath, line: UInt = #line) {
        let i = ((bitmap.height / 2) * bitmap.width + bitmap.width / 2) * 4
        XCTAssertEqual(Double(bitmap.bytes[i]), 255, accuracy: 3, name, file: file, line: line)
        XCTAssertEqual(Double(bitmap.bytes[i + 1]), 245, accuracy: 3, name, file: file, line: line)
        XCTAssertEqual(Double(bitmap.bytes[i + 2]), 219, accuracy: 3, name, file: file, line: line)
        XCTAssertEqual(bitmap.bytes[i + 3], 255, name, file: file, line: line)
    }

    private func pixels(_ image: UIImage) throws -> Bitmap {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        return Bitmap(width: cg.width, height: cg.height, bytes: bytes)
    }
}
