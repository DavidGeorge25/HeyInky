import SwiftUI

/// The curated SMARTS library (`ChemistryWeb/functional-groups.json`), shared with the
/// RDKit engine. Swift only needs names, descriptions and display colors; matching always
/// happens in RDKit.
struct FunctionalGroupLibrary: Decodable, Sendable {
    struct Group: Decodable, Sendable, Identifiable, Equatable {
        var id: String
        var name: String
        /// Compact on-structure label ("2° alcohol"); defaults to `name`.
        var short: String?
        var description: String
        var smarts: [String]
        var core: [Int]?
        var supersedes: [String]?
    }

    var version: Int
    var groups: [Group]

    static let shared: FunctionalGroupLibrary = {
        guard let url = ChemistryWebResources.root?.appendingPathComponent("functional-groups.json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(FunctionalGroupLibrary.self, from: data) else {
            return FunctionalGroupLibrary(version: 0, groups: [])
        }
        return library
    }()

    func group(_ id: String) -> Group? { groups.first { $0.id == id } }

    /// Display order (the library's order: most specific first).
    func rank(of id: String) -> Int { groups.firstIndex { $0.id == id } ?? groups.count }
}

/// Soft, distinct highlight tints. Each group keeps the same color everywhere so students
/// learn "esters are peach". Dark variants are used for label text.
enum GroupPalette {
    struct Tint: Sendable, Equatable {
        var fill: RGB
        var ink: RGB
    }

    static let tints: [Tint] = [
        Tint(fill: RGB(r: 0.99, g: 0.76, b: 0.55), ink: RGB(r: 0.70, g: 0.38, b: 0.08)), // peach
        Tint(fill: RGB(r: 0.62, g: 0.80, b: 0.99), ink: RGB(r: 0.12, g: 0.40, b: 0.72)), // sky
        Tint(fill: RGB(r: 0.66, g: 0.90, b: 0.68), ink: RGB(r: 0.14, g: 0.50, b: 0.22)), // mint
        Tint(fill: RGB(r: 0.99, g: 0.70, b: 0.80), ink: RGB(r: 0.72, g: 0.18, b: 0.40)), // rose
        Tint(fill: RGB(r: 0.80, g: 0.74, b: 0.99), ink: RGB(r: 0.40, g: 0.28, b: 0.78)), // lavender
        Tint(fill: RGB(r: 0.99, g: 0.90, b: 0.50), ink: RGB(r: 0.58, g: 0.44, b: 0.00)), // butter
        Tint(fill: RGB(r: 0.58, g: 0.90, b: 0.90), ink: RGB(r: 0.05, g: 0.48, b: 0.50)), // aqua
        Tint(fill: RGB(r: 0.93, g: 0.74, b: 0.99), ink: RGB(r: 0.58, g: 0.22, b: 0.70)), // lilac
        Tint(fill: RGB(r: 0.85, g: 0.88, b: 0.60), ink: RGB(r: 0.40, g: 0.45, b: 0.05)), // olive
        Tint(fill: RGB(r: 0.99, g: 0.66, b: 0.62), ink: RGB(r: 0.75, g: 0.22, b: 0.16)), // coral
    ]

    static let fixed: [String: Int] = [
        "carboxylicAcid": 9, "ester": 0, "lactone": 0, "anhydride": 3, "acylHalide": 8,
        "amide1": 1, "amide2": 1, "amide3": 1, "lactam": 6,
        "aldehyde": 5, "ketone": 3,
        "alcohol1": 2, "alcohol2": 2, "alcohol3": 2, "phenol": 6, "hemiacetal": 7, "acetal": 4,
        "ether": 4, "epoxide": 7,
        "amine1": 4, "amine2": 4, "amine3": 4, "imine": 7, "nitrile": 8, "nitro": 9,
        "thiol": 5, "sulfide": 5, "sulfonamide": 8,
        "alkylHalide": 8, "arylHalide": 8, "alkene": 6, "alkyne": 1, "aromaticRing": 1,
    ]

    static func tint(for key: String) -> Tint {
        if let i = fixed[key] { return tints[i] }
        var hash: UInt32 = 2166136261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return tints[Int(hash % UInt32(tints.count))]
    }
}
