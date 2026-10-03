import SwiftUI

/// What the RDKit engine (`chem-core.js`) returns for one `smiles` string. A reaction
/// ("A.B>>C") yields several molecules with the arrow after `arrowAfter` of them.
struct MoleculeAnalysis: Decodable, Sendable, Equatable {
    var ok: Bool
    var input: String
    var error: String?
    var molecules: [MoleculeDepiction]
    var arrowAfter: Int?
    var agents: [String]

    var isReaction: Bool { arrowAfter != nil }
}

/// One molecule: RDKit's 2D depiction (as drawable primitives in RDKit drawing space),
/// atom positions in the same space, and exact substructure matches.
struct MoleculeDepiction: Decodable, Sendable, Equatable {
    var input: String
    /// RDKit canonical SMILES.
    var smiles: String
    /// Hill formula without charge, e.g. "C2H3O2".
    var formula: String
    /// Net formal charge.
    var charge: Int
    var molWeight: Double?
    var inchiKey: String?
    /// Size of the depiction in RDKit drawing units (flexicanvas, fixed bond length).
    var width: CGFloat
    var height: CGFloat
    var bondLength: CGFloat
    var primitives: [Primitive]
    var atoms: [Atom]
    var bonds: [Bond]
    /// Library functional groups found by SMARTS (after supersession, overlapping matches merged).
    var groups: [GroupHit]
    /// Caller `highlightGroups` / `starGroups`, resolved and matched by RDKit.
    var highlights: [PatternHit]
    var stars: [PatternHit]
    var stereocenters: [Stereocenter]
    var stereobonds: [StereoBond]

    var size: CGSize { CGSize(width: width, height: height) }

    struct Atom: Decodable, Sendable, Equatable {
        var index: Int
        var symbol: String
        var x: CGFloat
        var y: CGFloat
        var charge: Int
        var hydrogens: Int
        var aromatic: Bool
        var point: CGPoint { CGPoint(x: x, y: y) }
    }

    struct Bond: Decodable, Sendable, Equatable {
        var index: Int
        var a: Int
        var b: Int
        var order: Int
    }

    struct Match: Decodable, Sendable, Equatable, Hashable {
        var atoms: [Int]
        var bonds: [Int]
        /// Library group that best explains a raw-SMARTS match (Jaccard ≥ 0.5), if any.
        var groupId: String?
    }

    struct GroupHit: Decodable, Sendable, Equatable {
        var id: String
        var name: String
        var matches: [Match]
    }

    struct PatternHit: Decodable, Sendable, Equatable {
        var pattern: String
        var valid: Bool
        /// Library groups this pattern names (or, for raw SMARTS, best explains).
        var groupIds: [String]
        var matches: [Match]
    }

    struct Stereocenter: Decodable, Sendable, Equatable {
        var atom: Int
        var label: String
    }

    struct StereoBond: Decodable, Sendable, Equatable {
        var a: Int
        var b: Int
        var label: String
    }

    /// A drawable piece of RDKit's SVG: a bond line, a wedge, or an atom-label glyph.
    struct Primitive: Decodable, Sendable, Equatable {
        enum Kind: Sendable, Equatable { case stroke, fill }
        var path: Path
        var kind: Kind
        var color: RGB
        var lineWidth: CGFloat
        var dashed: Bool
        /// Atom indices this primitive belongs to (from RDKit's `atom-N` classes).
        var atoms: [Int]
        /// Bond index (from RDKit's `bond-N` class), if this is part of a bond.
        var bond: Int?

        private enum CodingKeys: String, CodingKey { case d, cls, fill, stroke, lineWidth, dashed }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = SVGPath.parse(try c.decode(String.self, forKey: .d))
            let fill = try c.decodeIfPresent(String.self, forKey: .fill)
            let stroke = try c.decodeIfPresent(String.self, forKey: .stroke)
            // Wedges have both fill and a hairline stroke; atom glyphs only fill.
            kind = fill != nil ? .fill : .stroke
            color = RGB(hex: fill ?? stroke ?? "#000000")
            lineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 0
            dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false
            let classes = (try c.decodeIfPresent(String.self, forKey: .cls) ?? "").split(separator: " ")
            atoms = classes.compactMap { $0.hasPrefix("atom-") ? Int($0.dropFirst(5)) : nil }
            bond = classes.lazy.compactMap { $0.hasPrefix("bond-") ? Int($0.dropFirst(5)) : nil }.first
        }
    }
}

/// An sRGB color from RDKit's SVG.
struct RGB: Sendable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let v = UInt32(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }

    var isBlack: Bool { r < 0.05 && g < 0.05 && b < 0.05 }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}
