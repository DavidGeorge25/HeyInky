import Foundation
import CoreGraphics

// Swift mirror of /shared/inky_actions.schema.json (the source of truth).
// InkyActionSchemaSyncTests fails if the two drift apart: keep property names identical.

/// Rectangle in normalized page space. (0,0) top-left, (1,1) bottom-right.
struct NormRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let zero = NormRect(x: 0, y: 0, width: 0, height: 0)
    static let unit = NormRect(x: 0, y: 0, width: 1, height: 1)

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var center: NormPoint { NormPoint(x: x + width / 2, y: y + height / 2) }

    /// Clamped into the unit square with non-negative size.
    var clamped: NormRect {
        let cx = min(max(x, 0), 1)
        let cy = min(max(y, 0), 1)
        return NormRect(x: cx, y: cy, width: min(max(width, 0), 1 - cx), height: min(max(height, 0), 1 - cy))
    }

    func offsetBy(dx: Double, dy: Double) -> NormRect {
        NormRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    func insetBy(dx: Double, dy: Double) -> NormRect {
        NormRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    func intersectionOverUnion(_ other: NormRect) -> Double {
        let ix = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let iy = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        let inter = ix * iy
        let union = width * height + other.width * other.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Intersection area divided by this rect's area.
    func overlapFraction(with other: NormRect) -> Double {
        let ix = max(0, min(maxX, other.maxX) - max(minX, other.minX))
        let iy = max(0, min(maxY, other.maxY) - max(minY, other.minY))
        let area = width * height
        return area > 0 ? ix * iy / area : 0
    }

    func contains(_ p: NormPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    func cgRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect, in size: CGSize) {
        self.init(
            x: rect.minX / size.width,
            y: rect.minY / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }
}

struct NormPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    func cgPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    func offsetBy(dx: Double, dy: Double) -> NormPoint {
        NormPoint(x: x + dx, y: y + dy)
    }
}

/// Root object the model returns.
struct InkyResponse: Codable, Hashable, Sendable {
    /// Existing marks to delete ("undo that"). The model answers with the short ids it was
    /// shown ("m2"); `ValidatingInkyModelClient` rewrites them to annotation UUID strings.
    var removeAnnotations: [String]
    var actions: [InkyAction]

    init(removeAnnotations: [String] = [], actions: [InkyAction]) {
        self.removeAnnotations = removeAnnotations
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey { case removeAnnotations, actions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        removeAnnotations = try container.decodeIfPresent([String].self, forKey: .removeAnnotations) ?? []
        actions = try container.decode([InkyAction].self, forKey: .actions)
    }

    /// `removeAnnotations` as annotation ids (after the client resolved short ids).
    var removedAnnotationIDs: [UUID] { removeAnnotations.compactMap(UUID.init(uuidString:)) }
}

enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case yellow, green, blue, pink, orange
}

enum CircleStyle: String, Codable, CaseIterable, Sendable {
    case solid, dashed
}

struct HighlightAction: Codable, Hashable, Sendable {
    var region: NormRect
    var color: HighlightColor
    var note: String?
}

struct CircleAction: Codable, Hashable, Sendable {
    var region: NormRect
    var style: CircleStyle
}

struct StarAction: Codable, Hashable, Sendable {
    var point: NormPoint
}

struct LabelAction: Codable, Hashable, Sendable {
    var anchor: NormPoint
    var text: String
    var arrow: Bool
}

struct FillTextAction: Codable, Hashable, Sendable {
    var region: NormRect
    var text: String
    var handwritingStyle: Bool
}

struct InsertMoleculeCardAction: Codable, Hashable, Sendable {
    var smiles: String
    var near: NormRect
    /// SMARTS patterns to highlight.
    var highlightGroups: [String]
    /// SMARTS patterns to star.
    var starGroups: [String]
    var caption: String?
}

struct GraphSpec: Codable, Hashable, Sendable {
    struct Function: Codable, Hashable, Sendable {
        /// JavaScript math in `x` and param names, e.g. "a*Math.sin(b*x)".
        var expression: String
        var label: String?
        var color: String?
    }

    struct Param: Codable, Hashable, Sendable {
        var name: String
        var min: Double
        var max: Double
        var value: Double
        var step: Double?
    }

    enum Orientation: String, Codable, Hashable, Sendable {
        case vertical, horizontal, oblique
    }

    struct Asymptote: Codable, Hashable, Sendable {
        var orientation: Orientation
        /// x for vertical, y for horizontal, y-intercept for oblique.
        var value: Double
        /// Slope for oblique; nil otherwise.
        var slope: Double? = nil
        var label: String?
    }

    struct Point: Codable, Hashable, Sendable {
        var x: Double
        var y: Double
        var label: String?
        var draggable: Bool
    }

    struct Label: Codable, Hashable, Sendable {
        var x: Double
        var y: Double
        var text: String
    }

    var title: String?
    var xMin: Double
    var xMax: Double
    var yMin: Double
    var yMax: Double
    /// Axis labels (nil = "x" / "y" or the preset's).
    var xLabel: String? = nil
    var yLabel: String? = nil
    var functions: [Function]
    var params: [Param]
    var asymptotes: [Asymptote]
    var points: [Point]
    var labels: [Label]
}

struct InsertGraphCardAction: Codable, Hashable, Sendable {
    var spec: GraphSpec
    var near: NormRect
}

/// Inky draws with real ink: strokes and handwritten text, in normalized page coordinates.
struct DrawAction: Codable, Hashable, Sendable {
    enum Ink: String, Codable, CaseIterable, Sendable { case pen, marker, pencil }
    enum Color: String, Codable, CaseIterable, Sendable { case indigo, black, blue, red, green, orange, yellow, pink }

    struct Shape: Codable, Hashable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable {
            case line, dashedLine, arrow, doubleArrow, curvedArrow, polyline, polygon, ellipse, text
        }
        enum Size: String, Codable, CaseIterable, Sendable { case small, medium, large }

        var kind: Kind
        var points: [NormPoint]
        var text: String?
        var size: Size
    }

    var ink: Ink
    var color: Color
    var shapes: [Shape]
    var caption: String?
}

/// Marks on a structure recognized on the page (`PageStructure`), named by atom id. The app
/// computes the geometry (`StructureAnnotator`); the model only says what to add.
struct AnnotateStructureAction: Codable, Hashable, Sendable {
    struct Relabel: Codable, Hashable, Sendable {
        var atom: String
        var symbol: String
    }

    struct Charge: Codable, Hashable, Sendable {
        var atom: String
        var text: String
    }

    struct Highlight: Codable, Hashable, Sendable {
        var atoms: [String]
        /// Functional group name or SMARTS, matched by RDKit on the recognized molecule.
        var group: String?
        var color: HighlightColor
        var note: String?
    }

    struct AtomLabel: Codable, Hashable, Sendable {
        var atom: String
        var text: String
    }

    enum ArrowKind: String, Codable, CaseIterable, Sendable { case curved, fishhook }

    struct Arrow: Codable, Hashable, Sendable {
        /// Atom id (its lone pair) or bond "a3-a4".
        var from: String
        /// Atom id, or "a4-a7" (a bond, or the gap between two atoms).
        var to: String
        var kind: ArrowKind
    }

    var structure: String
    var relabel: [Relabel]
    /// Atom ids, or ["all"].
    var hydrogens: [String]
    /// Atom ids, or ["all"].
    var lonePairs: [String]
    var charges: [Charge]
    var highlights: [Highlight]
    var labels: [AtomLabel]
    var arrows: [Arrow]
    var color: DrawAction.Color
}

/// A typeset chemistry figure (RDKit structures in a row with connectors and electron arrows).
/// Atoms are referenced by SMILES atom-map numbers ("[O-:1]" → "1").
struct InsertChemSchemeAction: Codable, Hashable, Sendable {
    struct Step: Codable, Hashable, Sendable {
        var smiles: String
        var label: String?
    }

    enum ConnectorKind: String, Codable, CaseIterable, Sendable { case resonance, reaction, equilibrium, plus, none }

    struct Connector: Codable, Hashable, Sendable {
        var kind: ConnectorKind
        var above: String?
        var below: String?
    }

    struct Arrow: Codable, Hashable, Sendable {
        var step: Int
        var from: String
        var to: String
        var kind: AnnotateStructureAction.ArrowKind
    }

    struct LonePair: Codable, Hashable, Sendable {
        var step: Int
        var atom: String
    }

    struct Highlight: Codable, Hashable, Sendable {
        var step: Int
        var atoms: [String]
        var color: HighlightColor
    }

    var near: NormRect
    var title: String?
    var steps: [Step]
    var connectors: [Connector]
    var arrows: [Arrow]
    var lonePairs: [LonePair]
    var highlights: [Highlight]
    var caption: String?
}

/// A stylized figure written as SVG with Inky's style kit; rendered, checked and fitted by the app.
struct InsertDiagramAction: Codable, Hashable, Sendable {
    /// A part to name: the app lays out the label and a non-crossing leader line to (x, y).
    struct Callout: Codable, Hashable, Sendable {
        var text: String
        /// On the part, in SVG units.
        var x: Double
        var y: Double
    }

    var near: NormRect
    var title: String?
    var svg: String
    var callouts: [Callout]
    var caption: String?

    init(near: NormRect, title: String?, svg: String, callouts: [Callout] = [], caption: String?) {
        self.near = near
        self.title = title
        self.svg = svg
        self.callouts = callouts
        self.caption = caption
    }

    private enum CodingKeys: String, CodingKey { case near, title, svg, callouts, caption }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        near = try c.decode(NormRect.self, forKey: .near)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        svg = try c.decode(String.self, forKey: .svg)
        callouts = try c.decodeIfPresent([Callout].self, forKey: .callouts) ?? []
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
    }
}

