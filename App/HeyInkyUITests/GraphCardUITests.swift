import XCTest

/// Graph card end to end with the mock client ("plot …" inserts `a·sin(x)` with an `a` slider).
@MainActor
final class GraphCardUITests: XCTestCase {
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

    /// Saves a screenshot when `TEST_RUNNER_GRAPH_UI_SHOTS=<dir>` is set (for eyeballing layout).
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["GRAPH_UI_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func insertGraph() {
        let notebook = app.buttons["library.notebook.Welcome to Hey Inky"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 10))
        notebook.tap()
        let summon = app.buttons["inky.summon"]
        XCTAssertTrue(summon.waitForExistence(timeout: 10))
        summon.tap()
        let field = element("inky.ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("plot a sine wave")
        app.buttons["inky.ask.send"].tap()
        XCTAssertTrue(element("inky.annotation.insertGraphCard").waitForExistence(timeout: 10), "graph card inserted")
    }

    func testPlotInsertsInteractiveGraphCard() throws {
        insertGraph()
        XCTAssertTrue(app.sliders["inky.graph.param.a"].waitForExistence(timeout: 10), "card controls are accessible")
        // The board loads offline and the legend shows the model's expression.
        let chip = element("inky.graph.function.0")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertTrue((chip.value as? String)?.contains("sin") == true, "\(String(describing: chip.value))")
        sleep(1)
        shot("graph-1-inserted")

        // Slider: move a → the value label follows.
        let slider = app.sliders["inky.graph.param.a"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.9)
        let valueLabel = element("inky.graph.param.a.edit")
        XCTAssertTrue(valueLabel.label.contains("2.7") || valueLabel.label.contains("2.6") || valueLabel.label.contains("2.8"), valueLabel.label)

        // Tap the slider's name to edit its range.
        valueLabel.tap()
        let maxField = element("inky.graph.range.max")
        XCTAssertTrue(maxField.waitForExistence(timeout: 5))
        maxField.tap()
        maxField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        maxField.typeText("10")
        shot("graph-2-range-editor")
        element("inky.graph.range.done").tap()
        XCTAssertTrue(maxField.waitForNonExistence(timeout: 5))

        // Tap the curve's chip to edit its expression; an unknown name offers a slider.
        element("inky.graph.function.0").tap()
        let expression = element("inky.graph.expression")
        XCTAssertTrue(expression.waitForExistence(timeout: 5))
        let current = (expression.value as? String) ?? ""
        expression.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        expression.typeText("a*cos(k*x)")
        let addSlider = element("inky.graph.expression.addSlider")
        XCTAssertTrue(addSlider.waitForExistence(timeout: 5), "unknown k offers a slider")
        shot("graph-3-expression-error")
        addSlider.tap()
        XCTAssertTrue(app.sliders["inky.graph.param.k"].waitForExistence(timeout: 5))
        element("inky.graph.expression.done").tap()
        XCTAssertTrue(element("inky.graph.function.0").waitForExistence(timeout: 5))
        let edited = (element("inky.graph.function.0").value as? String) ?? ""
        XCTAssertEqual(edited, "a*cos(k*x)")
        sleep(1)
        shot("graph-4-edited")
    }

    func testPanningTheBoardKeepsTheCardInPlaceAndFlattenReplacesIt() throws {
        insertGraph()
        XCTAssertTrue(app.sliders["inky.graph.param.a"].waitForExistence(timeout: 10), "card controls are accessible")
        let card = element("inky.annotation.insertGraphCard")
        let before = card.frame
        let board = element("inky.graph.board")
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        sleep(1)
        let start = board.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        sleep(1)
        shot("graph-5-panned")
        XCTAssertEqual(card.frame.origin.x, before.origin.x, accuracy: 1, "panning the graph doesn't move the card")
        XCTAssertEqual(card.frame.origin.y, before.origin.y, accuracy: 1)

        // Flatten (needs a host that can place images; hidden otherwise).
        element("inky.graph.menu").tap()
        let flatten = app.buttons["Flatten into page"]
        XCTAssertTrue(flatten.waitForExistence(timeout: 3), "the Inky layer's host offers flatten")
        flatten.tap()
        let confirm = app.buttons["Flatten"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "card replaced by an image")
        sleep(1)
        shot("graph-6-flattened")
    }
}
