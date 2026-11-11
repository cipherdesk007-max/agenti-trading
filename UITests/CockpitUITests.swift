import XCTest

/// Test dell'interfaccia: premono davvero i pulsanti nel simulatore.
/// Verificano le protezioni che non si possono saltare: conferma del live,
/// conferma dell'HARD KILL, START/STOP coerenti con lo stato.
final class CockpitUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Tocca lo switch (a destra della riga, non sull'etichetta) finché non
    /// compare l'avviso: al primo avvio il simulatore può non essere pronto.
    @MainActor
    private func tapSwitchUntilAlert(_ element: XCUIElement, alert: XCUIElement) {
        for _ in 0..<3 {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            if alert.waitForExistence(timeout: 4) { return }
        }
    }

    @MainActor
    func testLiveRequiresConfirmationAndCancelKeepsPaper() {
        let app = XCUIApplication()
        app.launch()
        let toggle = app.switches["PAPER TRADING"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertEqual(toggle.value as? String, "1")
        let alert = app.alerts["PASSARE AL LIVE?"]
        tapSwitchUntilAlert(toggle, alert: alert)
        XCTAssertTrue(alert.exists, "Il live deve chiedere conferma")
        alert.buttons["ANNULLA"].tap()
        XCTAssertEqual(toggle.value as? String, "1", "Annullando si resta in paper")
    }

    @MainActor
    func testLiveWithWrongWordKeepsPaper() {
        let app = XCUIApplication()
        app.launch()
        let toggle = app.switches["PAPER TRADING"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        let alert = app.alerts["PASSARE AL LIVE?"]
        tapSwitchUntilAlert(toggle, alert: alert)
        XCTAssertTrue(alert.exists)
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("SI")
        alert.buttons["CONFERMA LIVE"].tap()
        XCTAssertEqual(toggle.value as? String, "1", "Senza la parola LIVE si resta in paper")
    }

    @MainActor
    func testCockpitShowsStopAndKillAsksConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-QSPreview"]
        app.launch()
        XCTAssertTrue(app.buttons["STOP"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["CONTROLLA ORA"].exists)
        XCTAssertFalse(app.buttons["START"].exists, "A motore acceso START non deve comparire")
        let kill = app.buttons["HARD KILL SWITCH"]
        var swipes = 0
        while !(kill.exists && kill.isHittable) && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(kill.isHittable)
        kill.tap()
        let alert = app.alerts["HARD KILL SWITCH"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "L'HARD KILL deve chiedere conferma")
        alert.buttons["ANNULLA"].tap()
        XCTAssertFalse(alert.exists)
    }
}
