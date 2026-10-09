import XCTest

/// Real out-of-process touches on the production chat scroll/composer, without
/// linked accounts, messages, microphone requests or network fixtures.
final class ChatInteractionTests: XCTestCase {
    @MainActor
    func testKeyboardHasNoDoneToolbarAndClosesFromHistoryControlsAndDraggingWithoutLosingDraft() {
        continueAfterFailure = false
        let app = launchFixture()
        defer { attachDiagnostics(in: app, name: "chat-keyboard-geometry") }
        let field = app.descendants(matching: .any).matching(identifier: "chat.message").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let history = app.scrollViews["chat.history"]
        field.tap()
        field.typeText("Mi borrador")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.keyboard.dismiss"].exists,
                       "The chat must not add a floating Done control above the keyboard")

        // Empty space in the conversation must dismiss, without selecting text.
        tapVisibleHistorySpace(in: app, history: history, composer: field)
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
        XCTAssertFalse(app.buttons["chat.keyboard.dismiss"].exists)
        tapVisibleHistorySpace(in: app, history: history, composer: field)
        waitForKeyboardToClose(in: app)
        XCTAssertEqual(field.value as? String, "Mi borrador")
        attach(app.screenshot(), name: "chat-keyboard-dismissed-draft-preserved")
    }

    @MainActor
    func testLatestMessageButtonUsesVisiblePositionAndNewMessagesRespectOlderReading() {
        continueAfterFailure = false
        let app = launchFixture()
        defer { attachDiagnostics(in: app, name: "chat-scroll-geometry") }
        let history = app.scrollViews["chat.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        let last = app.staticTexts["fixture.message.29"]
        waitUntilHittable(last)
        let initiallyHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                       object: app.buttons["chat.latest"])
        XCTAssertEqual(XCTWaiter.wait(for: [initiallyHidden], timeout: 5), .completed)
        history.swipeDown()
        let latest = app.buttons["chat.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        waitUntilHittable(latest)
        attachDiagnostics(in: app, name: "chat-latest-button-size")
        XCTAssertGreaterThanOrEqual(latest.frame.width, 44)
        XCTAssertGreaterThanOrEqual(latest.frame.height, 44)
        XCTAssertLessThanOrEqual(latest.frame.width, 56)
        XCTAssertLessThanOrEqual(latest.frame.height, 56)
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
    func testLongPressShowsSixAccessibleReactionsAndOnlyConfirmationChangesSelection() {
        continueAfterFailure = false
        let app = launchFixture(reactions: true)
        defer { attachDiagnostics(in: app, name: "chat-reaction-long-press") }
        let target = reactionTarget(in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        attachDiagnostics(in: app, name: "chat-reaction-before-long")
        waitUntilHittable(target)
        target.press(forDuration: 0.55)
        let fire = app.buttons["chat.reaction.fire"]
        XCTAssertTrue(fire.waitForExistence(timeout: 5))
        let kinds = ["heart", "laugh", "fire", "tear", "thumbsUp", "surprised"]
        let window = app.windows.firstMatch.frame
        var frames: [CGRect] = []
        for kind in kinds {
            let control = app.buttons["chat.reaction.\(kind)"]
            XCTAssertTrue(control.exists)
            // AX converts screen coordinates through floating-point transforms.
            // A 44pt target can be reported as 43.999999999999986pt.
            XCTAssertGreaterThanOrEqual(control.frame.width, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44 - 0.01)
            XCTAssertTrue(window.contains(control.frame), "All six reactions must stay visible on the phone")
            frames.append(control.frame)
        }
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(left.maxX, right.minX, "Reaction hit targets must not overlap")
            XCTAssertEqual(left.midY, right.midY, accuracy: 0.5, "Reactions must stay in one horizontal row")
        }
        let bar = app.descendants(matching: .any).matching(identifier: "chat.reaction.bar").firstMatch
        XCTAssertTrue(bar.exists)
        XCTAssertEqual(bar.frame.width, 286, accuracy: 1)
        XCTAssertEqual(bar.frame.height, 54, accuracy: 1, "The emoji pill must not grow into an oversized popover")
        let copy = app.buttons["chat.reaction.copy"]
        XCTAssertTrue(copy.exists)
        XCTAssertTrue(window.contains(copy.frame))
        let field = app.descendants(matching: .any).matching(identifier: "chat.message").firstMatch
        XCTAssertLessThanOrEqual(copy.frame.maxY, field.frame.minY,
                                "The menu must fit in the history above the composer")
        XCTAssertLessThan(copy.frame.width, bar.frame.width, "Copy has its own compact panel")
        XCTAssertGreaterThanOrEqual(copy.frame.minY - bar.frame.maxY, 7, "The two panels must remain separate")
        attach(app.screenshot(), name: "chat-reaction-six-options")

        fire.tap()
        waitForReactionState("requests=1; confirmations=0; pending=fire; confirmed=none; actions=0", in: app)
        XCTAssertFalse(fire.isEnabled)
        XCTAssertNotEqual(fire.value as? String, "Seleccionada", "An unconfirmed request must not select an emoji")
        dismissReactionPicker(in: app)
        app.buttons["fixture.reaction.fail"].tap()
        waitForReactionState("requests=1; confirmations=0; pending=idle; confirmed=none; actions=0", in: app)
        XCTAssertTrue(app.staticTexts["chat.reaction.error"].waitForExistence(timeout: 5))

        target.press(forDuration: 0.55)
        XCTAssertTrue(fire.waitForExistence(timeout: 5))
        fire.tap()
        waitForReactionState("requests=2; confirmations=0; pending=fire; confirmed=none; actions=0", in: app)
        dismissReactionPicker(in: app)
        app.buttons["fixture.reaction.confirm"].tap()
        waitForReactionState("requests=2; confirmations=1; pending=idle; confirmed=fire; actions=0", in: app)
        target.press(forDuration: 0.55)
        XCTAssertTrue(fire.waitForExistence(timeout: 5))
        XCTAssertEqual(fire.value as? String, "Seleccionada")
        attach(app.screenshot(), name: "chat-reaction-fire-confirmed")

        // Tapping the already confirmed emoji asks the server to remove it.
        fire.tap()
        waitForReactionState("requests=3; confirmations=1; pending=none; confirmed=fire; actions=0", in: app)
        dismissReactionPicker(in: app)
        app.buttons["fixture.reaction.confirm"].tap()
        waitForReactionState("requests=3; confirmations=2; pending=idle; confirmed=none; actions=0", in: app)
        app.scrollViews["chat.history"].swipeDown()
        XCTAssertTrue(app.buttons["chat.latest"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.reaction.heart"].exists, "A drag on a reaction-enabled row must remain a scroll")
        waitForReactionState("requests=3; confirmations=2; pending=idle; confirmed=none; actions=0", in: app)
    }

    @MainActor
    func testCopyClosesReactionMenuWithoutRequestingReactionOrOpeningMessage() {
        continueAfterFailure = false
        let app = launchFixture(reactions: true)
        defer { attachDiagnostics(in: app, name: "chat-reaction-copy") }
        let target = reactionTarget(in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        waitUntilHittable(target)
        target.press(forDuration: 0.55)
        let copy = app.buttons["chat.reaction.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["chat.reaction.heart"].exists)
        waitForReactionState("requests=0; confirmations=0; pending=idle; confirmed=none; actions=0", in: app)

        // A closed menu must release its owner so the same message can reopen it.
        target.press(forDuration: 0.55)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let field = app.descendants(matching: .any).matching(identifier: "chat.message").firstMatch
        // The outer backdrop must consume the first tap even over the composer.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    @MainActor
    func testDoubleTapWithKeyboardRequestsHeartWithoutOpeningAndPreservesDraft() {
        continueAfterFailure = false
        let app = launchFixture(reactions: true)
        defer { attachDiagnostics(in: app, name: "chat-reaction-double-tap") }
        let field = app.descendants(matching: .any).matching(identifier: "chat.message").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText("Mi borrador")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let target = reactionTarget(in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        attachDiagnostics(in: app, name: "chat-reaction-before-double-keyboard")
        waitUntilHittable(target)
        let window = app.windows.firstMatch
        let keyboard = app.keyboards.firstMatch
        let bounds = window.frame
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = min(keyboard.frame.minY, field.frame.minY)
        let historyAboveKeyboard = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
        let visibleTarget = target.frame.intersection(historyAboveKeyboard)
        XCTAssertFalse(visibleTarget.isNull)
        XCTAssertGreaterThan(visibleTarget.width, 1)
        XCTAssertGreaterThan(visibleTarget.height, 1)
        let point = CGPoint(x: visibleTarget.midX, y: visibleTarget.midY)
        XCTAssertTrue(target.frame.contains(point))
        XCTAssertFalse(keyboard.frame.contains(point))
        let pointAttachment = XCTAttachment(string: "Window=\(bounds); target=\(target.frame); keyboard=\(keyboard.frame); " +
                                            "visibleTarget=\(visibleTarget); doubleTapPoint=\(point)")
        pointAttachment.name = "chat-reaction-double-tap-visible-point"; pointAttachment.lifetime = .keepAlways
        add(pointAttachment)
        // Coordinate taps cannot auto-scroll the element into view or close the
        // keyboard before the first touch, unlike an element-based interaction.
        XCTAssertTrue(keyboard.exists, "Both touches must start with the keyboard still presented")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - bounds.minX, dy: point.y - bounds.minY)).doubleTap()
        waitForReactionState("requests=1; confirmations=0; pending=heart; confirmed=none; actions=0", in: app)
        waitForKeyboardToClose(in: app)
        XCTAssertEqual(field.value as? String, "Mi borrador")
        XCTAssertFalse(app.buttons["chat.reaction.heart"].exists,
                       "Double tap must wait for server confirmation before showing the selected bubble")
        app.buttons["fixture.reaction.confirm"].tap()
        let heart = app.buttons["chat.reaction.heart"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        XCTAssertEqual(heart.value as? String, "Seleccionada")
        waitForReactionState("requests=1; confirmations=1; pending=idle; confirmed=heart; actions=0", in: app)
        attach(app.screenshot(), name: "chat-reaction-double-heart-confirmed-draft-preserved")
        dismissReactionPicker(in: app)
        waitUntilHittable(target)
        target.tap()
        waitForReactionState("requests=1; confirmations=1; pending=idle; confirmed=heart; actions=1", in: app)
        XCTAssertEqual(field.value as? String, "Mi borrador")
        XCTAssertFalse(app.buttons["chat.reaction.heart"].exists,
                       "A single tap must preserve the card's own opening action")
    }

    @MainActor
    func testReactionWrapperPreservesNativeChildButtonAndScrolling() {
        continueAfterFailure = false
        let app = launchFixture(reactions: true, nativeChildren: true)
        defer { attachDiagnostics(in: app, name: "chat-reaction-native-child") }
        let child = app.buttons["fixture.reaction.native-action"]
        attachDiagnostics(in: app, name: "chat-reaction-before-native-child")
        XCTAssertTrue(child.waitForExistence(timeout: 15))
        waitUntilHittable(child)
        child.tap()
        waitForReactionState("requests=0; confirmations=0; pending=idle; confirmed=none; actions=1", in: app)
        XCTAssertFalse(app.buttons["chat.reaction.heart"].exists)
        let heading = app.staticTexts["fixture.message.29"]
        waitUntilHittable(heading)
        heading.press(forDuration: 0.55)
        XCTAssertTrue(app.buttons["chat.reaction.heart"].waitForExistence(timeout: 5))
        attach(app.screenshot(), name: "chat-reaction-native-child-long-press")
        dismissReactionPicker(in: app)
        waitUntilHittable(heading)
        let field = app.descendants(matching: .any).matching(identifier: "chat.message").firstMatch
        let distance = min(120, field.frame.minY - heading.frame.midY - 24)
        XCTAssertGreaterThan(distance, 30, "The drag must stay in visible history above the composer")
        let start = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        XCTAssertTrue(app.buttons["chat.latest"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.reaction.heart"].exists)
        waitForReactionState("requests=0; confirmations=0; pending=idle; confirmed=none; actions=1", in: app)
        attach(app.screenshot(), name: "chat-reaction-native-child-scroll-preserved")
    }

    @MainActor
    private func launchFixture(reactions: Bool = false, nativeChildren: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es)", "-AppleLocale", "es_AR",
                               "-pairnotes-chat-interaction-fixture"]
        if reactions { app.launchArguments.append("-pairnotes-chat-reaction-enabled") }
        if nativeChildren { app.launchArguments.append("-pairnotes-chat-reaction-children") }
        app.launch()
        return app
    }

    private func reactionTarget(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.reaction.target.fixture.29").firstMatch
    }

    private func waitForReactionState(_ value: String, in app: XCUIApplication) {
        let state = app.staticTexts["fixture.reaction.state"]
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 5), .completed)
    }

    @MainActor
    private func dismissReactionPicker(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        // Outside both menu panels, in the conversation's empty left margin.
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 5, dy: window.frame.height / 2)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                              object: app.buttons["chat.reaction.heart"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor
    private func tapVisibleHistorySpace(in app: XCUIApplication, history: XCUIElement, composer: XCUIElement) {
        let window = app.windows.firstMatch
        let bounds = window.frame
        let area = history.frame.intersection(bounds)
        let navigation = app.navigationBars.firstMatch
        let top = max(area.minY, navigation.exists ? navigation.frame.maxY : bounds.minY)
        var bottom = min(area.maxY, composer.frame.minY)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        XCTAssertGreaterThan(bottom - top, 40, "The tap must land in visible history, above both composer and keyboard")
        // ScrollView's AX frame includes content underneath safe-area insets.
        // Use an actual window point in the empty left margin of visible rows.
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: area.minX - bounds.minX + 16,
                                 dy: (top + bottom) / 2 - bounds.minY)).tap()
    }

    @MainActor
    private func attachDiagnostics(in app: XCUIApplication, name: String) {
        attach(app.screenshot(), name: name + "-screen")
        let field = app.descendants(matching: .any).matching(identifier: "chat.message").firstMatch
        let geometry = app.staticTexts["fixture.geometry"]
        let text = "Window: \(describeFrame(app.windows.firstMatch))\nHistory: \(describeFrame(app.scrollViews["chat.history"]))\n" +
            "Composer: \(describeFrame(field))\nKeyboard: \(describeFrame(app.keyboards.firstMatch))\n" +
            "Geometry: \(geometry.exists ? geometry.label : "not exposed")\n\(app.debugDescription)"
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func describeFrame(_ element: XCUIElement) -> String {
        element.exists ? String(describing: element.frame) : "not present"
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
