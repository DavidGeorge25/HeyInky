import Foundation

/// A chemical structure the app recognized on the page (in a placed image, the student's ink or
/// a PDF figure), with exact atom positions. Inky refers to its atoms by id ("S1", "a3") and the
/// app does the geometry, so marks land precisely on the real drawing.
struct PageStructure: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case image, ink, pdf
    }

    struct Atom: Codable, Hashable, Sendable {
        /// "a1", "a2", … (left to right).
        var id: String
        /// Element symbol ("C", "O"), or "?" when the letters couldn't be read.
        var element: String
        /// The label as written ("OH", "NH2"); nil for an unlabeled skeletal carbon.
        var label: String?
        /// Atom center (label center for written atoms), normalized page coordinates.
        var point: NormPoint
        /// Where the written label sits.
        var labelBox: NormRect?
        /// Total hydrogens on the atom (from RDKit, or carbon valence when unverified).
        var hydrogens: Int
        /// Hydrogens written in the label ("OH" → 1).
        var writtenHydrogens: Int
        var charge: Int
        var aromatic: Bool
        /// The label was read with low confidence.
        var unsure: Bool

        /// Hydrogens implied but not drawn.
        var hiddenHydrogens: Int { max(0, hydrogens - writtenHydrogens) }
    }

    struct Bond: Codable, Hashable, Sendable {
        /// Atom indices.
        var a: Int
        var b: Int
        var order: Int
    }

    var id: String
    var source: Source
    /// Bounds of the drawing, normalized page coordinates.
    var region: NormRect
    /// RDKit canonical SMILES; nil when RDKit couldn't make a valid molecule of it.
    var smiles: String?
    /// Typical bond length on the page, in page points.
    var bondLength: Double
    var atoms: [Atom]
    var bonds: [Bond]

    func atomIndex(_ id: String) -> Int? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        if let i = atoms.firstIndex(where: { $0.id == key }) { return i }
        // Tolerate "3" or "A3".
        let digits = key.drop { !$0.isNumber }
        guard let n = Int(digits), n >= 1, n <= atoms.count else { return nil }
        return n - 1
    }

    func bondIndex(_ a: Int, _ b: Int) -> Int? {
        bonds.firstIndex { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }
    }

    func neighbors(of atom: Int) -> [Int] {
        bonds.compactMap { $0.a == atom ? $0.b : $0.b == atom ? $0.a : nil }
    }
}
