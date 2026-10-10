import Foundation
import PairNotesCore
import SwiftUI
import UIKit
import XCTest
@testable import PairNotes

final class WishesLayoutTests: XCTestCase {
    func testEditorStartsWithoutCurrencyAndRequiresAnExplicitChoiceForPriceOrSavings() throws {
        let empty = WishFields(category: .travel)
        XCTAssertNil(empty.currencyCode)
        var fields = empty
        fields.title = "Viaje de los dos"
        XCTAssertNil(try fields.validated().currencyCode)
        fields.priceText = "1000,50"
        XCTAssertThrowsError(try fields.validated(locale: Locale(identifier: "es_AR")))
        fields.currencyCode = "MXN"
        fields.savedText = "250,25"
        let validated = try fields.validated(locale: Locale(identifier: "es_AR"))
        XCTAssertEqual(validated.priceText, "1000.5")
        XCTAssertEqual(validated.savedText, "250.25")
        XCTAssertEqual(validated.currencyCode, "MXN")
        fields.priceText = ""
        XCTAssertThrowsError(try fields.validated(locale: Locale(identifier: "es_AR")))
    }

    func testEditorPreservesDecimalMeaningWhenReopeningAcrossArgentinaAndMexico() throws {
        let wish = sample(category: .travel, amount: "1234.5678", saved: "0.0001")
        let fields = WishFields(wish)
        let saved = try fields.validated()
        XCTAssertEqual(saved.priceText, wish.priceAmount)
        XCTAssertEqual(saved.savedText, wish.savedAmount)
        XCTAssertEqual(saved.currencyCode, "USD")
        XCTAssertEqual(saved.targetDate?.rawValue, "2028-02-29")
        for locale in [Locale(identifier: "es_AR"), Locale(identifier: "es_MX")] {
            var localized = fields
            localized.priceText = CoupleWishPrice.editable(amount: "1234.5678", locale: locale)
            localized.savedText = CoupleWishPrice.editable(amount: "0.0001", locale: locale)
            XCTAssertEqual(try localized.validated(locale: locale).priceText, "1234.5678")
            XCTAssertEqual(try localized.validated(locale: locale).savedText, "0.0001")
        }
    }

    func testCategoryChangesRemoveOnlyIrrelevantDetailsAndRetainGiftDateAndLink() throws {
        var fields = WishFields(category: .gifts)
        fields.title = "Un regalo especial"
        fields.recipient = "Para los dos"
        fields.occasion = "Aniversario"
        fields.targetDate = CoupleDate(rawValue: "2028-02-29")
        fields.linkText = "https://example.com/regalo"
        XCTAssertEqual(try fields.validated().targetDate?.rawValue, "2028-02-29")
        fields.category = .food
        fields.foodKind = .recipe
        fields.ingredients = "Harina\nAgua"
        fields.instructions = "Mezclar y cocinar."
        let recipe = try fields.validated()
        XCTAssertTrue(recipe.recipient.isEmpty)
        XCTAssertTrue(recipe.occasion.isEmpty)
        XCTAssertNil(recipe.targetDate)
        XCTAssertEqual(recipe.ingredients, "Harina\nAgua")
        XCTAssertEqual(recipe.linkText, "https://example.com/regalo")
        fields.foodKind = .restaurant
        let restaurant = try fields.validated()
        XCTAssertTrue(restaurant.ingredients.isEmpty)
        XCTAssertTrue(restaurant.instructions.isEmpty)
    }

    func testPersistedDraftKeepsItsNumberLocaleUntilExplicitlyLocalized() throws {
        var fields = WishFields(category: .travel)
        fields.title = "Viaje"
        fields.numberLocaleIdentifier = "es_AR"
        fields.priceText = "1.234,50"
        fields.savedText = "0,0001"
        fields.currencyCode = "BRL"
        var restored = try JSONDecoder().decode(WishFields.self, from: JSONEncoder().encode(fields))
        XCTAssertEqual(try restored.validated().priceText, "1234.5")
        XCTAssertEqual(try restored.validated().savedText, "0.0001")
        restored.localizeNumbers(to: Locale(identifier: "es_MX"))
        XCTAssertEqual(restored.numberLocaleIdentifier, "es_MX")
        XCTAssertEqual(restored.priceText, "1234.5")
        XCTAssertEqual(restored.savedText, "0.0001")
        XCTAssertEqual(try restored.validated().priceText, "1234.5")
        XCTAssertEqual(try restored.validated().savedText, "0.0001")
    }

