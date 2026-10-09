import XCTest

/// Real out-of-process touches on the production chat scroll/composer, without
/// linked accounts, messages, microphone requests or network fixtures.
final class ChatInteractionTests: XCTestCase {
    @MainActor
    func testKeyboardClosesFromHistoryControlsDraggingAndDoneWithoutLosingDraft() {
        continueAfterFailure = false
        let app = launchFixture()
        let field = app.descendants(matching: .any).matching(identifier: "chat.message").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let history = app.scrollViews["chat.history"]
        field.tap()
        field.typeText("Mi borrador")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        // Empty space in the conversation must dismiss, without selecting text.
        history.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.7)).tap()
        waitForKeyboardToClose(in: app)
        XCTAssertEqual(field.value as? String, "Mi borrador")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let action = app.buttons["fixture.message.action"]
        waitUntilHittable(action)
        action.tap()
        waitForKeyboardToClose(in: app)
        XCTAssertEqual(app.staticTexts["fixture.action.count"].label, "Acciones: 1",
                       "Dismissing the keyboard must preserve the message's own action")
        XCTAssertEqual(field.value as? String, "Mi borrador")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        history.swipeDown()
        waitForKeyboardToClose(in: app)
        XCTAssertEqual(field.value as? String, "Mi borrador")

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let done = app.buttons["chat.keyboard.dismiss"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        waitForKeyboardToClose(in: app)
        XCTAssertEqual(field.value as? String, "Mi borrador")
        attach(app.screenshot(), name: "chat-keyboard-dismissed-draft-preserved")
    }

    @MainActor
    func testLatestMessageButtonUsesVisiblePositionAndNewMessagesRespectOlderReading() {
        continueAfterFailure = false
        let app = launchFixture()
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        let last = app.staticTexts["fixture.message.29"]
        waitUntilHittable(last)
        XCTAssertFalse(app.buttons["chat.latest"].exists)
        history.swipeDown()
        let latest = app.buttons["chat.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        waitUntilHittable(latest)
        XCTAssertGreaterThanOrEqual(latest.frame.width, 44)
        XCTAssertGreaterThanOrEqual(latest.frame.height, 44)
        XCTAssertFalse(last.isHittable)

        app.buttons["fixture.incoming"].tap()
        let incoming = app.staticTexts["fixture.message.30"]
        XCTAssertFalse(incoming.isHittable, "A new message must not pull the reader away from older history")
        XCTAssertTrue(latest.isHittable)
        attach(app.screenshot(), name: "chat-reading-older-latest-button")

        latest.tap()
        waitUntilHittable(incoming)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: latest)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        attach(app.screenshot(), name: "chat-returned-to-latest-message")
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_AR",
                               "-pairnotes-chat-interaction-fixture"]
        app.launch()
        return app
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor
    private func waitForKeyboardToClose(in app: XCUIApplication) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
