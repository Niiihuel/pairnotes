import PairNotesCore
import SwiftUI

extension CoupleTheme {
    var accent: Color { Color(rgb: accentRGB) }
    var paper: Color { Color(rgb: paperRGB) }
    var canvas: Color {
        switch self {
        case .cream: return Color(rgb: 0xFBF7EE)
        case .rose: return Color(rgb: 0xFCF3F5)
        case .lavender: return Color(rgb: 0xF6F3FB)
        case .night: return Color(rgb: 0x1C1D24)
        }
    }
    var card: Color { self == .night ? Color(rgb: 0x30313A) : Color.white.opacity(0.86) }
    var ink: Color { self == .night ? Color(rgb: 0xF9F0E8) : Color(rgb: 0x382D35) }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
