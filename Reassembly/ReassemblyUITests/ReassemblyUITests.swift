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
        // Vorige runs kunnen een navigatiestand achterlaten; start altijd op root.
        app.launchArguments += ["--reset-navigation"]

        // Sta de Photos-dialoog toe zodra die de app onderbreekt.
        addUIInterruptionMonitor(withDescription: "Photos-toegang") { alert in
            let allow = alert.buttons["Allow Full Access"]
            if allow.exists { allow.tap(); return true }
            return false
        }

        app.launch()
        grantPhotosIfNeeded(app)

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15),
                      "Projectenlijst niet geladen — Photos-toegang niet verkregen?")

        let suffix = "\(ProcessInfo.processInfo.processIdentifier)"
        let folderName = "UITestKlant-\(suffix)"
        let albumName = "UITestProject-\(suffix)"

        // 1. Folder aanmaken via de lege-staat-knop → opent automatisch.
        createItem(app, buttonLabel: "New Folder", name: folderName)
        XCTAssertTrue(app.staticTexts["Empty Folder"].waitForExistence(timeout: 5),
                      "Nieuwe folder opende niet automatisch")

        // 2. Album erin aanmaken → opent automatisch (AlbumView).
        createItem(app, buttonLabel: "New Album", name: albumName)
        XCTAssertTrue(app.staticTexts["No Photos Yet"].waitForExistence(timeout: 5),
                      "Nieuw album opende niet automatisch")

        // 3. Herstel: app killen en koud herstarten → zelfde album weer open.
        app.terminate()
        app.launchArguments = []   // géén reset-vlag: nu moet herstel juist werken
        app.launch()
        XCTAssertTrue(app.staticTexts["No Photos Yet"].waitForExistence(timeout: 10),
                      "Navigatiepad niet hersteld na koude herstart")

        // 4. Album hernoemen via het titelmenu in de navigatiebalk.
        let renamedAlbum = albumName + "-titel"
        let titleMenu = app.buttons["titleMenu"]
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 5), "Titelmenu niet gevonden")
        titleMenu.tap()
        app.buttons["Rename"].tap()
        let albumField = app.alerts["Rename"].textFields.element
        XCTAssertTrue(albumField.waitForExistence(timeout: 5))
        albumField.clearText()
        albumField.typeText(renamedAlbum)
        app.alerts["Rename"].buttons["Save"].tap()

        // 5. De titel in de balk beweegt mee.
        let renamedTitle = app.buttons.matching(NSPredicate(
            format: "identifier == 'titleMenu' AND label CONTAINS %@", renamedAlbum)).firstMatch
        XCTAssertTrue(renamedTitle.waitForExistence(timeout: 5),
                      "Albumtitel niet ververst na hernoemen via titelmenu")

        // 6. Terug naar folderniveau, dan naar root.
        goBack(app)
        goBack(app)

        // 7. Root toont de folder met "1 album" — de telling-refresh.
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 5),
                      "Folder niet zichtbaar op root")
        XCTAssertTrue(app.staticTexts["1 album"].waitForExistence(timeout: 5),
                      "Folder-telling niet ververst (bug: bleef leeg)")

        // 8. Hernoemen via leading swipe.
        let newName = folderName + "-hernoemd"
        app.staticTexts[folderName].swipeRight()
        app.buttons["Rename"].tap()
        let field = app.alerts["Rename"].textFields.element
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearText()
        field.typeText(newName)
        app.alerts["Rename"].buttons["Save"].tap()

        // 9. Naam beweegt mee — de rename-refresh.
        XCTAssertTrue(app.staticTexts[newName].waitForExistence(timeout: 5),
                      "Naam niet ververst na hernoemen")

        // 10. Opruimen: verwijderen + de systeem-bevestiging bevestigen.
        app.staticTexts[newName].swipeLeft()
        let deleteButton = app.buttons["Delete + Photos"]
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
        app.alerts.buttons["Create"].tap()
    }

    @MainActor
    private func grantPhotosIfNeeded(_ app: XCUIApplication) {
        // Op een verse (kloon)simulator is Photos notDetermined: gate → dialoog.
        let grant = app.buttons["Allow Access"]
        guard grant.waitForExistence(timeout: 10) else { return }
        grant.tap()

        // Dialoog afhandelen: springboard-knop direct tikken, en anders de app
        // aantikken om de interruption monitor te laten vuren. Blijven proberen
        // tot de lijst ("Add") verschijnt.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let toevoegen = app.buttons["Add"]
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
