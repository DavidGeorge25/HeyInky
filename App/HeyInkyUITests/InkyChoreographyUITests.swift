import XCTest

/// Inky acting on the page with the mock client: for each annotation Inky hops to the target
/// region first, the annotation appears only once Inky draws it, and Inky celebrates and leaves
/// at the end. Runs at 1/3 speed (`-InkyMotionScale 3`) so each phase is long enough to observe.
@MainActor
final class InkyChoreographyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-InkyUITestReset", "YES", "-InkyUseMockClient", "YES", "-InkyMotionScale", "3"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Polls the performer's status ("hopping circle", "drawing circle", …) until it matches.
    @discardableResult
    private func waitForPerformer(_ status: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let performer = element("inky.performer")
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [String] = []
        while Date() < deadline {
            if performer.exists, let value = performer.value as? String {
                if seen.last != value { seen.append(value) }
                if value == status { return performer }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Inky never reached \"\(status)\"; saw \(seen)", file: file, line: line)
        return performer
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInkyHopsToEachTargetBeforeDrawingIt() {
        let notebook = app.buttons["library.notebook.Welcome to Hey Inky"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 10))
        notebook.tap()

        let summon = app.buttons["inky.summon"]
        XCTAssertTrue(summon.waitForExistence(timeout: 10))
        summon.tap()
        let field = element("inky.ask.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("highlight the title")
        app.buttons["inky.ask.send"].tap()

        // 1. Inky drops onto the page at the highlight's start; the highlight isn't there yet.
        waitForPerformer("entering highlight")
        XCTAssertFalse(element("inky.annotation.highlight").exists, "nothing drawn before Inky arrives")
        screenshot("1-entering")

        // 2. Drawing the highlight: it now exists and Inky's nib is on it.
        let performer = waitForPerformer("drawing highlight")
        let highlight = element("inky.annotation.highlight")
        XCTAssertTrue(highlight.waitForExistence(timeout: 2))
        let nib = CGPoint(x: performer.frame.midX, y: performer.frame.maxY)
        XCTAssertTrue(highlight.frame.insetBy(dx: -24, dy: -24).contains(nib),
                      "Inky's nib \(nib) is on the highlight \(highlight.frame)")
        screenshot("2-drawing-highlight")

        // 3. Hops to the circle before it appears, then draws it there.
        waitForPerformer("hopping circle")
        XCTAssertFalse(element("inky.annotation.circle").exists, "circle waits for Inky")
        screenshot("3-hopping")
        let drawingCircle = waitForPerformer("drawing circle")
        let circle = element("inky.annotation.circle")
        XCTAssertTrue(circle.waitForExistence(timeout: 2))
        let circleNib = CGPoint(x: drawingCircle.frame.midX, y: drawingCircle.frame.maxY)
        XCTAssertTrue(circle.frame.insetBy(dx: -30, dy: -30).contains(circleNib),
                      "Inky's nib \(circleNib) is on the circle \(circle.frame)")

        // 4. The rest in order, then a happy bounce and Inky's reply.
        for kind in ["star", "label", "fillText"] {
            waitForPerformer("hopping \(kind)", timeout: 20)
            XCTAssertFalse(element("inky.annotation.\(kind)").exists, "\(kind) waits for Inky")
            waitForPerformer("drawing \(kind)", timeout: 10)
            XCTAssertTrue(element("inky.annotation.\(kind)").exists)
        }
        waitForPerformer("celebrating", timeout: 15)
        screenshot("4-celebrating")
        XCTAssertTrue(element("inky.toast").waitForExistence(timeout: 5), "reply toast after drawing")

        // 5. Inky leaves the page; everything it drew stays.
        XCTAssertTrue(element("inky.performer").waitForNonExistence(timeout: 10))
        for kind in ["highlight", "circle", "star", "label", "fillText"] {
            XCTAssertTrue(element("inky.annotation.\(kind)").exists, "\(kind) stays on the page")
        }
    }
}
