//
//  ReassemblyScreenshots.swift
//  ReassemblyUITests
//
//  App Store screenshots. Not a test of behaviour: seeds the simulator via
//  `--seed-demo`, walks list → album → viewer and writes PNGs to the host
//  directory in `SHOT_DIR` (pass as `TEST_RUNNER_SHOT_DIR` to xcodebuild).
//  `SEED_DIR` (`TEST_RUNNER_SEED_DIR`) points at the demo photos. Skipped
//  when either is missing, so a plain test run never produces files.
//

import XCTest

final class ReassemblyScreenshots: XCTestCase {

    @MainActor
    func testTakeScreenshots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let shotDir = env["SHOT_DIR"], let seedDir = env["SEED_DIR"] else {
            throw XCTSkip("SHOT_DIR / SEED_DIR not set")
        }
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += ["--reset-navigation", "--seed-demo"]
        app.launchEnvironment["REASSEMBLY_SEED_DIR"] = seedDir
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            let allow = alert.buttons["Allow Full Access"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        app.launch()
        grantPhotosIfNeeded(app)

        // Seeding runs on first launch; wait for the last-created album to show up.
        let lastAlbum = app.staticTexts["Ecotap DC15"]
        XCTAssertTrue(lastAlbum.waitForExistence(timeout: 240), "Seed did not produce projects")
        // Let the thumbnails and the (seed-triggered) list refreshes settle.
        sleep(8)
        save(app, "1-projects", to: shotDir)

        app.staticTexts["Raw Striker"].firstMatch.tap()
        let cells = app.descendants(matching: .any).matching(identifier: "photoCell")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 20), "Album grid did not load")
        sleep(4)
        save(app, "2-album", to: shotDir)

        // Third cell: a portrait side view of the engine (the first two are landscape).
        cells.element(boundBy: 2).tap()
        sleep(3)
        save(app, "3-viewer", to: shotDir)
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String, to dir: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        XCTAssertNoThrow(try png.write(to: url), "Could not write \(url.path)")
    }

    @MainActor
    private func grantPhotosIfNeeded(_ app: XCUIApplication) {
        let grant = app.buttons["Allow Access"]
        guard grant.waitForExistence(timeout: 10) else { return }
        grant.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if app.buttons["Add"].exists || app.staticTexts["New Folder"].exists { return }
            let allow = springboard.buttons["Allow Full Access"]
            if allow.exists { allow.tap() } else { app.tap() }
            usleep(500_000)
        }
    }
}
