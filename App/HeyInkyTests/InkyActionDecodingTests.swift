import Foundation
import Testing
@testable import HeyInky

@Suite("InkyAction decoding")
struct InkyActionDecodingTests {
    @Test func decodesEveryActionTypeFromSharedFixture() throws {
        let response = try Fixtures.response("all_actions")
        #expect(response.actions.map(\.type) == InkyActionType.allCases)
    }

    @Test func decodesFieldsExactly() throws {
        let actions = try Fixtures.response("all_actions").actions
        guard case .highlight(let h) = actions[0] else { Issue.record("expected highlight"); return }
        #expect(h.region == NormRect(x: 0.08, y: 0.05, width: 0.84, height: 0.07))
        #expect(h.color == .yellow)
        #expect(h.note == "Title")

        guard case .label(let l) = actions[3] else { Issue.record("expected label"); return }
        #expect(l.text == "Rate-limiting step")
        #expect(l.arrow)

        guard case .insertMoleculeCard(let m) = actions[5] else { Issue.record("expected molecule"); return }
        #expect(m.smiles == "CC(=O)O")
        #expect(m.highlightGroups == ["C(=O)[OH]"])

        guard case .insertGraphCard(let g) = actions[6] else { Issue.record("expected graph"); return }
        #expect(g.spec.params.map(\.name) == ["a", "b"])
        #expect(g.spec.params[1].step == nil)
        #expect(g.spec.asymptotes.first?.orientation == .horizontal)

        guard case .draw(let d) = actions[7] else { Issue.record("expected draw"); return }
        #expect(d.ink == .pen && d.color == .indigo)
        #expect(d.shapes.map(\.kind) == [.line, .text, .curvedArrow])
        #expect(d.shapes[1].text == "H" && d.shapes[1].size == .small)
        #expect(d.shapes[0].text == nil)

        guard case .addPage(let p) = actions[8] else { Issue.record("expected addPage"); return }
        #expect(p.paper == .grid)

        guard case .openSidebar(let s) = actions[9] else { Issue.record("expected sidebar"); return }
        #expect(s.speakable)
        #expect(s.markdown.hasPrefix("# Entropy"))
    }

    @Test func nullOptionalsDecodeAsNil() throws {
        let response = try Fixtures.response("highlight_title")
        guard case .highlight(let h) = response.actions.first else { Issue.record("expected highlight"); return }
        #expect(h.note == nil)
    }

    @Test func unknownTypeIsRejected() throws {
        #expect(throws: DecodingError.self) {
            try Fixtures.response("invalid_unknown_type")
        }
    }

    @Test func missingRequiredFieldIsRejected() {
        let json = #"{"actions":[{"type":"star"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(InkyResponse.self, from: Data(json.utf8))
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let original = try Fixtures.response("all_actions")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InkyResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test func pageAnnotationClassification() throws {
        let types = try Fixtures.response("all_actions").actions.filter(\.isPageAnnotation).map(\.type)
        #expect(types == [.highlight, .circle, .star, .label, .fillText, .insertMoleculeCard, .insertGraphCard, .draw])
    }

    @Test func normRectHelpers() {
        let r = NormRect(x: 0.9, y: -0.1, width: 0.3, height: 0.5)
        let c = r.clamped
        #expect(c.x == 0.9 && c.y == 0 && abs(c.width - 0.1) < 1e-9 && c.height == 0.5)
        let a = NormRect(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(a.intersectionOverUnion(a) == 1)
        #expect(a.intersectionOverUnion(NormRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)) == 0)
        #expect(a.contains(NormPoint(x: 0.25, y: 0.25)))
    }
}
