import PairNotesCore
import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import PairNotes

final class WidgetDistanceLayoutTests: XCTestCase {
    @MainActor
    func testRenderedAvatarsMoveCloserWithDistanceAndKeepTheirPhotosWhenOld() throws {
        let slots: [(String, WidgetFamily, CGSize, ColorScheme)] = [
            ("small", .systemSmall, CGSize(width: 134, height: 134), .light),
            ("medium", .systemMedium, CGSize(width: 314, height: 112), .dark),
            ("lock", .accessoryRectangular, CGSize(width: 146, height: 60), .dark)
        ]
        for (name, family, size, scheme) in slots {
            let nearImage = try render(meters: 30, family: family, size: size, scheme: scheme)
            let farImage = try render(meters: 5_000_000, family: family, size: size, scheme: scheme)
            let oldImage = try render(meters: 5_000_000, age: 3 * 86_400,
                                      family: family, size: size, scheme: scheme)
            for (state, image) in [("near", nearImage), ("far", farImage), ("previous", oldImage)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "distance-\(name)-\(scheme)-\(state)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let near = try portraits(try pixels(nearImage))
            let farBitmap = try pixels(farImage)
            let far = try portraits(farBitmap)
            let oldBitmap = try pixels(oldImage)
            let old = try portraits(oldBitmap)
            XCTAssertGreaterThan(near.left.midX, far.left.midX + 5, name)
            XCTAssertLessThan(near.right.midX, far.right.midX - 5, name)
            XCTAssertEqual(near.left.width, far.left.width, accuracy: 1, name)
            XCTAssertEqual(near.right.width, far.right.width, accuracy: 1, name)
            // Footer text can change the centered stack's height. Proximity is
            // encoded horizontally; age must preserve that spacing and photo detail.
            for (previous, current) in [(old.left, far.left), (old.right, far.right)] {
                XCTAssertEqual(previous.minX, current.minX, "Age must preserve horizontal position (\(name))")
                XCTAssertEqual(previous.width, current.width, "Age must preserve portrait width (\(name))")
                XCTAssertEqual(previous.height, current.height, "Age must preserve portrait height (\(name))")
                let oldCenter = (Int(previous.midY) * oldBitmap.width + Int(previous.midX)) * 4
                let farCenter = (Int(current.midY) * farBitmap.width + Int(current.midX)) * 4
                XCTAssertEqual(Array(oldBitmap.bytes[oldCenter..<(oldCenter + 4)]),
                               Array(farBitmap.bytes[farCenter..<(farCenter + 4)]),
                               "Age must preserve photo color and opacity (\(name))")
            }
            for rect in [near.left, near.right, far.left, far.right, old.left, old.right] {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect), name)
            }
            XCTAssertGreaterThan(connectionPixels(farBitmap, between: far, scheme: scheme), 10,
                                 "The distance must have a visible line between the portraits (\(name))")
        }
        // ImageRenderer validates layout and our original-color treatment.
        // WidgetKit applies the final monochrome Lock Screen compositor.
    }

    @MainActor
    func testPrivacyHidesBothDistanceGeometryAndProfileIdentity() throws {
        let size = CGSize(width: 146, height: 60)
        let near = try render(meters: 30, family: .accessoryRectangular, size: size, reasons: .privacy)
        let far = try render(meters: 5_000_000, family: .accessoryRectangular, size: size,
                             reasons: .privacy, swapProfiles: true)
        XCTAssertEqual(try pixels(near).bytes, try pixels(far).bytes,
                       "Private distance widgets must not reveal proximity, avatars or names")
    }

    @MainActor
    private func render(meters: Double, age: TimeInterval = 0, family: WidgetFamily, size: CGSize,
                        scheme: ColorScheme = .light, reasons: RedactionReasons = [],
                        swapProfiles: Bool = false) throws -> UIImage {
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let profiles = [CoupleProfile(uid: "first", displayName: swapProfiles ? "Nombre secreto" : "Perfil A"),
                        CoupleProfile(uid: "second", displayName: swapProfiles ? "Otro nombre" : "Perfil B")]
        let snapshot = CoupleWidgetSnapshot(profiles: profiles, startedOn: nil, latestMessage: nil,
            distance: CoupleDistance(status: .available, meters: meters,
                                     updatedAt: date.addingTimeInterval(-age), accuracyMeters: 20))
        let avatars = ["first": try avatar(swapProfiles ? .blue : .red),
                       "second": try avatar(swapProfiles ? .red : .blue)]
        let view = WidgetDistanceContent(family: family, date: date, avatars: avatars, snapshot: snapshot)
            .privacySensitive()
            .frame(width: size.width, height: size.height)
            .foregroundStyle(Color.primary)
            .background(scheme == .light ? Color.white : Color.black)
            .environment(\.widgetRenderingMode, .fullColor)
            .environment(\.redactionReasons, reasons)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1; renderer.isOpaque = true
        return try XCTUnwrap(renderer.uiImage)
    }

    @MainActor
    private func avatar(_ color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try XCTUnwrap(image.pngData())
    }

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private func portraits(_ bitmap: Bitmap) throws -> (left: CGRect, right: CGRect) {
        var red: [CGPoint] = [], blue: [CGPoint] = []
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let i = (y * bitmap.width + x) * 4
                let r = bitmap.bytes[i], g = bitmap.bytes[i + 1], b = bitmap.bytes[i + 2]
                if r > 220 && g < 30 && b < 30 { red.append(CGPoint(x: x, y: y)) }
                if b > 220 && r < 30 && g < 30 { blue.append(CGPoint(x: x, y: y)) }
            }
        }
        func bounds(_ points: [CGPoint]) throws -> CGRect {
            XCTAssertGreaterThan(points.count, 100, "A portrait must remain visible in its original color")
            let minX = try XCTUnwrap(points.map(\.x).min()), maxX = try XCTUnwrap(points.map(\.x).max())
            let minY = try XCTUnwrap(points.map(\.y).min()), maxY = try XCTUnwrap(points.map(\.y).max())
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        return (try bounds(red), try bounds(blue))
    }

    private func connectionPixels(_ bitmap: Bitmap, between portraits: (left: CGRect, right: CGRect),
                                  scheme: ColorScheme) -> Int {
        let middle = (portraits.left.maxX + portraits.right.minX) / 2
        let background = scheme == .light ? 255 : 0
        var count = 0
        for y in max(0, Int(portraits.left.midY) - 1)...min(bitmap.height - 1, Int(portraits.left.midY) + 1) {
            for x in Int(portraits.left.maxX + 2)..<Int(portraits.right.minX - 2) where abs(CGFloat(x) - middle) > 15 {
                let i = (y * bitmap.width + x) * 4
                let r = Int(bitmap.bytes[i]), g = Int(bitmap.bytes[i + 1]), b = Int(bitmap.bytes[i + 2])
                if abs(r - g) < 8 && abs(g - b) < 8 && abs(r - background) > 30 { count += 1 }
            }
        }
        return count
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
