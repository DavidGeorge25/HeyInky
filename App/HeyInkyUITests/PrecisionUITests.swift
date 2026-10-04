import XCTest

/// Precise marks on recognized structures and Inky's typeset figures, on the seeded
/// "Organic structures" notebook (a hand-drawn acetaminophen image on grid paper).
///
/// Mock client by default; `TEST_RUNNER_INKY_LIVE=1` runs the same flows against the real proxy.
/// `TEST_RUNNER_INKY_UI_SHOTS=<dir>` saves a screenshot per step.
@MainActor
final class PrecisionUITests: XCTestCase {
    var app: XCUIApplication!

    var isLive: Bool { ProcessInfo.processInfo.environment["INKY_LIVE"] == "1" }
    var answerTimeout: TimeInterval { isLive ? 120 : 25 }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testHiddenHydrogensLandOnTheDrawing() throws {
        launch(scenario: "molecule")
        openNotebook("Organic structures")
        ask("add the hidden hydrogens")
        let drawing = element("inky.annotation.draw")
        XCTAssertTrue(drawing.waitForExistence(timeout: answerTimeout), "Inky drew on the structure")
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout), "Inky finished")
        XCTAssertTrue(drawing.label.contains("H"), drawing.label)
        sleep(isLive ? 9 : 5)  // let Inky finish drawing every stroke
        shot("hydrogens")
    }

    func testLonePairsAndAmideOnTheDrawing() throws {
        launch(scenario: "molecule")
        openNotebook("Organic structures")
        ask("show the lone pairs and highlight the amide")
        XCTAssertTrue(element("inky.annotation.draw").waitForExistence(timeout: answerTimeout), "Inky marked the structure")
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout))
        sleep(isLive ? 9 : 5)
        shot("lonepairs")
    }

    func testResonanceStructuresAreATypesetFigure() throws {
        launch(scenario: "molecule")
        openNotebook("Organic structures")
        ask(isLive ? "draw the resonance structures of the phenoxide ion" : "draw the resonance structures")
        let inserted = element("inky.annotation.insertChemScheme").waitForExistence(timeout: answerTimeout)
        if !inserted { shot("resonance-missing") }
        XCTAssertTrue(inserted, "scheme inserted")
        let drawn = element("inky.figure.chemScheme").waitForExistence(timeout: 30)
        shot("resonance-check")
        XCTAssertTrue(drawn, "scheme drawn")
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout))
        sleep(3)
        shot("resonance")
    }

    func testDiagramIsCheckedAndPlaced() throws {
        launch(scenario: "molecule")
        openNotebook("Organic structures")
        ask(isLive ? "draw me a labeled diagram of an animal cell" : "draw a diagram of a cell")
        XCTAssertTrue(element("inky.annotation.insertDiagram").waitForExistence(timeout: answerTimeout), "diagram inserted")
        XCTAssertTrue(element("inky.figure.diagram").waitForExistence(timeout: 30), "diagram drawn")
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout))
        sleep(3)
        shot("diagram")
    }

    // MARK: Helpers

    private func launch(scenario: String) {
        app = XCUIApplication()
        var arguments = ["-InkyUITestReset", "YES", "-InkyUITestScenario", scenario]
        if !isLive { arguments += ["-InkyUseMockClient", "YES"] }
        if isLive, let model = ProcessInfo.processInfo.environment["INKY_MODEL"], !model.isEmpty {
            arguments += ["-InkyModel", model]
        }
        if let image = Bundle(for: Self.self).path(forResource: "acetaminophen_hand", ofType: "png") {
            arguments += ["-InkyUITestImage", image]
        }
        app.launchArguments = arguments
        app.launch()
    }

    private func openNotebook(_ title: String) {
        let notebook = app.buttons["library.notebook.\(title)"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 15), "\(title) in the library")
        notebook.tap()
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: 10))
    }

    private func ask(_ question: String) {
        app.buttons["inky.summon"].tap()
        let field = element("inky.ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(question)
        app.buttons["inky.ask.send"].tap()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["INKY_UI_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(isLive ? "live" : "mock")-\(name).png"))
        }
    }
}
