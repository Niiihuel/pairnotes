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
    func testMountedEditorCannotWriteThePreviousAccountsDraftAfterSourceChanges() async throws {
        let lifecycle = WishEditorLifecycleFixtureState()
        let firstStorage = lifecycle.storage(scope: "account-a", draftID: "new")
        let secondStorage = lifecycle.storage(scope: "account-b", draftID: "new")
        defer { firstStorage.clear(); secondStorage.clear() }
        var first = WishEditorSeedDraft(fields: WishFields(category: .gifts))
        first.fields.title = "Borrador privado de la cuenta A"
        var second = WishEditorSeedDraft(fields: WishFields(category: .home))
        second.fields.title = "Borrador propio de la cuenta B"
        try firstStorage.saveValue(first)
        try secondStorage.saveValue(second)
        let secondPhoto = wishEditorPhoto(.systemTeal)
        try secondStorage.savePhoto(secondPhoto)

        let appeared = expectation(description: "account A editor mounted")
        let reinitialized = expectation(description: "same editor identity rebuilt for account B")
        let disappeared = expectation(description: "production editor disappeared")
        lifecycle.appeared = appeared
        lifecycle.reinitialized = reinitialized
        lifecycle.disappeared = disappeared
        let mounted = try mountWishEditor(lifecycle)
        defer { mounted.close() }
        mounted.render()
        await fulfillment(of: [appeared], timeout: 3)

        // Rebuild the same SwiftUI identity. Its @State draft still belongs to A,
        // while init receives closures returning B's current scope/storage key.
        lifecycle.scope = "account-b"
        mounted.render()
        await fulfillment(of: [reinitialized], timeout: 3)
        XCTAssertTrue(lifecycle.initializedScopes.contains("account-a"))
        XCTAssertTrue(lifecycle.initializedScopes.contains("account-b"),
                      "The test must exercise a new initializer without replacing the editor's identity")
        mounted.removeEditor()
        await fulfillment(of: [disappeared], timeout: 3)
        await Task.yield()

        let preservedFirst: WishEditorSeedDraft? = firstStorage.loadValue()
        let preservedSecond: WishEditorSeedDraft? = secondStorage.loadValue()
        XCTAssertEqual(preservedFirst, first)
        XCTAssertEqual(preservedSecond, second,
                       "onDisappear must never persist A's retained @State under account B's newly computed key")
        XCTAssertEqual(secondStorage.photo(), secondPhoto)
        XCTAssertEqual(lifecycle.mutations, 0)
    }

    @MainActor
    func testEditingCreatedCardRestoresPendingPhotoAndOriginalRetryFromCreationDraft() async throws {
        let lifecycle = WishEditorLifecycleFixtureState()
        let wish = sample(category: .travel, amount: "1500.25", saved: "300.1")
        let creationStorage = lifecycle.storage(scope: "account-a", draftID: "new")
        let cardStorage = lifecycle.storage(scope: "account-a", draftID: wish.id)
        defer { creationStorage.clear(); cardStorage.clear() }
        let pending = WishEditorSeedDraft(id: wish.id, fields: WishFields(wish), base: wish,
                                         metadataConfirmed: true, pendingPhoto: true, photoAction: "replace")
        let photo = wishEditorPhoto(.systemIndigo)
        try creationStorage.saveValue(pending)
        try creationStorage.savePhoto(photo)

        let appeared = expectation(description: "card editor recovered pending creation")
        let disappeared = expectation(description: "recovered editor persisted on disappearance")
        lifecycle.appeared = appeared
        lifecycle.disappeared = disappeared
        let mounted = try mountWishEditor(lifecycle, original: wish)
        defer { mounted.close() }
        mounted.render()
        await fulfillment(of: [appeared], timeout: 3)
        let screenshot = XCTAttachment(image: mounted.render())
        screenshot.name = "wishes-editor-recovered-pending-photo"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Alter disk after mounting. The existing editor must persist the exact
        // recovered request snapshot, proving it loaded the creation draft rather
        // than merely leaving an untouched file behind or constructing a new edit.
        var sentinel = pending
        sentinel.fields.title = "A later disk value that must not replace the mounted draft"
        sentinel.photoRequest = UUID()
        sentinel.metadataConfirmed = false
        sentinel.pendingPhoto = false
        try creationStorage.saveValue(sentinel)
        mounted.removeEditor()
        await fulfillment(of: [disappeared], timeout: 3)
        await Task.yield()

        let restored = try XCTUnwrap(creationStorage.loadValue() as WishEditorSeedDraft?)
        let duplicate: WishEditorSeedDraft? = cardStorage.loadValue()
        XCTAssertEqual(restored, pending, "Recovery must retain the confirmed metadata, pending photo and original request IDs")
        XCTAssertNil(duplicate, "Opening the card must not fork a second draft that loses the pending photo request")
        XCTAssertEqual(creationStorage.photo(), photo)
        XCTAssertEqual(lifecycle.mutations, 0, "Reopening for review must not silently save metadata or upload again")
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

    @MainActor
    private func mountWishEditor(_ lifecycle: WishEditorLifecycleFixtureState,
                                 original: CoupleWish? = nil) throws -> MountedWishEditor {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let host = UIHostingController(rootView: AnyView(WishEditorLifecycleFixture(lifecycle: lifecycle, original: original)))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return MountedWishEditor(window: window, host: host, previous: previous)
    }

    @MainActor
    private func wishEditorPhoto(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).jpegData(withCompressionQuality: 0.9) { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }
    }
}

