import PencilKit
import Testing
@testable import HeyInky

@MainActor
@Suite("Tool picker")
struct ToolPickerTests {
    @Test func erasesPixelsByDefaultAndOffersSelectAndInky() throws {
        // An old saved layout (object eraser) is forgotten once.
        UserDefaults.standard.removeObject(forKey: "HeyInkyToolPickerLayoutVersion")
        let host = InkyToolPickerHost()
        let eraser = try #require(host.picker.toolItems.compactMap { $0 as? PKToolPickerEraserItem }.first)
        // `.bitmap` comes back as iOS 26's fixed-width pixel eraser; either way not the object eraser.
        #expect(eraser.eraserTool.eraserType != .vector, "pixel eraser")
        let ids = host.picker.toolItems.map(\.identifier)
        #expect(ids.contains(InkyToolPickerHost.selectItemIdentifier))
        #expect(ids.contains(InkyToolPickerHost.inkyItemIdentifier))
        #expect(!host.picker.toolItems.contains { $0 is PKToolPickerLassoItem }, "our Select replaces PencilKit's lasso")
    }
}

