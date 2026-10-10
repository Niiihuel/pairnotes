import Foundation
import XCTest
@testable import PairNotesCore

final class CoupleWishTests: XCTestCase {
    private let pair = PairMembership(id: "wish-pair", memberIDs: ["alex", "sam"], pairEpoch: 3,
                                      partner: SessionIdentity(uid: "sam", displayName: "Sam"))

    func testLocalizedAmountsRemainExactAndAcceptSpanishDecimalComma() throws {
        let spanish = Locale(identifier: "es_AR"), english = Locale(identifier: "en_US")
        XCTAssertEqual(try CoupleWishPrice.parse("1.234,5000", locale: spanish), "1234.5")
        XCTAssertEqual(try CoupleWishPrice.parse("  0,0001  ", locale: spanish), "0.0001")
        XCTAssertEqual(try CoupleWishPrice.parse(",25", locale: spanish), "0.25")
        XCTAssertEqual(try CoupleWishPrice.parse("1,234.5000", locale: english), "1234.5")
        XCTAssertEqual(try CoupleWishPrice.parse("9,999,999,999.9999", locale: english), "9999999999.9999")
        XCTAssertEqual(try CoupleWishPrice.parse("0000", locale: spanish), "0")
        XCTAssertNil(try CoupleWishPrice.parse(" \n ", locale: spanish))
        for locale in [spanish, english] {
            let canonical = "1.234"
            let editable = CoupleWishPrice.editable(amount: canonical, locale: locale)
            XCTAssertEqual(try CoupleWishPrice.parse(editable, locale: locale), canonical,
                "Editing a canonical decimal must not reinterpret its dot as a thousands separator")
        }
    }

    func testAmountsRejectNegativeNonFiniteScientificMalformedAndExcessPrecisionValues() {
        for invalid in ["-1", "+1", "NaN", "nan", "Infinity", "inf", "1e2", "1/2", "1$", "１２", "1 23",
                        "1,23.00", "1234,567", ".", "1.", "1..2", "10000000000", "1.00001", "0.00000"] {
            XCTAssertThrowsError(try CoupleWishPrice.parse(invalid, locale: Locale(identifier: "en_US")), invalid)
        }
        XCTAssertEqual(try CoupleWishPrice.canonical("000012.3400"), "12.34")
        for invalid in ["01", "1.0", "00.01", "1.2300", "-0", "1e2"] {
            XCTAssertFalse(CoupleWishPrice.isCanonical(invalid), invalid)
        }
    }

    func testEveryPricedWishRequiresItsOwnExplicitCurrencyAndFormatsItsCode() throws {
        let empty = try wish()
        XCTAssertNil(empty.priceAmount)
        XCTAssertNil(empty.currencyCode)
        XCTAssertNil(empty.formattedPrice(locale: Locale(identifier: "es_AR")))
        for code in ["ARS", "MXN", "USD", "BRL", "EUR", "JPY"] {
            XCTAssertTrue(CoupleWishPrice.currencyCodes.contains(code))
            let priced = try wish(["priceAmount": "12.3456", "currencyCode": code])
            XCTAssertNoThrow(try priced.validate(for: pair))
            let formatted = try XCTUnwrap(priced.formattedPrice(locale: Locale(identifier: "es_AR")))
            XCTAssertTrue(formatted.contains(code), "A dollar symbol alone would confuse ARS, MXN, and USD")
            XCTAssertTrue(formatted.contains("3456"), "Formatting must preserve the entered decimal precision")
        }
        for invalid: [String: Any] in [["priceAmount": "25"], ["currencyCode": "USD"],
                                      ["priceAmount": "25", "currencyCode": "usd"],
                                      ["priceAmount": "25", "currencyCode": "$"],
                                      ["priceAmount": "-2", "currencyCode": "ARS"]] {
            XCTAssertThrowsError(try wish(invalid).validate(for: pair))
        }
        XCTAssertNoThrow(try wish(["priceAmount": "0", "currencyCode": "MXN"]).validate(for: pair))
    }

    func testSavingsUseExactSameCurrencyAndClampRemainingAtZero() throws {
        for (budget, saved, expected) in [("0.3", "0.1", "0.2"), ("1000", "250.1234", "749.8766"),
                                           ("100", "150", "0"), ("9999999999.9999", "0.0001", "9999999999.9998")] {
            let travel = try wish(["category": "travel", "priceAmount": budget, "currencyCode": "MXN", "savedAmount": saved])
            XCTAssertNoThrow(try travel.validate(for: pair))
            XCTAssertEqual(travel.remainingAmount, expected)
            XCTAssertEqual(travel.currencyCode, "MXN")
        }
        let notPriced = try wish(["category": "travel"])
        XCTAssertNil(notPriced.remainingAmount)
        XCTAssertEqual(CoupleWishPrice.remaining(budget: "10", saved: nil), "10")
        XCTAssertNil(CoupleWishPrice.remaining(budget: "10", saved: "-1"))
        XCTAssertThrowsError(try wish(["category": "travel", "savedAmount": "1"]).validate(for: pair))
        XCTAssertThrowsError(try wish(["category": "home", "priceAmount": "100", "currencyCode": "USD", "savedAmount": "1"]).validate(for: pair))
    }

