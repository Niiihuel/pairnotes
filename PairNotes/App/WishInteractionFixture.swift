#if DEBUG && targetEnvironment(simulator)
import Foundation
import PairNotesCore
import SwiftUI
import UIKit

/// Explicit simulator-only entry point. The production views receive an in-memory
/// source and synthetic pictures, never accounts or a backend connection.
@MainActor
struct WishInteractionFixture: View {
    @StateObject private var services = AppServices()
    @StateObject private var store = WishFixtureStore()

    var body: some View {
        NavigationStack {
            if services.identity == nil {
                WishesView(services: services, source: store.source)
                    .overlay(alignment: .topLeading) {
                        Text(store.description).font(.system(size: 1)).foregroundStyle(.clear)
                            .frame(width: 1, height: 1).allowsHitTesting(false)
                            .accessibilityIdentifier("fixture.wishes.state")
                    }
            } else { Text("La prueba requiere una sesión limpia.") }
        }
        .tint(services.personalization.theme.accent)
        .environment(\.coupleAppTheme, services.personalization.theme)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-pairnotes-wishes-dark") ? .dark : .light)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("-pairnotes-wishes-large-text") ? .accessibility3 : .large)
    }
}

@MainActor
private final class WishFixtureStore: ObservableObject {
    private let scope = "wish-fixture:" + UUID().uuidString
    private let pair = PairMembership(id: "wish-fixture-pair", memberIDs: ["fixture-alex", "fixture-sam"], pairEpoch: 1,
                                      partner: SessionIdentity(uid: "fixture-sam", displayName: "Sam"))
    @Published private var wishes: [CoupleWish] = []
    @Published private var saves = 0
    @Published private var deleted = 0
    @Published private var last: CoupleWish?
    private var receipts: [UUID: String] = [:]
    private var pictures: [String: UIImage] = [:]
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        guard !ProcessInfo.processInfo.arguments.contains("-pairnotes-wishes-empty") else { return }
        let seeds: [(CoupleWishCategory, String, String?, String?)] = [
            (.travel, "Escapada al mar", "1000", "MXN"), (.gifts, "Un regalo para Sam", "120", "USD"),
            (.food, "Pasta para dos", "75.5", "BRL"), (.home, "Rincón para leer", "85000", "ARS"),
            (.plans, "Una noche de estrellas", nil, nil), (.other, "Una idea por descubrir", nil, nil)
        ]
        for (index, seed) in seeds.enumerated() {
            let id = String(format: "70000000-0000-4000-8000-%012d", index + 1)
            let image = Self.picture(category: seed.0, index: index)
            let data = image.pngData() ?? Data()
            let photo = CoupleWishPhoto(id: String(format: "71000000-0000-4000-8000-%012d", index + 1),
                                       sha256: ContentDigest.sha256(data))
            pictures[photo.id] = image
            wishes.append(CoupleWish(id: id, pairId: pair.id, pairEpoch: pair.pairEpoch, authorId: "fixture-alex",
                title: seed.1, category: seed.0, notes: "Un antojo ficticio para compartir juntos.",
                priceAmount: seed.2, currencyCode: seed.3, photo: photo,
                createdAt: baseDate.addingTimeInterval(Double(-index)), updatedAt: baseDate.addingTimeInterval(Double(-index)), revision: 1,
                linkURL: seed.0 == .gifts ? "https://www.apple.com/iphone/" : nil,
                targetDate: seed.0 == .travel ? CoupleDate(rawValue: "2030-06-15") : nil,
                location: seed.0 == .travel ? "Mar del Plata" : "",
                savedAmount: seed.0 == .travel ? "250.25" : nil,
                recipient: seed.0 == .gifts ? "Sam" : "", occasion: seed.0 == .gifts ? "Cumpleaños" : "",
                foodKind: seed.0 == .food ? .recipe : nil,
                ingredients: seed.0 == .food ? "Pasta\nTomate\nAlbahaca" : "",
                instructions: seed.0 == .food ? "Cocinar la pasta y preparar la salsa juntos." : ""))
        }
    }

    var description: String {
        "count=\(wishes.count); saves=\(saves); deleted=\(deleted); fulfilled=\(wishes.filter(\.fulfilled).count); " +
            "lastCurrency=\(last?.currencyCode ?? "none"); lastRemaining=\(last?.remainingAmount ?? "none"); " +
            "lastDate=\(last?.targetDate?.rawValue ?? "none"); lastCategory=\(last?.category.rawValue ?? "none")"
    }

    var source: WishSource {
        WishSource(currentScope: { self.scope }, isAuthorized: { true }, draftKey: { self.scope + ":draft:" + $0 },
            list: { self.wishes }, save: { try self.save($0, id: $1, revision: $2, request: $3) },
            delete: { try self.delete($0, request: $1) },
            uploadPhoto: { try self.replacePhoto($0, wish: $1, request: $2) },
            removePhoto: { try self.replacePhoto(nil, wish: $0, request: $1) },
            photo: { wish in wish.photo.flatMap { self.pictures[$0.id] } })
    }

    private func save(_ fields: WishFields, id: String, revision: Int, request: UUID) throws -> CoupleWish {
        let values = try fields.validated()
        let previous = wishes.first { $0.id == id }
        if let acknowledged = receipts[request] {
            guard acknowledged == id, let previous else { throw APIError(status: 404, code: "wish_unavailable") }
            return previous
        }
        guard (previous?.revision ?? 0) == revision else { throw APIError(status: 409, code: "wish_revision_conflict") }
        let wish = CoupleWish(id: id, pairId: pair.id, pairEpoch: pair.pairEpoch,
            authorId: previous?.authorId ?? "fixture-alex", title: values.title, category: values.category, notes: values.notes,
            priceAmount: values.priceText.isEmpty ? nil : values.priceText, currencyCode: values.currencyCode,
            fulfilled: values.fulfilled, photo: previous?.photo,
            createdAt: previous?.createdAt ?? baseDate, updatedAt: baseDate.addingTimeInterval(Double(saves + 1)), revision: revision + 1,
            linkURL: values.linkText.isEmpty ? nil : values.linkText, targetDate: values.targetDate, location: values.location,
            savedAmount: values.savedText.isEmpty ? nil : values.savedText, recipient: values.recipient, occasion: values.occasion,
            foodKind: values.foodKind, ingredients: values.ingredients, instructions: values.instructions)
        try wish.validate(for: pair)
        wishes.removeAll { $0.id == id }; wishes.insert(wish, at: 0)
        saves += 1; last = wish; receipts[request] = id
        return wish
    }

    private func delete(_ wish: CoupleWish, request: UUID) throws {
        if receipts[request] == wish.id, !wishes.contains(where: { $0.id == wish.id }) { return }
        guard let current = wishes.first(where: { $0.id == wish.id }), current.revision == wish.revision else {
            throw APIError(status: 409, code: "wish_revision_conflict")
        }
        wishes.removeAll { $0.id == wish.id }; deleted += 1; receipts[request] = wish.id
    }

    private func replacePhoto(_ data: Data?, wish: CoupleWish, request: UUID) throws -> CoupleWish {
        guard let current = wishes.first(where: { $0.id == wish.id }) else { throw APIError(status: 404, code: "wish_unavailable") }
        if receipts[request] == wish.id { return current }
        guard current.revision == wish.revision else { throw APIError(status: 409, code: "wish_revision_conflict") }
        let photo: CoupleWishPhoto?
        if let data {
            guard let image = UIImage(data: data) else { throw ServiceError.invalidResponse }
            photo = CoupleWishPhoto(id: UUID().uuidString.lowercased(), sha256: ContentDigest.sha256(data))
            pictures[photo!.id] = image
        } else { photo = nil }
        let updated = CoupleWish(id: current.id, pairId: current.pairId, pairEpoch: current.pairEpoch, authorId: current.authorId,
            title: current.title, category: current.category, notes: current.notes, priceAmount: current.priceAmount,
            currencyCode: current.currencyCode, fulfilled: current.fulfilled, photo: photo,
            createdAt: current.createdAt, updatedAt: current.updatedAt.addingTimeInterval(1), revision: current.revision + 1,
            linkURL: current.linkURL, targetDate: current.targetDate, location: current.location, savedAmount: current.savedAmount,
            recipient: current.recipient, occasion: current.occasion, foodKind: current.foodKind,
            ingredients: current.ingredients, instructions: current.instructions)
        wishes.removeAll { $0.id == wish.id }; wishes.insert(updated, at: 0); receipts[request] = wish.id
        return updated
    }

    private static func picture(category: CoupleWishCategory, index: Int) -> UIImage {
        let size = CGSize(width: 640, height: 400)
        let colors: [UIColor] = [.systemTeal, .systemPink, .systemOrange, .systemPurple, .systemIndigo, .systemGreen]
        return UIGraphicsImageRenderer(size: size).image { context in
            let color = colors[index % colors.count]
            color.withAlphaComponent(0.16).setFill(); context.fill(CGRect(origin: .zero, size: size))
            color.withAlphaComponent(0.17).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 330, y: -140, width: 440, height: 440))
            context.cgContext.fillEllipse(in: CGRect(x: -90, y: 180, width: 310, height: 310))
            let symbol = UIImage(systemName: category.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 105, weight: .light))?.withTintColor(color, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 248, y: 130, width: 144, height: 140))
        }
    }
}
#endif
