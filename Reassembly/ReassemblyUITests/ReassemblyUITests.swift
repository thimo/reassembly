//
//  ReassemblyUITests.swift
//  ReassemblyUITests
//
//  Test de projectenlijst-flows die niet in code te vangen zijn: aanmaken,
//  nesten, terug-navigeren met verse tellingen, en hernoemen. Vereist vooraf
//  toegekende Photos-toegang op de simulator.
//

import XCTest

final class ReassemblyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateNestNavigateAndRename() throws {
        let app = XCUIApplication()

        // Sta de Photos-dialoog toe zodra die de app onderbreekt.
        addUIInterruptionMonitor(withDescription: "Photos-toegang") { alert in
            let allow = alert.buttons["Allow Full Access"]
            if allow.exists { allow.tap(); return true }
            return false
        }

        app.launch()
        grantPhotosIfNeeded(app)

        let addButton = app.buttons["Toevoegen"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15),
                      "Projectenlijst niet geladen — Photos-toegang niet verkregen?")

        let suffix = "\(ProcessInfo.processInfo.processIdentifier)"
        let folderName = "UITestKlant-\(suffix)"
        let albumName = "UITestProject-\(suffix)"

        // 1. Folder aanmaken via de lege-staat-knop → opent automatisch.
        createItem(app, buttonLabel: "Nieuwe folder", name: folderName)
        XCTAssertTrue(app.staticTexts["Lege folder"].waitForExistence(timeout: 5),
                      "Nieuwe folder opende niet automatisch")

        // 2. Album erin aanmaken → opent automatisch (AlbumView).
        createItem(app, buttonLabel: "Nieuw album", name: albumName)
        XCTAssertTrue(app.staticTexts["Nog geen foto's"].waitForExistence(timeout: 5),
                      "Nieuw album opende niet automatisch")

        // 3. Terug naar folderniveau, dan naar root.
        goBack(app)
        goBack(app)

        // 4. Root toont de folder met "1 item" — de childCount-refresh.
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 5),
                      "Folder niet zichtbaar op root")
        XCTAssertTrue(app.staticTexts["1 item"].waitForExistence(timeout: 5),
                      "Folder-telling niet ververst (bug: bleef 0 items)")

        // 5. Hernoemen via leading swipe.
        let newName = folderName + "-hernoemd"
        app.staticTexts[folderName].swipeRight()
        app.buttons["Hernoem"].tap()
        let field = app.alerts["Hernoemen"].textFields.element
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearText()
        field.typeText(newName)
        app.alerts["Hernoemen"].buttons["Bewaar"].tap()

        // 6. Naam beweegt mee — de rename-refresh.
        XCTAssertTrue(app.staticTexts[newName].waitForExistence(timeout: 5),
                      "Naam niet ververst na hernoemen")

        // 7. Opruimen: verwijderen + de systeem-bevestiging bevestigen.
        app.staticTexts[newName].swipeLeft()
        let deleteButton = app.buttons["Verwijder + foto's"]
        if deleteButton.waitForExistence(timeout: 5) {
            deleteButton.tap()
        }
        // iOS vraagt bevestiging voor het verwijderen van album+folder.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirmDeadline = Date().addingTimeInterval(6)
        while Date() < confirmDeadline {
            let sb = springboard.buttons["Delete"]
            if sb.exists { sb.tap(); break }
            let inApp = app.alerts.buttons["Delete"]
            if inApp.exists { inApp.tap(); break }
            usleep(300_000)
        }
        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: app.staticTexts[newName])
        wait(for: [gone], timeout: 12)
    }

    // MARK: - Helpers

    @MainActor
    private func createItem(_ app: XCUIApplication, buttonLabel: String, name: String) {
        // Lege-staat-knop (geen "+"-menu openen → geen dubbele match).
        let button = app.buttons[buttonLabel].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Knop \(buttonLabel) niet gevonden")
        button.tap()
        let field = app.alerts.textFields.element
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Naam-veld niet gevonden")
        field.tap()
        field.typeText(name)
        app.alerts.buttons["Maak aan"].tap()
    }

    @MainActor
    private func grantPhotosIfNeeded(_ app: XCUIApplication) {
        // Op een verse (kloon)simulator is Photos notDetermined: gate → dialoog.
        let grant = app.buttons["Geef toegang"]
        guard grant.waitForExistence(timeout: 10) else { return }
        grant.tap()

        // Dialoog afhandelen: springboard-knop direct tikken, en anders de app
        // aantikken om de interruption monitor te laten vuren. Blijven proberen
        // tot de lijst ("Toevoegen") verschijnt.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let toevoegen = app.buttons["Toevoegen"]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if toevoegen.exists { return }
            let allow = springboard.buttons["Allow Full Access"]
            if allow.exists {
                allow.tap()
            } else {
                app.tap()
            }
            usleep(500_000)
        }
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Terugknop niet gevonden")
        back.tap()
    }
}

private extension XCUIElement {
    @MainActor
    func clearText() {
        guard let current = value as? String, !current.isEmpty else { return }
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
}
