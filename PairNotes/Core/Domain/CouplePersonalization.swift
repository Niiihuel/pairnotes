import Foundation

public enum CoupleTheme: String, Codable, CaseIterable, Sendable {
    case cream, rose, lavender, night
    public var title: String {
        switch self {
        case .cream: return "Crema"
        case .rose: return "Rosa empolvado"
        case .lavender: return "Lavanda"
        case .night: return "Noche"
        }
    }
    public var paperRGB: UInt32 {
        switch self {
        case .cream: return 0xFFF5DB
        case .rose: return 0xFFE1E8
        case .lavender: return 0xEEE8FA
        case .night: return 0x26282E
        }
    }
    public var accentRGB: UInt32 {
        switch self {
        case .cream: return 0x966039
        case .rose: return 0xA53F62
        case .lavender: return 0x705394
        case .night: return 0xD8B6EE
        }
    }
}

public enum HomeSection: String, Codable, CaseIterable, Sendable {
    case story, message, drawing, distance
    public var title: String {
        switch self {
        case .story: return "Nuestra historia"
        case .message: return "Último mensaje"
        case .drawing: return "Último dibujo"
        case .distance: return "Nuestra distancia"
        }
    }
}

public struct CouplePersonalization: Codable, Equatable, Sendable {
    public var theme: CoupleTheme
    public var phrase: String
    public var nicknames: [String: String]
    public var coverMemoryId: String?
    public var homeOrder: [HomeSection]
    public var revision: Int

    public init(theme: CoupleTheme = .rose, phrase: String = "", nicknames: [String: String] = [:],
                coverMemoryId: String? = nil, homeOrder: [HomeSection] = HomeSection.allCases, revision: Int = 0) {
        self.theme = theme; self.phrase = phrase; self.nicknames = nicknames
        self.coverMemoryId = coverMemoryId; self.homeOrder = homeOrder; self.revision = revision
    }
    public func name(for uid: String, fallback: String) -> String {
        let nickname = nicknames[uid]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nickname.isEmpty ? fallback : nickname
    }
    public func validate(memberIDs: [String]) throws {
        guard revision >= 0, phrase.utf16.count <= 160,
              homeOrder.count == HomeSection.allCases.count, Set(homeOrder) == Set(HomeSection.allCases),
              nicknames.allSatisfy({ memberIDs.contains($0.key) && $0.value.utf16.count <= 40 }),
              coverMemoryId.map({ (1...128).contains($0.utf8.count) && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              } }) ?? true else { throw LocalStoreError.corruptData }
    }
}

public struct MemoryDecoration: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable {
        case polaroid, postcard, journal
        public var title: String {
            switch self {
            case .polaroid: return "Polaroid"
            case .postcard: return "Postal"
            case .journal: return "Diario"
            }
        }
    }
    public enum Sticker: String, Codable, CaseIterable, Sendable {
        case none = "", heart, sparkles, flower, star, moon
        public var symbol: String {
            switch self {
            case .none: return ""
            case .heart: return "♡"
            case .sparkles: return "✨"
            case .flower: return "🌸"
            case .star: return "⭐️"
            case .moon: return "🌙"
            }
        }
    }
    public var layout: Layout
    public var sticker: Sticker
    public init(layout: Layout = .polaroid, sticker: Sticker = .heart) {
        self.layout = layout; self.sticker = sticker
    }
}
