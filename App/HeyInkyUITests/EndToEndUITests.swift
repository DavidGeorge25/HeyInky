import XCTest

/// End-to-end flows on seeded QA notebooks (`UITestScenarios`): handwritten molecule, PDF slide
/// with a function, worksheet with blank boxes, long explanation + read aloud, voice question,
/// undo / delete / hide and relaunch.
///
/// By default Inky is the mock client (offline, deterministic). With
/// `TEST_RUNNER_INKY_LIVE=1` the same tests go through the real proxy + OpenAI
/// (`cd proxy && npm start` first) and check the model's answers; `TEST_RUNNER_INKY_MODEL=<name>`
/// overrides the model.
/// `TEST_RUNNER_INKY_UI_SHOTS=<dir>` saves a screenshot per step.
@MainActor
final class EndToEndUITests: XCTestCase {
    var app: XCUIApplication!

    var isLive: Bool { ProcessInfo.processInfo.environment["INKY_LIVE"] == "1" }
    /// The real model needs a few seconds, plus Inky's drawing performance.
    var answerTimeout: TimeInterval { isLive ? 90 : 20 }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: Flows

    func testFunctionalGroupsOnAHandwrittenMolecule() throws {
        launch(scenario: "molecule")
        openNotebook("Organic structures")
        shot("molecule-0-page")
        ask("what functional groups are here?")

        let card = element("inky.annotation.insertMoleculeCard")
        XCTAssertTrue(card.waitForExistence(timeout: answerTimeout), "molecule card inserted")
        // RDKit recognizes the structure Inky read off the drawing: acetaminophen has a secondary
        // amide and a phenol on an aromatic ring, and the card highlights them.
        let amide = element("inky.molecule.group.amide2")
        let phenol = element("inky.molecule.group.phenol")
        XCTAssertTrue(amide.waitForExistence(timeout: 30), "amide chip")
        XCTAssertTrue(phenol.waitForExistence(timeout: 5), "phenol chip")
        XCTAssertTrue(element("inky.molecule.group.aromaticRing").exists, "aromatic ring detected")
        XCTAssertTrue(amide.label.contains("highlighted"), amide.label)
        XCTAssertTrue(phenol.label.contains("highlighted"), phenol.label)
        sleep(2)
        shot("molecule-1-card")
    }

