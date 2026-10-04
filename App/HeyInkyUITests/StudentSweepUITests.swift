import XCTest

/// A student's week across subjects, against the real model (`TEST_RUNNER_INKY_LIVE=1`, proxy
/// running) or the mock. Each flow saves a screenshot (`TEST_RUNNER_INKY_UI_SHOTS=<dir>`) for review.
@MainActor
final class StudentSweepUITests: XCTestCase {
    var app: XCUIApplication!
    var isLive: Bool { ProcessInfo.processInfo.environment["INKY_LIVE"] == "1" }
    var answerTimeout: TimeInterval { isLive ? 150 : 25 }

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(isLive, "The sweep reviews real answers; run with TEST_RUNNER_INKY_LIVE=1")
    }

    func testCheckMyAlgebra() throws {
        run(scenario: "algebra", notebook: "Algebra homework", ask: "check my work", shot: "algebra-check")
    }

    func testFreeBodyDiagram() throws {
        run(scenario: "physics", notebook: "Physics – Forces", ask: "draw the free-body diagram and find the acceleration", shot: "physics-fbd")
    }

    func testDiagramFromNotes() throws {
        run(scenario: "biology", notebook: "Bio – Cellular respiration", ask: "make me a diagram of the stages of cellular respiration", shot: "bio-diagram")
    }

    func testQuizFromNotes() throws {
        run(scenario: "biology", notebook: "Bio – Cellular respiration", ask: "quiz me on this", shot: "bio-quiz")
    }

    func testBalanceEquations() throws {
        run(scenario: "stoich", notebook: "Chem – Balancing equations", ask: "balance these neatly", shot: "chem-balance")
    }

    // MARK: Helpers

    private func run(scenario: String, notebook: String, ask question: String, shot name: String) {
        app = XCUIApplication()
        var arguments = ["-InkyUITestReset", "YES", "-InkyUITestScenario", scenario]
        if !isLive { arguments += ["-InkyUseMockClient", "YES"] }
        if let model = ProcessInfo.processInfo.environment["INKY_MODEL"], !model.isEmpty { arguments += ["-InkyModel", model] }
        app.launchArguments = arguments
        app.launch()
        let book = app.buttons["library.notebook.\(notebook)"]
        XCTAssertTrue(book.waitForExistence(timeout: 15), "\(notebook) in the library")
        book.tap()
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: 10))
        app.buttons["inky.summon"].tap()
        let field = app.descendants(matching: .any)["inky.ask.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(question)
        app.buttons["inky.ask.send"].tap()
        // Thinking, then Inky performs; wait until the button is back and the drawing is done.
        sleep(5)
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: answerTimeout), "Inky answered")
        sleep(14)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["INKY_UI_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sweep-\(name).png"))
        }
    }
}
