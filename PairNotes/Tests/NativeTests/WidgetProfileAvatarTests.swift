import PairNotesCore
import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import PairNotes

final class WidgetProfileAvatarTests: XCTestCase {
    @MainActor
    func testPortraitKeepsColorsUnderWhiteForegroundInNormalAndAccentedLayouts() throws {
        let data = try portrait()
        for mode in [WidgetRenderingMode.fullColor, .accented] {
            let image = try render(data: data, mode: mode)
            let left = try pixel(image, x: 16, y: 32)
            let right = try pixel(image, x: 48, y: 32)
            XCTAssertGreaterThan(Int(left[0]) - Int(left[2]), 128, "The red half must not become a white template")
            XCTAssertGreaterThan(Int(right[2]) - Int(right[0]), 128, "The blue half must remain distinguishable")
            XCTAssertEqual(left[3], 255)
            XCTAssertEqual(right[3], 255)
        }
        // This checks our SwiftUI rendering, not WidgetKit's final Lock Screen
        // compositor. A device/WidgetKit preview verifies wallpaper vibrancy.
    }

    @MainActor
    func testOriginalImagePreservesTransparentCutoutsAndRejectsCorruptData() throws {
        let data = try portrait(transparent: true)
        let image = try XCTUnwrap(WidgetProfileAvatar.image(from: data))
        XCTAssertEqual(image.renderingMode, .alwaysOriginal)
        XCTAssertEqual(try pixel(image, x: 16, y: 4)[3], 0, "Don't add an opaque matte to legitimate transparent PNGs")
        XCTAssertEqual(try pixel(image, x: 16, y: 32)[3], 255)
        XCTAssertNil(WidgetProfileAvatar.image(from: nil))
        XCTAssertNil(WidgetProfileAvatar.image(from: Data("invalid image".utf8)))
    }

    @MainActor
    func testMonochromeFallbackHasOpaqueInkWithoutAWhiteDisk() throws {
        for mode in [WidgetRenderingMode.accented, .vibrant] {
            let image = try render(data: nil, mode: mode)
            let rgba = try pixels(image)
            let visible = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count
            let opaque = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] == 255 }.count
            XCTAssertGreaterThan(opaque, 100, "Initials and ring should not be washed out with low opacity")
            XCTAssertLessThan(visible, 1_500, "A filled template disk would hide the initials in monochrome mode")
        }
    }

    @MainActor
    func testPrivacyPlaceholderDoesNotRenderPrivatePhotoOrInitials() throws {
        let privatePortrait = try render(data: portrait(), mode: .vibrant, initials: "AA", reasons: .privacy)
        let otherIdentity = try render(data: nil, mode: .vibrant, initials: "ZZ", reasons: .privacy)
        XCTAssertEqual(try pixels(privatePortrait), try pixels(otherIdentity), "Only a generic person symbol is visible while redacted")
    }

    @MainActor
    private func render(data: Data?, mode: WidgetRenderingMode, initials: String = "A",
                        reasons: RedactionReasons = []) throws -> UIImage {
        let content = WidgetProfileAvatar(data: data, name: "Perfil ficticio", initials: initials, theme: .rose, size: 64)
            .foregroundStyle(.white)
            .environment(\.widgetRenderingMode, mode)
            .environment(\.redactionReasons, reasons)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = false
        return try XCTUnwrap(renderer.uiImage)
    }

    @MainActor
    private func portrait(transparent: Bool = false) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { _ in
            let y: CGFloat = transparent ? 16 : 0
            let height: CGFloat = transparent ? 32 : 64
            UIColor.red.setFill(); UIBezierPath(rect: CGRect(x: 0, y: y, width: 32, height: height)).fill()
            UIColor.blue.setFill(); UIBezierPath(rect: CGRect(x: 32, y: y, width: 32, height: height)).fill()
        }
        return try XCTUnwrap(image.pngData())
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let rgba = try pixels(image)
        let index = (y * cgImage.width + x) * 4
        return Array(rgba[index..<(index + 4)])
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }
}
