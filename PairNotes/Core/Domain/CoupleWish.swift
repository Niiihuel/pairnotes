import Foundation

public enum CoupleWishCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case travel, home, food, plans, gifts, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .travel: return "Viajes"
        case .home: return "Hogar"
        case .food: return "Comida"
        case .plans: return "Planes"
        case .gifts: return "Regalitos"
        case .other: return "Otros"
        }
    }
    public var symbol: String {
        switch self {
        case .travel: return "airplane"
        case .home: return "house.fill"
        case .food: return "fork.knife"
        case .plans: return "calendar"
        case .gifts: return "gift.fill"
        case .other: return "sparkles"
        }
    }
}

public enum CoupleWishFoodKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case restaurant, recipe
    public var id: String { rawValue }
    public var title: String { self == .restaurant ? "Restaurante" : "Receta" }
}

public typealias CoupleWishPhoto = CoupleAvatar

/// A shared wish keeps the original author's identity while either partner may edit it.
public struct CoupleWish: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let pairId: String
    public let pairEpoch: UInt64
    public let authorId: String
    public let title: String
    public let category: CoupleWishCategory
    public let notes: String
    public let priceAmount: String?
    public let currencyCode: String?
    public let fulfilled: Bool
    public let photo: CoupleWishPhoto?
    public let createdAt: Date
    public let updatedAt: Date
    public let revision: Int
    public let linkURL: String?
    public let targetDate: CoupleDate?
    public let location: String
    public let savedAmount: String?
    public let recipient: String
    public let occasion: String
    public let foodKind: CoupleWishFoodKind?
    public let ingredients: String
    public let instructions: String

    public init(id: String, pairId: String, pairEpoch: UInt64, authorId: String, title: String,
                category: CoupleWishCategory, notes: String = "", priceAmount: String? = nil,
                currencyCode: String? = nil, fulfilled: Bool = false, photo: CoupleWishPhoto? = nil,
                createdAt: Date, updatedAt: Date, revision: Int,
                linkURL: String? = nil, targetDate: CoupleDate? = nil, location: String = "",
                savedAmount: String? = nil, recipient: String = "", occasion: String = "",
                foodKind: CoupleWishFoodKind? = nil, ingredients: String = "", instructions: String = "") {
        self.id = id; self.pairId = pairId; self.pairEpoch = pairEpoch; self.authorId = authorId
        self.title = title; self.category = category; self.notes = notes
        self.priceAmount = priceAmount; self.currencyCode = currencyCode; self.fulfilled = fulfilled
        self.photo = photo; self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision
        self.linkURL = linkURL; self.targetDate = targetDate; self.location = location; self.savedAmount = savedAmount
        self.recipient = recipient; self.occasion = occasion; self.foodKind = foodKind
        self.ingredients = ingredients; self.instructions = instructions
    }

    public func validate(for pair: PairMembership) throws {
        guard UUID(uuidString: id) != nil, pairId == pair.id, pairEpoch == pair.pairEpoch,
              pair.memberIDs.contains(authorId), (1...120).contains(title.utf16.count),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              notes.utf16.count <= 1_000, location.utf16.count <= 240,
              recipient.utf16.count <= 120, occasion.utf16.count <= 120,
              ingredients.utf16.count <= 6_000, instructions.utf16.count <= 10_000,
              (1...9_007_199_254_740_991).contains(revision),
              createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 > 0,
              updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt,
              (priceAmount == nil) == (currencyCode == nil),
              priceAmount.map(CoupleWishPrice.isCanonical) ?? true,
              currencyCode.map(CoupleWishPrice.isCurrencyCode) ?? true,
              linkURL.map(Self.isPublicLink) ?? true else { throw AccountDomainError.invalidContext }
        if let savedAmount {
            guard category == .travel, priceAmount != nil, currencyCode != nil,
                  CoupleWishPrice.isCanonical(savedAmount) else { throw AccountDomainError.invalidContext }
        }
        guard category == .gifts || (recipient.isEmpty && occasion.isEmpty),
              category == .food || foodKind == nil,
              (category == .food && foodKind == .recipe) || (ingredients.isEmpty && instructions.isEmpty) else {
            throw AccountDomainError.invalidContext
        }
        if let photo {
            guard UUID(uuidString: photo.id) != nil, photo.sha256.utf8.count == 64,
                  photo.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AccountDomainError.invalidContext
            }
        }
    }

    public static func isPublicLink(_ text: String) -> Bool {
        guard text.utf16.count <= 2_048, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = URLComponents(string: text), let scheme = value.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.url != nil else { return false }
        return true
    }

    public var remainingAmount: String? {
        guard category == .travel, let priceAmount, currencyCode != nil else { return nil }
        return CoupleWishPrice.remaining(budget: priceAmount, saved: savedAmount)
    }

    public func formattedPrice(locale: Locale = .current) -> String? {
        guard let priceAmount, let currencyCode else { return nil }
        return CoupleWishPrice.format(amount: priceAmount, currencyCode: currencyCode, locale: locale)
    }
}