/// A fresh page after the current one; the rest of the answer goes there.
struct AddPageAction: Codable, Hashable, Sendable {
    enum Paper: String, Codable, CaseIterable, Sendable { case blank, lined, grid, dotted }
    var paper: Paper
}

struct OpenSidebarAction: Codable, Hashable, Sendable {
    var markdown: String
    var speakable: Bool
}

struct SayAction: Codable, Hashable, Sendable {
    var text: String
}

/// The discriminator values, in schema order.
enum InkyActionType: String, Codable, CaseIterable, Sendable {
    case highlight, circle, star, label, fillText, insertMoleculeCard, insertGraphCard, draw
    case annotateStructure, insertChemScheme, insertDiagram, addPage, openSidebar, say
}

/// One thing Inky does. Encoded flat with a `type` discriminator, exactly as in the schema.
enum InkyAction: Hashable, Sendable {
    case highlight(HighlightAction)
    case circle(CircleAction)
    case star(StarAction)
    case label(LabelAction)
    case fillText(FillTextAction)
    case insertMoleculeCard(InsertMoleculeCardAction)
    case insertGraphCard(InsertGraphCardAction)
    case draw(DrawAction)
    case annotateStructure(AnnotateStructureAction)
    case insertChemScheme(InsertChemSchemeAction)
    case insertDiagram(InsertDiagramAction)
    case addPage(AddPageAction)
    case openSidebar(OpenSidebarAction)
    case say(SayAction)

