import XCTest

/// End-to-end run of the real app in the iOS Simulator against the robot's real server code in simulator mode
/// (CI starts it on 127.0.0.1:8099 and passes the pairing PIN). Every step saves a screenshot.
///
/// Covers: finding the robot fails cleanly when nothing is advertised, typing an address with a port, pairing,
/// the live home page (status, 3D model with the face, readings, camera tile), opening the cover, search,
/// a part's live values, settings, the Drive tab, and the demo.
final class DORMEUITests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0
    private let env = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A clean start: forget remembered robots (UserDefaults argument domain).
        app.launchArguments += ["-robot.host", "", "-robot.lanIP", "", "-robot.remoteName", "", "-robot.remoteIP", ""]
        app.launch()
    }

    private func shot(_ name: String) {
        step += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%02d-%@", step, name)
        a.lifetime = .keepAlways
        add(a)
    }

    /// System alerts (Bluetooth, local network) are answered "Allow".
    private func allowAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Allow While Using App"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 1) { b.tap() }
        }
    }

    /// Waits for an element while answering any system alert that shows up in the meantime.
    private func appear(_ e: XCUIElement, _ timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if e.exists { return true }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["Allow", "OK", "Allow While Using App"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
            }
            _ = e.waitForExistence(timeout: 2)
        }
        return e.exists
    }

    private func text(containing s: String) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", s)).firstMatch
    }

    func testConnectPairAndExplore() throws {
        let host = env["DORME_SIM_HOST"] ?? "127.0.0.1:8099"
        let pin = try XCTUnwrap(env["DORME_SIM_PIN"], "CI passes the simulator's PIN as TEST_RUNNER_DORME_SIM_PIN")
        allowAlerts()
        shot("launch")

        // Nothing advertises _dorme._tcp here, so the search ends with "not found" and the address option.
        let more = app.buttons["More"]
        let ok = appear(more, 75)
        shot(ok ? "not-found" : "no-not-found-panel")
        XCTAssertTrue(ok, "the not-found panel with its menu never appeared")
        more.tap()
        app.buttons["Enter address"].tap()
        let field = app.textFields["connect.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + host)
        shot("address")
        app.buttons["Go"].tap()

        // Pairing: the robot shows a code; the label PIN also pairs.
        let code = app.textFields["pair.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 20), "pairing panel did not appear")
        shot("pairing")
        code.tap()
        code.typeText(pin)

        // Connected: the search bar, the model card and the readings.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        XCTAssertTrue(text(containing: " V").waitForExistence(timeout: 20), "battery reading never appeared")
        sleep(2)
        shot("home-connected")

        // Open the cover with the button and look inside.
        let coverButton = app.buttons["Hide cover"]
        if coverButton.waitForExistence(timeout: 3) {
            coverButton.tap()
            sleep(1)
            shot("home-inside")
            app.buttons["Show cover"].tap()
        }

        let battery = text(containing: " V")
        battery.swipeUp()                       // swipe on the readings, not the model (the model turns on drag)
        sleep(1)
        shot("home-lower")
        app.staticTexts["DORM-E"].firstMatch.swipeDown()
        search.swipeDown()

        // Search finds parts by everyday words.
        search.tap()
        search.typeText("motor")
        let m1 = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Motor M1'")).firstMatch
        XCTAssertTrue(m1.waitForExistence(timeout: 5), "search for 'motor' did not list motor M1")
        shot("search-motor")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "temperature")
        let pi = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Raspberry Pi'")).firstMatch
        XCTAssertTrue(pi.waitForExistence(timeout: 5), "search for 'temperature' did not list the Pi")
        pi.tap()
        XCTAssertTrue(app.navigationBars.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Raspberry Pi'")).firstMatch
                        .waitForExistence(timeout: 10), "the Pi's page did not open")
        sleep(2)
        shot("part-pi")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // leave search: iOS 26 shows a close (X) button next to the field, earlier systems "Cancel"
        let leave = app.buttons.matching(NSPredicate(format: "label IN {'Cancel', 'Close'}")).firstMatch
        if leave.waitForExistence(timeout: 3) { leave.tap() }
        XCTAssertTrue(appear(app.buttons["Settings"], 10), "home toolbar did not come back after search")

        // Settings.
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Remote access"].waitForExistence(timeout: 5))
        shot("settings")
        app.swipeUp()
        shot("settings-lower")
        app.swipeDown(velocity: .fast)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() } else { app.swipeDown(velocity: .fast) }

        // Drive tab.
        let drive = app.buttons["Drive"]
        if drive.waitForExistence(timeout: 5) {
            drive.tap()
            sleep(1)
            shot("drive")
            app.buttons["Robot"].tap()
        }
    }

    func testDemoMode() throws {
        allowAlerts()
        let more = app.buttons["More"]
        XCTAssertTrue(appear(more, 75))
        more.tap()
        app.buttons["Try the demo"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        shot("demo-home")
    }
}