    func testAsymptotesOnAPDFSlideWithWorkingSliders() throws {
        launch(scenario: "asymptotes")
        openNotebook("Lecture 9 – Rational functions")
        ask("label the asymptotes")
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout), "Inky answered")
        sleep(2)
        shot("asymptotes-0-answer")

        XCTAssertTrue(element("inky.annotation.insertGraphCard").waitForExistence(timeout: answerTimeout), "graph card inserted")
        let asymptotes = element("inky.graph.asymptotes")
        XCTAssertTrue(asymptotes.waitForExistence(timeout: 15), "asymptotes on the board")
        XCTAssertTrue(asymptotes.label.contains("x = 3"), asymptotes.label)
        XCTAssertTrue(asymptotes.label.contains("y = 2"), asymptotes.label)
        XCTAssertFalse((asymptotes.value as? String)?.hasPrefix("0 ") ?? true, "Inky labeled them (not only auto-detected)")
        sleep(2)
        shot("asymptotes-1-card")

        // Sliders work: moving one changes its value and the curve's asymptotes follow.
        let slider = app.sliders.matching(NSPredicate(format: "identifier BEGINSWITH 'inky.graph.param.'")).firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "the graph has a slider")
        let before = asymptotes.label
        let sliderValue = slider.value as? String
        slider.adjust(toNormalizedSliderPosition: 0.95)
        XCTAssertNotEqual(slider.value as? String, sliderValue, "slider value changed")
        let changed = NSPredicate(format: "label != %@", before)
        expectation(for: changed, evaluatedWith: element("inky.graph.asymptotes"))
        waitForExpectations(timeout: 10)
        if !isLive {
            XCTAssertFalse(element("inky.graph.asymptotes").label.contains("y = 2"), "stale asymptote removed: \(element("inky.graph.asymptotes").label)")
        }
        sleep(1)
        shot("asymptotes-2-slider")
    }

    func testWorksheetFillIn() throws {
        launch(scenario: "worksheet")
        openNotebook("Warm-up worksheet")
        ask("fill these in")

        let fills = app.descendants(matching: .any).matching(identifier: "inky.annotation.fillText")
        XCTAssertTrue(waitUntil(timeout: answerTimeout) { fills.count >= 4 }, "one answer per box (got \(fills.count))")
        sleep(isLive ? 4 : 2)   // let Inky finish writing
        XCTAssertEqual(fills.count, 4)
        let answers = fills.allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { $0.label.replacingOccurrences(of: "Inky text: ", with: "") }
        if isLive {
            let expected = ["56", "12", "12", "18"]
            for (answer, want) in zip(answers, expected) {
                XCTAssertTrue(answer.hasPrefix(want), "\(answers) vs \(expected)")
            }
        } else {
            XCTAssertEqual(answers, ["1", "2", "3", "4"], "the mock numbers the detected boxes top to bottom")
        }
        // Each answer sits to the right of its question, inside the box column.
        let canvas = app.scrollViews["page.canvas"]
        for fill in fills.allElementsBoundByIndex {
            XCTAssertGreaterThan(fill.frame.minX, canvas.frame.minX + canvas.frame.width * 0.3, "answer is in the box column")
        }
        shot("worksheet-1-filled")
    }

    func testLongExplanationOpensSidebarAndReadsAloud() throws {
        launch()
        openNotebook("Welcome to Hey Inky")
        ask("explain SN1 vs SN2")

        XCTAssertTrue(element("inky.sidebar").waitForExistence(timeout: answerTimeout), "sidebar opens")
        if isLive {
            let mentions = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'SN1' OR label CONTAINS 'SN2'"))
            XCTAssertGreaterThan(mentions.count, 0, "the explanation is about SN1/SN2")
        }
        let play = app.buttons["inky.sidebar.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { play.label == "Pause" }, "playing")
        // The synthesizer is actually speaking: its word progress moves.
        XCTAssertTrue(waitUntil(timeout: 15) { self.percentRead(play) > 0 }, "speech progresses (\(play.value ?? "-"))")
        shot("sidebar-1-reading")
        play.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { play.label == "Read aloud" }, "paused")
        app.buttons["inky.sidebar.close"].tap()
        XCTAssertTrue(element("inky.sidebar").waitForNonExistence(timeout: 5))
    }

    func testVoiceQuestion() throws {
        launch(extra: ["-InkyUITestSpeech", "highlight the title"])
        openNotebook("Welcome to Hey Inky")
        app.buttons["inky.summon"].tap()
        let mic = app.buttons["inky.ask.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.tap()

        let field = element("inky.ask.field")
        XCTAssertTrue(waitUntil(timeout: 10) { (field.value as? String) == "highlight the title" }, "transcript streams into the field (\(field.value ?? "-"))")
        shot("voice-1-transcript")
        mic.tap()   // stop listening
        app.buttons["inky.ask.send"].tap()

        let highlight = element("inky.annotation.highlight")
        XCTAssertTrue(highlight.waitForExistence(timeout: answerTimeout), "Inky answered the spoken question")
        sleep(2)
        shot("voice-2-answer")
    }

    func testUndoDeleteHideAndRelaunchPersists() throws {
        launch(library: "persistence")
        openNotebook("Welcome to Hey Inky")
        ask("highlight the title and star it")
        let highlight = element("inky.annotation.highlight")
        let star = element("inky.annotation.star")
        XCTAssertTrue(highlight.waitForExistence(timeout: answerTimeout))
        XCTAssertTrue(star.waitForExistence(timeout: answerTimeout))
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout), "Inky finished")

        // Toolbar Undo takes back the whole Inky turn; Redo brings it back.
        app.navigationBars.buttons["Undo"].tap()
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 5), "undo removes Inky's marks")
        XCTAssertFalse(star.exists)
        app.navigationBars.buttons["Redo"].tap()
        XCTAssertTrue(highlight.waitForExistence(timeout: 5), "redo restores them")
        XCTAssertTrue(star.waitForExistence(timeout: 5))

        // Delete one mark from the page.
        star.tap()
        let delete = element("inky.selection.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(star.waitForNonExistence(timeout: 5))

        // Hide the whole Inky layer.
        app.buttons["notebook.inkyLayer"].tap()
        let toggle = element("inkyLayer.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 5), "layer hidden")
        shot("persist-1-hidden")

        // Relaunch on the same library: still hidden, and the marks come back when shown.
        app.terminate()
        launch(library: "persistence", reset: false)
        openNotebook("Welcome to Hey Inky")
        XCTAssertFalse(highlight.waitForExistence(timeout: 3), "layer stays hidden after relaunch")
        app.buttons["notebook.inkyLayer"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(highlight.waitForExistence(timeout: 5), "marks persisted")
        XCTAssertFalse(star.exists, "the deleted star stays deleted")
        shot("persist-2-relaunched")
    }

    // MARK: Helpers

    private func launch(scenario: String? = nil, library: String? = nil, reset: Bool = true, extra: [String] = []) {
        app = XCUIApplication()
        var arguments: [String] = []
        if let library {
            arguments += ["-InkyUITestLibrary", library]
        }
        if reset { arguments += ["-InkyUITestReset", "YES"] }
        if !isLive { arguments += ["-InkyUseMockClient", "YES"] }
        // TEST_RUNNER_INKY_MODEL=gpt-5.4: try another model (e.g. when one hits its daily quota).
        if isLive, let model = ProcessInfo.processInfo.environment["INKY_MODEL"], !model.isEmpty {
            arguments += ["-InkyModel", model]
        }
        if let scenario {
            arguments += ["-InkyUITestScenario", scenario]
            if let image = Bundle(for: Self.self).path(forResource: "acetaminophen_hand", ofType: "png") {
                arguments += ["-InkyUITestImage", image]
            }
        }
        app.launchArguments = arguments + extra
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

    private func percentRead(_ play: XCUIElement) -> Int {
        Int((play.value as? String)?.split(separator: "%").first ?? "") ?? 0
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