    var type: InkyActionType {
        switch self {
        case .highlight: .highlight
        case .circle: .circle
        case .star: .star
        case .label: .label
        case .fillText: .fillText
        case .insertMoleculeCard: .insertMoleculeCard
        case .insertGraphCard: .insertGraphCard
        case .draw: .draw
        case .annotateStructure: .annotateStructure
        case .insertChemScheme: .insertChemScheme
        case .insertDiagram: .insertDiagram
        case .addPage: .addPage
        case .openSidebar: .openSidebar
        case .say: .say
        }
    }

    /// Actions that live on the page's Inky layer (everything except say/openSidebar/addPage).
    var isPageAnnotation: Bool {
        switch type {
        case .say, .openSidebar, .addPage: false
        default: true
        }
    }
}

extension InkyAction: Codable {
    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let type = InkyActionType(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown Inky action type '\(raw)'"
            )
        }
        switch type {
        case .highlight: self = .highlight(try HighlightAction(from: decoder))
        case .circle: self = .circle(try CircleAction(from: decoder))
        case .star: self = .star(try StarAction(from: decoder))
        case .label: self = .label(try LabelAction(from: decoder))
        case .fillText: self = .fillText(try FillTextAction(from: decoder))
        case .insertMoleculeCard: self = .insertMoleculeCard(try InsertMoleculeCardAction(from: decoder))
        case .insertGraphCard: self = .insertGraphCard(try InsertGraphCardAction(from: decoder))
        case .draw: self = .draw(try DrawAction(from: decoder))
        case .annotateStructure: self = .annotateStructure(try AnnotateStructureAction(from: decoder))
        case .insertChemScheme: self = .insertChemScheme(try InsertChemSchemeAction(from: decoder))
        case .insertDiagram: self = .insertDiagram(try InsertDiagramAction(from: decoder))
        case .addPage: self = .addPage(try AddPageAction(from: decoder))
        case .openSidebar: self = .openSidebar(try OpenSidebarAction(from: decoder))
        case .say: self = .say(try SayAction(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(type.rawValue, forKey: .type)
        switch self {
        case .highlight(let a): try a.encode(to: encoder)
        case .circle(let a): try a.encode(to: encoder)
        case .star(let a): try a.encode(to: encoder)
        case .label(let a): try a.encode(to: encoder)
        case .fillText(let a): try a.encode(to: encoder)
        case .insertMoleculeCard(let a): try a.encode(to: encoder)
        case .insertGraphCard(let a): try a.encode(to: encoder)
        case .draw(let a): try a.encode(to: encoder)
        case .annotateStructure(let a): try a.encode(to: encoder)
        case .insertChemScheme(let a): try a.encode(to: encoder)
        case .insertDiagram(let a): try a.encode(to: encoder)
        case .addPage(let a): try a.encode(to: encoder)
        case .openSidebar(let a): try a.encode(to: encoder)
        case .say(let a): try a.encode(to: encoder)
        }
    }
}
