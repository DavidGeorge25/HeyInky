import Foundation

/// A functional group as the card shows it: one row in the group bar, one color, and every
/// place it occurs across the card's molecules. Atoms always come from RDKit matches.
struct DisplayGroup: Identifiable, Equatable, Sendable {
    struct Instance: Equatable, Hashable, Sendable {
        var molecule: Int
        var atoms: [Int]
        var bonds: [Int]
    }

    /// Library group id (e.g. "ester") or `pattern:<SMARTS>` for a caller pattern that no
    /// library group explains.
    var key: String
    var name: String
    /// Label drawn on the structure (compact, e.g. "2° alcohol").
    var shortName: String
    var description: String
    var instances: [Instance]

    var id: String { key }
    var tint: GroupPalette.Tint { GroupPalette.tint(for: key) }
    var isLibraryGroup: Bool { !key.hasPrefix(DisplayGroup.patternPrefix) }

    static let patternPrefix = "pattern:"
}

/// Turns an engine result + the action's `highlightGroups` / `starGroups` into what the card
/// draws, and turns user toggles back into pattern lists to persist on the action.
struct MoleculeGroups: Equatable, Sendable {
    /// Every group on the card, in library order (custom patterns last).
    var all: [DisplayGroup]
    var highlighted: Set<String>
    var starred: Set<String>
    /// Caller patterns RDKit could not parse (shown as a quiet note, never guessed at).
    var invalidPatterns: [String]

    /// `highlightGroups == ["none"]` means the user hid every highlight.
    static let noneSentinel = "none"

    init(analysis: MoleculeAnalysis, highlightGroups: [String], starGroups: [String], library: FunctionalGroupLibrary = .shared) {
        var groups: [String: DisplayGroup] = [:]
        for (m, molecule) in analysis.molecules.enumerated() {
            for hit in molecule.groups {
                let info = library.group(hit.id)
                var group = groups[hit.id] ?? DisplayGroup(key: hit.id, name: info?.name ?? hit.name, shortName: info?.short ?? info?.name ?? hit.name, description: info?.description ?? "", instances: [])
                group.instances += hit.matches.map { .init(molecule: m, atoms: $0.atoms, bonds: $0.bonds) }
                groups[hit.id] = group
            }
        }

        var invalid: [String] = []
        func keys(for patterns: [String], hits: (MoleculeDepiction) -> [MoleculeDepiction.PatternHit]) -> Set<String> {
            var keys = Set<String>()
            for (p, pattern) in patterns.enumerated() where pattern != Self.noneSentinel {
                let perMolecule = analysis.molecules.enumerated().compactMap { m, mol in
                    hits(mol).indices.contains(p) ? (m, hits(mol)[p]) : nil
                }
                if !perMolecule.isEmpty, perMolecule.allSatisfy({ !$0.1.valid }) {
                    if !invalid.contains(pattern) { invalid.append(pattern) }
                    continue
                }
                let matches = perMolecule.flatMap { m, hit in hit.matches.map { (m, $0) } }
                let named = perMolecule.flatMap { $0.1.groupIds }
                if !matches.isEmpty, matches.allSatisfy({ $0.1.groupId.map { groups[$0] != nil } ?? false }) {
                    // Every match is (part of) a library group: use the library's exact atoms and name.
                    matches.forEach { keys.insert($0.1.groupId!) }
                } else if matches.isEmpty, library.group(named.first ?? "") != nil {
                    // A named group the molecule doesn't contain: nothing to highlight.
                    continue
                } else if !matches.isEmpty {
                    let key = DisplayGroup.patternPrefix + pattern
                    let bestName = named.first.flatMap { library.group($0)?.name }
                    groups[key] = DisplayGroup(
                        key: key,
                        name: bestName ?? "Matched pattern",
                        shortName: bestName ?? "Match",
                        description: "Atoms matching the SMARTS pattern \(pattern).",
                        instances: matches.map { .init(molecule: $0.0, atoms: $0.1.atoms, bonds: $0.1.bonds) }
                    )
                    keys.insert(key)
                }
            }
            return keys
        }

        let highlightKeys = keys(for: highlightGroups) { $0.highlights }
        let starKeys = keys(for: starGroups) { $0.stars }
        all = groups.values.sorted { a, b in
            let ra = library.rank(of: a.key), rb = library.rank(of: b.key)
            return ra != rb ? ra < rb : a.key < b.key
        }
        if highlightGroups == [Self.noneSentinel] {
            highlighted = []
        } else if highlightGroups.isEmpty {
            highlighted = Set(all.filter(\.isLibraryGroup).map(\.key))
        } else {
            highlighted = highlightKeys
        }
        starred = starKeys
        invalidPatterns = invalid
    }

    func group(_ key: String) -> DisplayGroup? { all.first { $0.key == key } }

    /// Pattern strings to persist for a set of keys: library ids (the engine accepts them)
    /// or the original SMARTS for custom patterns.
    static func patterns(for keys: Set<String>, in all: [DisplayGroup]) -> [String] {
        all.filter { keys.contains($0.key) }.map { group in
            group.isLibraryGroup ? group.key : String(group.key.dropFirst(DisplayGroup.patternPrefix.count))
        }
    }

    /// `highlightGroups` for a new highlighted set. "All library groups" is stored as `[]`
    /// (the default for a fresh card) and "nothing" as `["none"]`.
    func highlightPatterns(for keys: Set<String>) -> [String] {
        if keys.isEmpty { return [Self.noneSentinel] }
        let library = Set(all.filter(\.isLibraryGroup).map(\.key))
        if keys == library { return [] }
        return Self.patterns(for: keys, in: all)
    }

    func starPatterns(for keys: Set<String>) -> [String] {
        Self.patterns(for: keys, in: all)
    }
}