/// Encodes the private persisted draft contract without exposing production state
/// or replacing the real editor's recovery/lifecycle implementation in these tests.
private struct WishEditorSeedDraft: Codable, Equatable {
    var id = UUID().uuidString.lowercased()
    var fields: WishFields
    var base: CoupleWish?
    var metadataRequest = UUID()
    var photoRequest = UUID()
    var metadataConfirmed = false
    var pendingMetadata = false
    var pendingPhoto = false
    var needsReview = false
    var photoAction = "keep"
}

@MainActor
private final class WishEditorLifecycleFixtureState: ObservableObject {
    @Published var scope = "account-a"
    let namespace = "wishes-native-lifecycle:" + UUID().uuidString
    var appeared: XCTestExpectation?
    var reinitialized: XCTestExpectation?
    var disappeared: XCTestExpectation?
    var initializedScopes: [String] = []
    var mutations = 0

    func storage(scope: String, draftID: String) -> MemoryCompositionStorage {
        MemoryCompositionStorage(key: namespace + ":" + scope + ":" + draftID)
    }

    func source() -> WishSource {
        initializedScopes.append(scope)
        return WishSource(currentScope: { self.scope }, isAuthorized: { true },
            draftKey: { self.storage(scope: self.scope, draftID: $0).key }, list: { [] },
            save: { _, _, _, _ in self.mutations += 1; XCTFail("Mounting an editor must not save remotely"); throw ServiceError.invalidResponse },
            delete: { _, _ in self.mutations += 1; XCTFail("Mounting an editor must not delete") },
            uploadPhoto: { _, _, _ in self.mutations += 1; XCTFail("Mounting an editor must not upload"); throw ServiceError.invalidResponse },
            removePhoto: { _, _ in self.mutations += 1; XCTFail("Mounting an editor must not remove a photo"); throw ServiceError.invalidResponse },
            photo: { _ in XCTFail("Recovery must use the local staged photo"); return nil })
    }
}

private struct WishEditorLifecycleFixture: View {
    @ObservedObject var lifecycle: WishEditorLifecycleFixtureState
    let original: CoupleWish?

    var body: some View {
        WishEditorView(source: lifecycle.source(), original: original,
                       onSaved: { _ in XCTFail("Mounting an editor must not confirm a remote save") })
            .onAppear { lifecycle.appeared?.fulfill(); lifecycle.appeared = nil }
            .onChange(of: lifecycle.scope) { _, _ in lifecycle.reinitialized?.fulfill(); lifecycle.reinitialized = nil }
            .onDisappear { lifecycle.disappeared?.fulfill(); lifecycle.disappeared = nil }
    }
}

@MainActor
private struct MountedWishEditor {
    let window: UIWindow
    let host: UIHostingController<AnyView>
    let previous: UIWindow?

    @discardableResult
    func render() -> UIImage {
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    func removeEditor() { host.rootView = AnyView(EmptyView()); _ = render() }

    func close() {
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
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
