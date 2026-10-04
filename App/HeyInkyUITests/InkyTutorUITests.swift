import XCTest

/// Inky as a tutor on the page: drawing on the student's structure, working on a new page,
/// explaining on the page instead of in a sidebar, and the Select tool (move, Ask Inky, make ink).
///
/// Mock client by default; `TEST_RUNNER_INKY_LIVE=1` (+ optional `TEST_RUNNER_INKY_MODEL`) runs the
/// real model through the proxy. `TEST_RUNNER_INKY_UI_SHOTS=<dir>` saves screenshots.
@MainActor
final class InkyTutorUITests: XCTestCase {
    var app: XCUIApplication!

    var isLive: Bool { ProcessInfo.processInfo.environment["INKY_LIVE"] == "1" }
    var answerTimeout: TimeInterval { isLive ? 120 : 20 }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: Drawing

    func testDrawsTheHiddenHydrogensOnTheStudentsStructure() throws {
        launch(scenario: "skeleton")
        openNotebook("Hydrogen practice")
        shot("hydrogens-0-structure")
        ask("draw in all the hidden hydrogens")
        waitForInky()

        let drawing = element("inky.annotation.draw")
        XCTAssertTrue(drawing.waitForExistence(timeout: 5), "Inky drew on the page")
        let hydrogens = drawing.label.components(separatedBy: ",").filter { $0.contains("H") }.count
        if isLive {
            // Methylcyclohexane: C7H14 (a drawing may group them, e.g. "H₂").
            XCTAssertGreaterThanOrEqual(hydrogens, 7, drawing.label)
        } else {
            XCTAssertGreaterThan(hydrogens, 0, drawing.label)
        }
        XCTAssertFalse(element("inky.sidebar").exists, "drew on the page, no sidebar")
        shot("hydrogens-1-drawn")
    }

    func testWorksItOutOnANewPage() throws {
        launch(scenario: "asymptotes")
        openNotebook("Lecture 9 – Rational functions")
        XCTAssertEqual(app.staticTexts["page.indicator"].label, "1 / 1")
        ask(isLive ? "work out the x- and y-intercepts step by step on a new page" : "work it out on a new page")
        waitForInky()
        XCTAssertTrue(waitUntil(timeout: 10) { self.app.staticTexts["page.indicator"].label == "2 / 2" }, "Inky added a page and moved there")
        XCTAssertTrue(element("inky.annotation.draw").waitForExistence(timeout: 5), "worked steps written on the new page")
        shot("newpage-1-work")
    }

    func testExplainsOnThePageNotInASidebar() throws {
        try XCTSkipUnless(isLive, "judges the real model's choice of format")
        launch()
        openNotebook("Welcome to Hey Inky")
        ask("explain why raising the temperature shifts this equilibrium to the left")
        waitForInky()
        let marks = ["highlight", "circle", "label", "draw", "star"].reduce(0) { count, type in
            count + app.descendants(matching: .any).matching(identifier: "inky.annotation.\(type)").count
        }
        XCTAssertGreaterThanOrEqual(marks, 2, "taught on the page")
        shot("explain-1-page")
    }

    // MARK: Select tool

    func testSelectToolMovesInkAndAsksInkyAboutIt() throws {
        launch(scenario: "skeleton")
        openNotebook("Hydrogen practice")
        selectTool()

        // Tap the ring's ink to select it.
        let canvas = app.scrollViews["page.canvas"]
        let page = pagePoint(canvas, 300.0 / 816 + 62.0 / 816, 380.0 / 1056)   // the ring's right edge
        page.tap()
        let box = element("select.box")
        XCTAssertTrue(box.waitForExistence(timeout: 5), "selection box")
        shot("select-1-selected")

        // Drag it somewhere else.
        let before = box.frame
        box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 120, dy: 80)))
        XCTAssertTrue(waitUntil(timeout: 5) { abs(box.frame.minX - before.minX - 120) < 25 }, "moved (\(before) → \(box.frame))")
        shot("select-2-moved")

        // Undo puts it back.
        app.navigationBars.buttons["Undo"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.element("select.box").exists == false || abs(self.element("select.box").frame.minX - before.minX) < 25 })

        // Select again and ask Inky about just that.
        selectTool()
        page.tap()
        XCTAssertTrue(element("select.askInky").waitForExistence(timeout: 5))
        element("select.askInky").tap()
        let field = element("inky.ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "ask card opened for the selection")
        field.tap()
        let ringFrame = page.screenPoint
        field.typeText("what is this?")
        app.buttons["inky.ask.send"].tap()
        waitForInky()
        if !isLive {
            // The mock highlights the region it was pointed at: the selection.
            let highlight = element("inky.annotation.highlight")
            XCTAssertTrue(highlight.waitForExistence(timeout: 5))
            XCTAssertTrue(highlight.frame.insetBy(dx: -20, dy: -20).contains(ringFrame), "Inky looked at the selected ring (\(highlight.frame))")
        }
        shot("select-3-asked")
    }

    func testMakeInkysDrawingMyInk() throws {
        launch(scenario: "skeleton")
        openNotebook("Hydrogen practice")
        ask("draw in all the hidden hydrogens")
        waitForInky()
        let drawing = element("inky.annotation.draw")
        XCTAssertTrue(drawing.waitForExistence(timeout: 5))

        selectTool()
        drawing.tap()
        let makeInk = element("select.makeInk")
        XCTAssertTrue(makeInk.waitForExistence(timeout: 5), "offered for Inky's drawings")
        makeInk.tap()
        // The bonds became ink; the "H"s stay as Inky's handwriting.
        XCTAssertTrue(waitUntil(timeout: 5) { !self.element("select.makeInk").exists })
        shot("makeink-1")
    }

    // MARK: Helpers

    private func launch(scenario: String? = nil) {
        app = XCUIApplication()
        var arguments = ["-InkyUITestReset", "YES", "-InkyMotionScale", "0.5"]
        if !isLive { arguments += ["-InkyUseMockClient", "YES"] }
        if isLive, let model = ProcessInfo.processInfo.environment["INKY_MODEL"], !model.isEmpty { arguments += ["-InkyModel", model] }
        if isLive, let effort = ProcessInfo.processInfo.environment["INKY_REASONING"], !effort.isEmpty { arguments += ["-InkyReasoning", effort] }
        if let scenario { arguments += ["-InkyUITestScenario", scenario] }
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

    /// Until the answer is in and Inky has finished drawing it.
    private func waitForInky() {
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout), "Inky answered")
        XCTAssertTrue(waitUntil(timeout: 30) { !self.element("inky.performer").exists }, "Inky finished drawing")
        sleep(1)
    }

    /// Our Select item in PencilKit's palette (labeled from its symbol).
    private func selectTool() {
        let item = app.buttons["lasso select"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Select in the tool picker")
        item.tap()
    }

    private func pagePoint(_ canvas: XCUIElement, _ x: Double, _ y: Double) -> XCUICoordinate {
        // The page is centered with a 24pt margin each side and 24pt from the top at fit zoom.
        let pageWidth = canvas.frame.width - 48
        let scale = pageWidth / 816
        return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24 + x * 816 * scale, dy: 24 + y * 1056 * scale))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
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