    func testEditorRejectsOversizedUnicodeAndUnsafeLinksBeforeStartingSave() throws {
        var fields = WishFields()
        fields.title = String(repeating: "🥰", count: 61)
        XCTAssertThrowsError(try fields.validated())
        fields.title = "Válido"
        fields.notes = String(repeating: "🥰", count: 501)
        XCTAssertThrowsError(try fields.validated())
        fields.notes = ""
        fields.linkText = "https://example.com/" + String(repeating: "a", count: 2048)
        XCTAssertThrowsError(try fields.validated())
        for invalid in ["javascript:alert(1)", "file:///private/item", "https://user:password@example.com", "https://"] {
            fields.linkText = invalid
            XCTAssertThrowsError(try fields.validated(), invalid)
        }
        fields.linkText = "https://example.com/receta"
        fields.category = .food; fields.foodKind = .recipe
        fields.ingredients = String(repeating: "a", count: 6001)
        XCTAssertThrowsError(try fields.validated())
        fields.ingredients = ""
        fields.instructions = String(repeating: "a", count: 10001)
        XCTAssertThrowsError(try fields.validated())
    }

    @MainActor
    func testRealWishCardsFitNarrowPhonesAndAccessibilityTextInBothAppearances() async throws {
        let services = AppServices()
        guard services.identity == nil else { throw XCTSkip("Requires a clean unauthenticated simulator") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let source = WishSource(currentScope: { "layout-fixture" }, isAuthorized: { true },
            draftKey: { "wishes-layout:" + $0 }, list: { [] },
            save: { _, _, _, _ in XCTFail("Rendering must not save"); throw ServiceError.invalidResponse },
            delete: { _, _ in XCTFail("Rendering must not delete") },
            uploadPhoto: { _, _, _ in XCTFail("Rendering must not upload"); throw ServiceError.invalidResponse },
            removePhoto: { _, _ in XCTFail("Rendering must not remove photos"); throw ServiceError.invalidResponse },
            photo: { _ in XCTFail("These cards do not have photos"); return nil })
        let values = [sample(category: .travel, amount: "9999999999.9999", saved: "0.0001"),
                      sample(category: .gifts, amount: "1250.75", saved: nil)]
        for width: CGFloat in [320, 393] {
            for large in [false, true] {
                for dark in [false, true] {
                    let name = "wishes-cards-\(Int(width))-\(large ? "accessibility3" : "body")-\(dark ? "dark" : "light")"
                    let ready = expectation(description: name)
                    let geometry = WishLayoutGeometry(ready)
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: large ? 1 : 2)
                    let root = ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(Array(values.enumerated()), id: \.offset) { _, wish in
                                WishCard(wish: wish, source: source)
                            }
                        }.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                            Task { @MainActor in geometry.record(size) }
                        }.padding(20)
                    }
                    .background(services.personalization.theme.canvas)
                    .environment(\.coupleAppTheme, services.personalization.theme)
                    .dynamicTypeSize(large ? .accessibility3 : .large)
                    .frame(width: width, height: 800).ignoresSafeArea()
                    let host = UIHostingController(rootView: AnyView(root))
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
                    window.overrideUserInterfaceStyle = dark ? .dark : .light
                    window.rootViewController = host; window.makeKeyAndVisible()
                    host.view.frame = window.bounds; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    window.layoutIfNeeded(); host.view.layoutIfNeeded()
                    let render = { UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    } }
                    _ = render()
                    await fulfillment(of: [ready], timeout: 3)
                    XCTAssertEqual(geometry.size.width, width - 40, accuracy: 0.5, name)
                    XCTAssertTrue(geometry.size.height.isFinite)
                    XCTAssertGreaterThan(geometry.size.height, 180, name)
                    let attachment = XCTAttachment(image: render())
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    host.rootView = AnyView(EmptyView()); host.view.layoutIfNeeded(); await Task.yield()
                    window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
                }
            }
        }
    }

    private func sample(category: CoupleWishCategory, amount: String, saved: String?) -> CoupleWish {
        CoupleWish(id: UUID().uuidString.lowercased(), pairId: "layout-pair", pairEpoch: 1, authorId: "layout-a",
            title: category == .travel ? "Nuestro próximo viaje para reencontrarnos" : "Un juego de mesa para disfrutar juntos",
            category: category, priceAmount: amount, currencyCode: "USD", createdAt: Date(), updatedAt: Date(), revision: 1,
            linkURL: "https://example.com/idea", targetDate: CoupleDate(rawValue: "2028-02-29"),
            savedAmount: saved, recipient: category == .gifts ? "Para los dos" : "")
    }
}

@MainActor
private final class WishLayoutGeometry {
    let ready: XCTestExpectation
    var size = CGSize.zero
    private var fulfilled = false
    init(_ ready: XCTestExpectation) { self.ready = ready }
    func record(_ size: CGSize) {
        self.size = size
        if size.width > 0, size.height > 0, !fulfilled { fulfilled = true; ready.fulfill() }
    }
}
