import XCTest

/// Runs against a fresh temporary library seeded with the sample lecture page, using the
/// mock Inky client (no network).
@MainActor
final class HeyInkyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-InkyUITestReset", "YES", "-InkyUseMockClient", "YES"]
        app.launch()
    }

    private func openSampleNotebook() {
        let notebook = app.buttons["library.notebook.Welcome to Hey Inky"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 10), "sample notebook in library")
        notebook.tap()
        XCTAssertTrue(app.otherElements["page.canvas"].waitForExistence(timeout: 10) || app.scrollViews["page.canvas"].waitForExistence(timeout: 2))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func testSummonInkyWithMockClientShowsAnnotations() {
        openSampleNotebook()

        let summon = app.buttons["inky.summon"]
        XCTAssertTrue(summon.waitForExistence(timeout: 5))
        summon.tap()

        let field = element("inky.ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "ask popover appears")
        field.tap()
        field.typeText("highlight the title")
        app.buttons["inky.ask.send"].tap()

        // say() shows a short-lived toast; check it first.
        XCTAssertTrue(element("inky.toast").waitForExistence(timeout: 10), "say() toast shown")

        // Every annotation renderer shows up on the Inky layer.
        for type in ["highlight", "circle", "star", "label", "fillText"] {
            XCTAssertTrue(element("inky.annotation.\(type)").waitForExistence(timeout: 10), "\(type) annotation rendered")
        }
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: 5), "popover dismissed after answering")

        // Select the highlight and delete it individually.
        element("inky.annotation.highlight").tap()
        let delete = element("inky.selection.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(element("inky.annotation.highlight").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("inky.annotation.star").exists, "other annotations stay")
    }

    func testExplainOpensSidebarWithPlayButton() {
        openSampleNotebook()
        app.buttons["inky.summon"].tap()
        let field = element("inky.ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("explain this page")
        app.buttons["inky.ask.send"].tap()

        XCTAssertTrue(element("inky.sidebar").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["inky.sidebar.play"].exists)
        app.buttons["inky.sidebar.close"].tap()
        XCTAssertTrue(element("inky.sidebar").waitForNonExistence(timeout: 5))
    }

    func testCreateNotebookDrawAndAddPage() {
        app.buttons["library.add"].tap()
        app.buttons["New Notebook"].tap()
        app.buttons["Lined"].tap()

        let canvas = app.scrollViews["page.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        // Draw a stroke (the simulator draws with touch).
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)))

        app.buttons["notebook.add"].tap()
        app.buttons["New Page"].tap()
        app.buttons["notebook.addPage.grid"].tap()
        let indicator = app.staticTexts["page.indicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 5))
        XCTAssertEqual(indicator.label, "2 / 2")
    }
}