public enum CoupleWishPriceError: LocalizedError, Equatable {
    case invalidAmount, currencyRequired, invalidCurrency
    public var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Ingresá un importe válido, con hasta 10 enteros y 4 decimales."
        case .currencyRequired: return "Elegí la moneda del importe."
        case .invalidCurrency: return "Elegí una moneda válida."
        }
    }
}

/// Decimal strings avoid binary floating-point rounding and never imply a default currency.
public enum CoupleWishPrice {
    public static let currencyCodes = Locale.commonISOCurrencyCodes.sorted()

    /// ISO membership is checked authoritatively by the server. This accepts new
    /// three-letter codes even if this device's Foundation currency list is older.
    public static func isCurrencyCode(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy { (65...90).contains($0) }
    }

    public static func isCanonical(_ amount: String) -> Bool {
        (try? canonical(amount)) == amount
    }

    public static func canonical(_ amount: String) throws -> String {
        let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || parts[1].count <= 4 else { throw CoupleWishPriceError.invalidAmount }
        let significant = parts[0].drop(while: { $0 == "0" })
        let whole = significant.isEmpty ? "0" : String(significant)
        guard whole.count <= 10 else { throw CoupleWishPriceError.invalidAmount }
        let fraction = parts.count == 2 ? String(parts[1].reversed().drop(while: { $0 == "0" }).reversed()) : ""
        return fraction.isEmpty ? whole : whole + "." + fraction
    }

    /// Localized grouping is accepted only in complete groups of three. Editing
    /// an existing value must use editable(amount:locale:) to preserve its decimal separator.
    public static func parse(_ text: String, locale: Locale = .current) throws -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let decimal = locale.decimalSeparator ?? "."
        let grouping = locale.groupingSeparator ?? ","
        let parts = value.components(separatedBy: decimal)
        guard (1...2).contains(parts.count) else { throw CoupleWishPriceError.invalidAmount }
        var whole = parts[0]
        if !grouping.isEmpty, grouping != decimal, whole.contains(grouping) {
            let groups = whole.components(separatedBy: grouping)
            guard (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }),
                  groups.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else {
                throw CoupleWishPriceError.invalidAmount
            }
            whole = groups.joined()
        }
        if whole.isEmpty { whole = "0" }
        return try canonical(whole + (parts.count == 2 ? "." + parts[1] : ""))
    }

    public static func editable(amount: String, locale: Locale = .current) -> String {
        amount.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    public static func format(amount: String, currencyCode: String, locale: Locale = .current) -> String {
        guard isCanonical(amount), isCurrencyCode(currencyCode),
              let decimal = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
            return currencyCode + " " + amount
        }
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode; formatter.currencySymbol = currencyCode
        // Explicit precision also avoids ICU currency defaults rounding a four-decimal amount.
        formatter.minimumFractionDigits = amount.split(separator: ".").dropFirst().first?.count ?? 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? (currencyCode + " " + amount)
    }

    public static func remaining(budget: String, saved: String?) -> String? {
        guard isCanonical(budget), saved.map(isCanonical) ?? true,
              let target = Decimal(string: budget, locale: Locale(identifier: "en_US_POSIX")),
              let available = Decimal(string: saved ?? "0", locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return try? canonical(NSDecimalNumber(decimal: max(0, target - available)).stringValue)
    }
}
