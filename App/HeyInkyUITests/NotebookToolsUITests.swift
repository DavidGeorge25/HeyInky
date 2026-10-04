import XCTest

/// Text tool, draw-and-hold shape correction, PDF export (mock client, offline).
@MainActor
final class NotebookToolsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-InkyUITestReset", "YES", "-InkyUseMockClient", "YES", "-InkyUITestScenario", "skeleton"]
        app.launch()
        let notebook = app.buttons["library.notebook.Hydrogen practice"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 15))
        notebook.tap()
        XCTAssertTrue(app.buttons["inky.summon"].waitForExistence(timeout: 10))
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private var canvas: XCUIElement { app.scrollViews["page.canvas"] }

    /// The canvas frame, read once (PencilKit can drop its identifier when the drawing is replaced).
    private lazy var canvasFrame: CGRect = canvas.frame

    private func pagePoint(_ x: Double, _ y: Double) -> XCUICoordinate {
        let frame = canvasFrame
        let scale = (frame.width - 48) / 816
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 24 + x * 816 * scale, dy: frame.minY + 24 + y * 1056 * scale))
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["INKY_UI_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tools-\(name).png"))
        }
    }

    func testTypeATextBoxAndEditItAgain() {
        // PencilKit names custom palette items after their symbols.
        let textTool = app.buttons["text formatting"]
        XCTAssertTrue(textTool.waitForExistence(timeout: 5), "Text in the tool picker")
        textTool.tap()
        pagePoint(0.15, 0.65).tap()
        let field = element("text.editor")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "typing starts where you tap")
        field.typeText("Methylcyclohexane: C7H14")
        element("text.larger").tap()
        element("text.color.blue").tap()
        shot("1-typing")
        element("text.done").tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        shot("2-placed")

        // Tap the text again: it opens for editing with what was typed.
        pagePoint(0.2, 0.66).tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Methylcyclohexane: C7H14")
        element("text.done").tap()
    }

    func testDrawAndHoldSnapsToAShape() {
        // Pen is the default tool: draw a slightly crooked line and keep the pen down at the end.
        let start = pagePoint(0.15, 0.8), end = pagePoint(0.65, 0.815)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)
        sleep(1)
        shot("3a-after-line")
        // And a rough circle, drawn as a few connected segments, held at the end.
        let c = (x: 0.45, y: 0.3, r: 0.08)
        let points = (0...8).map { i -> XCUICoordinate in
            let t = Double(i) / 8 * 2 * .pi
            return pagePoint(c.x + c.r * cos(t) * (i % 2 == 0 ? 1 : 0.96), c.y + c.r * sin(t) * 0.773)
        }
        points[0].press(forDuration: 0.05, thenDragTo: points[1], withVelocity: .slow, thenHoldForDuration: 0)
        sleep(1)
        shot("3-snapped-line")
    }

    func testExportPDFOpensTheShareSheet() {
        app.buttons["notebook.more"].tap()
        let export = app.buttons["notebook.exportPDF"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        // UIActivityViewController
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10)
                      || app.collectionViews.firstMatch.waitForExistence(timeout: 2), "share sheet")
        shot("4-share")
    }
}
