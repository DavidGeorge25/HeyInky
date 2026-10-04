import Foundation
import Testing
@testable import HeyInky

/// Guards against the Swift types drifting from /shared/inky_actions.schema.json.
/// If this fails after editing the schema, update InkyAction.swift to match (and vice versa).
@Suite("Schema ⇄ Swift sync")
struct InkyActionSchemaSyncTests {
    let schema = InkyPromptBuilder.actionSchema()

    var defs: [String: [String: Any]] {
        schema["$defs"] as? [String: [String: Any]] ?? [:]
    }

    func properties(_ def: String) -> Set<String> {
        Set(((defs[def]?["properties"]) as? [String: Any] ?? [:]).keys)
    }

    /// Encodes with every optional set, so all keys appear.
    func encodedKeys(_ action: InkyAction) throws -> Set<String> {
        let data = try JSONEncoder().encode(action)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Set(object.keys)
    }

    static let fullySpecified: [InkyAction] = [
        .highlight(HighlightAction(region: .unit, color: .green, note: "n")),
        .circle(CircleAction(region: .unit, style: .solid)),
        .star(StarAction(point: NormPoint(x: 0.5, y: 0.5))),
        .label(LabelAction(anchor: NormPoint(x: 0.5, y: 0.5), text: "t", arrow: true)),
        .fillText(FillTextAction(region: .unit, text: "t", handwritingStyle: false)),
        .insertMoleculeCard(InsertMoleculeCardAction(smiles: "C", near: .unit, highlightGroups: [], starGroups: [], caption: "c")),
        .insertGraphCard(InsertGraphCardAction(spec: GraphSpec(title: "t", xMin: 0, xMax: 1, yMin: 0, yMax: 1, xLabel: "x", yLabel: "y", functions: [], params: [], asymptotes: [], points: [], labels: []), near: .unit)),
        .draw(DrawAction(ink: .pen, color: .indigo, shapes: [.init(kind: .line, points: [], text: "t", size: .medium)], caption: "c")),
        .annotateStructure(AnnotateStructureAction(
            structure: "S1", relabel: [.init(atom: "a1", symbol: "O")], hydrogens: ["all"], lonePairs: [], charges: [.init(atom: "a1", text: "+")],
            highlights: [.init(atoms: ["a1"], group: "amide", color: .yellow, note: "n")], labels: [.init(atom: "a1", text: "t")],
            arrows: [.init(from: "a1", to: "a2-a3", kind: .curved)], color: .indigo)),
        .insertChemScheme(InsertChemSchemeAction(
            near: .unit, title: "t", steps: [.init(smiles: "C", label: "l")], connectors: [.init(kind: .resonance, above: "a", below: "b")],
            arrows: [.init(step: 0, from: "1", to: "2", kind: .fishhook)], lonePairs: [.init(step: 0, atom: "1")],
            highlights: [.init(step: 0, atoms: ["1"], color: .pink)], caption: "c")),
        .insertDiagram(InsertDiagramAction(near: .unit, title: "t", svg: "<svg/>", caption: "c")),
        .addPage(AddPageAction(paper: .grid)),
        .openSidebar(OpenSidebarAction(markdown: "m", speakable: true)),
        .say(SayAction(text: "s")),
    ]

    @Test func actionTypeNamesMatchSchema() {
        let refs = ((schema["properties"] as? [String: Any])?["actions"] as? [String: Any])?["items"] as? [String: Any]
        let anyOf = refs?["anyOf"] as? [[String: String]] ?? []
        let names = anyOf.compactMap { $0["$ref"]?.components(separatedBy: "/").last }
        #expect(names == InkyActionType.allCases.map(\.rawValue))
    }

    @Test(arguments: fullySpecified)
    func swiftKeysMatchSchemaProperties(_ action: InkyAction) throws {
        #expect(try encodedKeys(action) == properties(action.type.rawValue))
    }

    @Test func enumValuesMatchSchema() {
        func enumValues(_ def: String, _ property: String) -> [String] {
            ((defs[def]?["properties"] as? [String: Any])?[property] as? [String: Any])?["enum"] as? [String] ?? []
        }
        #expect(enumValues("highlight", "color") == HighlightColor.allCases.map(\.rawValue))
        #expect(enumValues("circle", "style") == CircleStyle.allCases.map(\.rawValue))
        #expect(enumValues("draw", "ink") == DrawAction.Ink.allCases.map(\.rawValue))
        #expect(enumValues("draw", "color") == DrawAction.Color.allCases.map(\.rawValue))
        #expect(enumValues("shape", "kind") == DrawAction.Shape.Kind.allCases.map(\.rawValue))
        #expect(enumValues("shape", "size") == DrawAction.Shape.Size.allCases.map(\.rawValue))
        #expect(enumValues("addPage", "paper") == AddPageAction.Paper.allCases.map(\.rawValue))
    }

    @Test func sharedPrimitivesMatch() throws {
        #expect(properties("region") == ["x", "y", "width", "height"])
        #expect(properties("point") == ["x", "y"])
        let shape = DrawAction.Shape(kind: .text, points: [], text: "t", size: .small)
        let shapeKeys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(shape)) as? [String: Any] ?? [:]).keys)
        #expect(shapeKeys == properties("shape"))
        let spec = GraphSpec(title: "t", xMin: 0, xMax: 1, yMin: 0, yMax: 1, xLabel: "x", yLabel: "y", functions: [], params: [], asymptotes: [], points: [], labels: [])
        let keys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any] ?? [:]).keys)
        #expect(keys == properties("graphSpec"))
        let graphProperties = defs["graphSpec"]?["properties"] as? [String: Any] ?? [:]
        let asymptoteItem = (graphProperties["asymptotes"] as? [String: Any])?["items"] as? [String: Any] ?? [:]
        let asymptote = GraphSpec.Asymptote(orientation: .oblique, value: 0, slope: 1, label: "l")
        let asymptoteKeys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(asymptote)) as? [String: Any] ?? [:]).keys)
        #expect(asymptoteKeys == Set((asymptoteItem["properties"] as? [String: Any] ?? [:]).keys))
        let orientations = ((asymptoteItem["properties"] as? [String: Any])?["orientation"] as? [String: Any])?["enum"] as? [String]
        #expect(orientations == ["vertical", "horizontal", "oblique"])
    }

    @Test func bundledSchemaIsAnObjectRoot() {
        #expect(schema["type"] as? String == "object")
        #expect(schema["$comment"] == nil, "OpenAI strict mode may reject unknown keywords")
    }
}