    func testScopeAuthorRevisionAndPhotoMetadataMustBelongToCurrentPair() throws {
        XCTAssertNoThrow(try wish().validate(for: pair))
        XCTAssertNoThrow(try wish(["authorId": "sam", "revision": 9]).validate(for: pair), "Both partners own the shared list")
        for invalid: [String: Any] in [["pairId": "other"], ["pairEpoch": 2], ["authorId": "third-person"],
                                      ["revision": 0], ["revision": -1], ["id": "../another-item"],
                                      ["updatedAt": 999], ["createdAt": 0], ["title": " \n"],
                                      ["title": String(repeating: "a", count: 121)],
                                      ["notes": String(repeating: "a", count: 1_001)],
                                      ["photo": ["id": UUID().uuidString, "sha256": "wrong"]]] {
            XCTAssertThrowsError(try wish(invalid).validate(for: pair), String(describing: invalid.keys))
        }
        let photo = CoupleWishPhoto(id: UUID().uuidString, sha256: String(repeating: "a", count: 64))
        XCTAssertNoThrow(try wish(["photo": ["id": photo.id, "sha256": photo.sha256]]).validate(for: pair))
    }

    func testLinksAllowPublicHTTPPagesAndCivilDatesRemainDateOnly() throws {
        for link in ["https://example.com/product?id=1", "http://example.com/recipe", "https://ejemplo.com/viaje#precios"] {
            let value = try wish(["linkURL": link, "targetDate": "2028-02-29", "location": "Buenos Aires"])
            XCTAssertNoThrow(try value.validate(for: pair))
            XCTAssertEqual(value.targetDate?.rawValue, "2028-02-29")
        }
        for link in ["javascript:alert(1)", "file:///private/test", "/relative", "https://", "https://user:password@example.com",
                     "https://example.com/" + String(repeating: "a", count: 2_048)] {
            XCTAssertThrowsError(try wish(["linkURL": link]).validate(for: pair))
        }
        XCTAssertThrowsError(try wish(["targetDate": "2027-02-29"]))
        XCTAssertThrowsError(try wish(["targetDate": "2028-02-29T00:00:00Z"]))
    }

    func testRecipeGiftAndCategorySpecificFieldsCannotLeakIntoAnotherCategory() throws {
        let recipe = try wish(["category": "food", "foodKind": "recipe", "ingredients": "Harina\nAgua", "instructions": "Mezclar."])
        XCTAssertNoThrow(try recipe.validate(for: pair))
        XCTAssertEqual(recipe.foodKind, .recipe)
        let gift = try wish(["category": "gifts", "recipient": "Sam", "occasion": "Cumpleaños"])
        XCTAssertNoThrow(try gift.validate(for: pair))
        for invalid: [String: Any] in [["category": "home", "recipient": "Sam"], ["category": "plans", "foodKind": "restaurant"],
                                      ["category": "food", "foodKind": "restaurant", "ingredients": "Harina"],
                                      ["category": "food", "foodKind": "recipe", "instructions": String(repeating: "a", count: 10_001)]] {
            XCTAssertThrowsError(try wish(invalid).validate(for: pair))
        }
    }

    func testAllWishFieldsRoundTripWithoutImplicitCurrencyOrPrecisionLoss() throws {
        let original = try wish(["category": "travel", "priceAmount": "1234.5678", "currencyCode": "BRL",
                                 "savedAmount": "0.0001", "linkURL": "https://example.com/trip", "targetDate": "2028-02-29",
                                 "location": "Rio de Janeiro", "fulfilled": true, "revision": 4])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(CoupleWish.self, from: encoder.encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertNoThrow(try restored.validate(for: pair))
        XCTAssertEqual(restored.remainingAmount, "1234.5677")
    }

    private func wish(_ changes: [String: Any] = [:]) throws -> CoupleWish {
        var object: [String: Any] = ["id": "50000000-0000-4000-8000-000000000001", "pairId": pair.id,
            "pairEpoch": pair.pairEpoch, "authorId": "alex", "title": "Un antojo", "category": "other", "notes": "",
            "priceAmount": NSNull(), "currencyCode": NSNull(), "fulfilled": false, "photo": NSNull(),
            "createdAt": 1_000, "updatedAt": 2_000, "revision": 1, "linkURL": NSNull(), "targetDate": NSNull(),
            "location": "", "savedAmount": NSNull(), "recipient": "", "occasion": "", "foodKind": NSNull(),
            "ingredients": "", "instructions": ""]
        object.merge(changes) { _, new in new }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CoupleWish.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
