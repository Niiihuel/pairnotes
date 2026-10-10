import XCTest

/// Touches the production Antojos screens with an isolated, simulator-only source.
/// Data and photo mutations never contact real accounts or an API.
final class WishesInteractionTests: XCTestCase {
    @MainActor
    func testPriceRequiresExplicitCurrencyAndClosedDraftRestoresBeforeSaving() {
        continueAfterFailure = false
        let app = launch(empty: true)
        defer { diagnostics(app, name: "wishes-currency-and-draft") }
        XCTAssertTrue(app.buttons["wishes.add"].waitForExistence(timeout: 15))
        attach(app, name: "wishes-empty-light")
        app.buttons["wishes.add"].tap()
        enter("Una idea para la casa", into: "wish.form.title", app: app)
        enter("2500,50", into: "wish.form.price", app: app)
        let currency = element("wish.form.currency", app: app)
        reveal(currency, app: app)
        XCTAssertTrue(currency.label.contains("Elegir moneda"))
        XCTAssertFalse(app.buttons["wish.form.save.toolbar"].isEnabled,
                       "A country or locale must never silently choose the currency")
        for code in ["ARS", "USD", "BRL", "MXN"] {
            reveal(currency, app: app); currency.tap()
            let row = app.buttons["wish.currency.\(code)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            if code == "ARS" { attach(app, name: "wishes-explicit-currency-picker") }
            row.tap()
            XCTAssertTrue(currency.waitForExistence(timeout: 5))
            XCTAssertTrue(currency.label.contains(code))
        }
        app.buttons["wish.form.close"].tap()
        waitForState(app, contains: ["count=0;", "saves=0;"])
        app.buttons["wishes.add"].tap()
        XCTAssertEqual(element("wish.form.title", app: app).value as? String, "Una idea para la casa")
        reveal(currency, app: app)
        XCTAssertTrue(currency.label.contains("MXN"))
        XCTAssertEqual(element("wish.form.price", app: app).value as? String, "2500,50")
        app.buttons["wish.form.save.toolbar"].tap()
        waitForState(app, contains: ["count=1;", "saves=1;", "lastCurrency=MXN;"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wish.card.")).firstMatch.exists)
        attach(app, name: "wishes-created-explicit-mxn")

        app.buttons["wishes.add"].tap()
        reveal(element("wish.form.currency", app: app), app: app)
        XCTAssertTrue(element("wish.form.currency", app: app).label.contains("Elegir moneda"),
                      "The next wish has no currency until the person selects one")
        app.buttons["wish.form.close"].tap()
    }

    @MainActor
    func testTravelBudgetSavingsDateFulfillAndDeleteUseSharedVersion() {
        continueAfterFailure = false
        let app = launch()
        defer { diagnostics(app, name: "wishes-travel-lifecycle") }
        let travel = app.buttons[cardID(1)]
        XCTAssertTrue(travel.waitForExistence(timeout: 15))
        attach(app, name: "wishes-category-grid-light")
        travel.tap()
        XCTAssertTrue(app.staticTexts["wish.detail.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["wish.detail.price"].label.contains("MXN"))
        attach(app, name: "wishes-travel-detail-light")
        app.buttons["wish.edit"].tap()
        XCTAssertTrue(element("wish.form.has-date", app: app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("wish.form.has-date", app: app).value as? String, "1")
        replace("1000,3001", in: "wish.form.price", app: app)
        replace("300,1001", in: "wish.form.saved", app: app)
        app.buttons["wish.form.save.toolbar"].tap()
        XCTAssertTrue(app.buttons["wish.edit"].waitForExistence(timeout: 5))
        let remaining = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Nos faltan")).firstMatch
        reveal(remaining, app: app)
        XCTAssertTrue(remaining.label.contains("700,2"), "Savings use exact decimal subtraction in the selected currency")
        XCTAssertTrue(remaining.label.contains("MXN"))
        attach(app, name: "wishes-travel-edited-savings")
        app.buttons["Cerrar"].tap()
        waitForState(app, contains: ["saves=1;", "lastRemaining=700.2;", "lastDate=2030-06-15;"])

        reveal(travel, app: app); travel.tap()
        let fulfill = app.buttons["wish.fulfill"]
        reveal(fulfill, app: app); fulfill.tap()
        waitFor(fulfill, predicate: NSPredicate(format: "label CONTAINS %@", "Volver a pendientes"))
        app.buttons["Cerrar"].tap()
        waitForState(app, contains: ["fulfilled=1;", "saves=2;"])
        app.segmentedControls["wishes.status"].buttons["Cumplidos"].tap()
        reveal(travel, app: app); travel.tap()
        let delete = app.buttons["wish.delete"]
        reveal(delete, app: app); delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Eliminar antojo", "wish.delete")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        waitForState(app, contains: ["count=5;", "deleted=1;", "fulfilled=0;"])
        XCTAssertFalse(travel.exists)
    }

    @MainActor
    func testGiftLinkOpensNativeBrowserAndRecipeDraftKeepsIngredientsAndPreparation() {
        continueAfterFailure = false
        let app = launch(dark: true)
        defer { diagnostics(app, name: "wishes-gift-and-recipe") }
        let gift = app.buttons[cardID(2)]
        XCTAssertTrue(gift.waitForExistence(timeout: 15))
        reveal(gift, app: app); gift.tap()
        XCTAssertTrue(app.staticTexts["wish.detail.price"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["wish.detail.price"].label.contains("USD"))
        attach(app, name: "wishes-gift-detail-dark")
        let link = app.buttons["wish.detail.link"]
        reveal(link, app: app); link.tap()
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Listo", "Done"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The publication opens inside the native Safari sheet")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        attach(app, name: "wishes-publication-native-browser")
        done.tap()
        XCTAssertTrue(app.buttons["wish.edit"].waitForExistence(timeout: 5))
        app.buttons["Cerrar"].tap()

        let recipe = app.buttons[cardID(3)]
        reveal(recipe, app: app); recipe.tap()
        XCTAssertTrue(app.buttons["wish.edit"].waitForExistence(timeout: 5))
        app.buttons["wish.edit"].tap()
        XCTAssertTrue(app.segmentedControls["wish.form.food-kind"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["wish.form.food-kind"].buttons["Receta"].isSelected)
        let ingredients = element("wish.form.ingredients", app: app)
        reveal(ingredients, app: app)
        XCTAssertTrue((ingredients.value as? String ?? "").contains("Albahaca"))
        replace("Cocinar juntos y servir con queso.", in: "wish.form.instructions", app: app)
        app.buttons["wish.form.close"].tap()
        XCTAssertTrue(app.buttons["wish.edit"].waitForExistence(timeout: 5))
        app.buttons["wish.edit"].tap()
        let preparation = element("wish.form.instructions", app: app)
        reveal(preparation, app: app)
        XCTAssertEqual(preparation.value as? String, "Cocinar juntos y servir con queso.")
        XCTAssertTrue((element("wish.form.ingredients", app: app).value as? String ?? "").contains("Albahaca"))
        attach(app, name: "wishes-recipe-restored-draft-dark")
        app.buttons["wish.form.save.toolbar"].tap()
        XCTAssertTrue(app.buttons["wish.edit"].waitForExistence(timeout: 5))
        app.buttons["Cerrar"].tap()
        waitForState(app, contains: ["saves=1;", "lastCategory=food", "lastCurrency=BRL;"])
    }

    @MainActor
    private func launch(empty: Bool = false, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_AR", "-pairnotes-wishes-interaction-fixture"]
        if empty { app.launchArguments.append("-pairnotes-wishes-empty") }
        if dark { app.launchArguments.append("-pairnotes-wishes-dark") }
        app.launch()
        return app
    }

    private func cardID(_ number: Int) -> String { String(format: "wish.card.70000000-0000-4000-8000-%012d", number) }
    private func element(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if target.exists && target.isHittable { return }
            let window = app.windows.firstMatch
            let frame = window.frame
            let keyboard = app.keyboards.firstMatch
            let startY = min(frame.maxY - 90, keyboard.exists ? keyboard.frame.minY - 30 : frame.maxY - 90)
            let endY = frame.minY + 140
            guard startY - endY > 100 else { break }
            // Keep the whole drag inside the form rather than starting on the keyboard.
            let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            let start = origin.withOffset(CGVector(dx: 0, dy: startY - frame.minY))
            let end = origin.withOffset(CGVector(dx: 0, dy: endY - frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(target.exists && target.isHittable, "Unreachable control: \(target.identifier)")
    }
    private func enter(_ text: String, into id: String, app: XCUIApplication) {
        let target = element(id, app: app)
        reveal(target, app: app); target.tap(); target.typeText(text)
    }
    private func replace(_ text: String, in id: String, app: XCUIApplication) {
        let target = element(id, app: app)
        reveal(target, app: app)
        let previous = target.value as? String ?? ""
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        target.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
    }
    private func waitFor(_ target: XCUIElement, predicate: NSPredicate) {
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
    private func waitForState(_ app: XCUIApplication, contains fragments: [String]) {
        let state = app.staticTexts["fixture.wishes.state"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            state.exists && fragments.allSatisfy { state.label.contains($0) }
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        XCTAssertEqual(result, .completed, "Expected \(fragments), got \(state.exists ? state.label : "missing fixture state")")
    }
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func diagnostics(_ app: XCUIApplication, name: String) {
        attach(app, name: name)
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name + "-hierarchy"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
