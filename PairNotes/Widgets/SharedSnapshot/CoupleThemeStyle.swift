import PairNotesCore
import SwiftUI
import UIKit

private struct CoupleAppThemeKey: EnvironmentKey {
    static let defaultValue: CoupleTheme = .rose
}

extension EnvironmentValues {
    var coupleAppTheme: CoupleTheme {
        get { self[CoupleAppThemeKey.self] }
        set { self[CoupleAppThemeKey.self] = newValue }
    }
}

/// The surrounding app surface is shared by collections, forms and sheets.
/// Paper, photographs and other content keep their own surfaces inside it.
private struct CoupleScreenBackground: ViewModifier {
    @Environment(\.coupleAppTheme) private var inheritedTheme
    let theme: CoupleTheme?

    func body(content: Content) -> some View {
        let background = (theme ?? inheritedTheme).canvas
        content
            .scrollContentBackground(.hidden)
            .background(background.ignoresSafeArea())
            .presentationBackground(background)
    }
}

extension View {
    func coupleScreenBackground(_ theme: CoupleTheme? = nil) -> some View {
        modifier(CoupleScreenBackground(theme: theme))
    }
}

extension CoupleTheme {
    var accent: Color { adaptive(accentRGB, dark: self == .cream ? 0xE0BB95 : self == .rose ? 0xE7A5BB : 0xD8B6EE) }
    var paper: Color { adaptive(paperRGB, dark: 0x26282E) }
    var canvas: Color {
        switch self {
        case .cream: return adaptive(0xFBF7EE, dark: 0x1C1D24)
        case .rose: return adaptive(0xFCF3F5, dark: 0x1C1D24)
        case .lavender: return adaptive(0xF6F3FB, dark: 0x1C1D24)
        case .night: return Color(rgb: 0x1C1D24)
        }
    }
    var card: Color { self == .night ? Color(rgb: 0x30313A) : adaptive(0xFFFFFF, dark: 0x30313A) }
    var ink: Color { self == .night ? Color(rgb: 0xF9F0E8) : adaptive(0x382D35, dark: 0xF9F0E8) }
    private func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
