import SwiftUI
import UIKit

enum ReactionBubbleTail: Equatable {
    case none, topLeading, bottomLeading
}

enum ReactionBubbleSurface {
    case material
    case solid(Color)
}

/// Contains controls supplied by the caller, including Button(intent:) in a
/// widget. It owns presentation only; selection remains server-confirmed.
struct ReactionBubble<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.layoutDirection) private var layoutDirection
    let tail: ReactionBubbleTail
    let surface: ReactionBubbleSurface
    private let content: Content

    init(tail: ReactionBubbleTail = .none, surface: ReactionBubbleSurface = .material,
         @ViewBuilder content: () -> Content) {
        self.tail = tail; self.surface = surface; self.content = content()
    }

    var body: some View {
        let shape = ReactionBubbleShape(tail: tail, mirrored: layoutDirection == .rightToLeft)
        content
            .padding(.horizontal, 6).padding(.vertical, 5)
            .padding(.top, tail == .topLeading ? 7 : 0)
            .padding(.bottom, tail == .bottomLeading ? 7 : 0)
            .background {
                switch surface {
                case .solid(let color): shape.fill(color)
                case .material:
                    if reduceTransparency { shape.fill(Color(uiColor: .secondarySystemBackground)) }
                    else { shape.fill(.regularMaterial) }
                }
            }
            .overlay { shape.stroke(.primary.opacity(0.12), lineWidth: 0.75).allowsHitTesting(false) }
            .accessibilityElement(children: .contain)
    }
}

/// A closed outline keeps the border continuous around the optional tail.
struct ReactionBubbleShape: Shape {
    var tail: ReactionBubbleTail = .none
    var mirrored = false

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let tailHeight: CGFloat = tail == .none ? 0 : min(7, rect.height / 4)
        let top = rect.minY + tailHeight
        let bottom = rect.maxY
        let radius = min(24, rect.width / 2, (bottom - top) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        if tailHeight > 0, rect.width >= 68 {
            path.addLine(to: CGPoint(x: rect.minX + radius + 4, y: top))
            path.addQuadCurve(to: CGPoint(x: rect.minX + 20, y: rect.minY),
                              control: CGPoint(x: rect.minX + 24, y: top))
            path.addQuadCurve(to: CGPoint(x: rect.minX + 44, y: top),
                              control: CGPoint(x: rect.minX + 34, y: rect.minY + 1))
        }
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius),
                          control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: bottom),
                          control: CGPoint(x: rect.maxX, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - radius),
                          control: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top),
                          control: CGPoint(x: rect.minX, y: top))
        path.closeSubpath()
        if tail == .bottomLeading {
            path = path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY))
        }
        if mirrored {
            path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        }
        return path
    }
}

struct ReactionEmojiLabel: View {
    let symbol: String
    let selected: Bool
    var tint: Color = .accentColor

    var body: some View {
        Text(symbol).font(.system(size: 25))
            .frame(width: 44, height: 44)
            .background(selected ? tint.opacity(0.18) : Color.primary.opacity(0.04), in: Circle())
            .overlay { Circle().strokeBorder(selected ? tint : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 0.75) }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
                        .symbolRenderingMode(.palette).foregroundStyle(Color(uiColor: .systemBackground), tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Circle())
    }
}

struct ReactionCameraLabel: View {
    var tint: Color = .accentColor
    var body: some View {
        Image(systemName: "camera.fill").font(.system(size: 20, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(tint.opacity(0.14), in: Circle())
            .contentShape(Circle())
    }
}

struct ReactionBubbleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
