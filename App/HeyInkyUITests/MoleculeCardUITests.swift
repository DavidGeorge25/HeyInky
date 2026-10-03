import XCTest

/// Molecule card end to end with the mock client: "show me the molecule" inserts acetic acid
/// with `highlightGroups: ["C(=O)[OH]"]`. Set `TEST_RUNNER_INKY_UI_SCREENSHOTS=<dir>` to save
/// screenshots of each step for visual review.
@MainActor
final class MoleculeCardUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-InkyUITestReset", "YES", "-InkyUseMockClient", "YES"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func screenshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["INKY_UI_SCREENSHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func insertMoleculeCard() {
        let notebook = app.buttons["library.notebook.Welcome to Hey Inky"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 10))
        notebook.tap()
        let summon = app.buttons["inky.summon"]
        XCTAssertTrue(summon.waitForExistence(timeout: 10))
        summon.tap()
        let field = element("inky.ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("show me the molecule")
        app.buttons["inky.ask.send"].tap()
        XCTAssertTrue(element("inky.annotation.insertMoleculeCard").waitForExistence(timeout: 10), "molecule card inserted")
    }

    func testMoleculeCardRendersGroupsAndOpensKetcher() {
        insertMoleculeCard()
        // RDKit (bundled WASM) finishes: the group bar shows the acid the mock asked for.
        let acid = element("inky.molecule.group.carboxylicAcid")
        XCTAssertTrue(acid.waitForExistence(timeout: 20), "carboxylic acid chip from the RDKit match")
        XCTAssertTrue(element("inky.molecule.canvas").exists)
        screenshot("1-card")

        // Tap the chip: name + one-line description, with a star button.
        acid.tap()
        XCTAssertTrue(element("inky.molecule.groupInfo").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Carboxylic acid"].exists)
        let star = element("inky.molecule.star")
        XCTAssertTrue(star.exists)
        star.tap()
        XCTAssertTrue(element("inky.molecule.group.carboxylicAcid").waitForExistence(timeout: 5))
        XCTAssertEqual(element("inky.molecule.group.carboxylicAcid").label, "Carboxylic acid, highlighted, starred")
        screenshot("2-starred")

        // Labels toggle.
        let labels = element("inky.molecule.labels")
        XCTAssertEqual(labels.label, "Hide labels")
        labels.tap()
        XCTAssertEqual(element("inky.molecule.labels").label, "Show labels")

        // Edit opens the bundled Ketcher; it boots offline and Cancel returns to the card.
        element("inky.molecule.edit").tap()
        let done = app.buttons["inky.ketcher.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Ketcher sheet")
        let ready = NSPredicate(format: "isEnabled == true")
        expectation(for: ready, evaluatedWith: done)
        waitForExpectations(timeout: 40)
        screenshot("3-ketcher")
        app.buttons["inky.ketcher.cancel"].tap()
        XCTAssertTrue(element("inky.molecule.group.carboxylicAcid").waitForExistence(timeout: 10), "back on the card")
    }
}
