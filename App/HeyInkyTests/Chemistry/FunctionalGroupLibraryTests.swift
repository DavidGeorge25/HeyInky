import Foundation
import Testing
@testable import HeyInky

/// Known molecules → exact functional-group instances, matched by the real RDKit engine
/// against the bundled SMARTS library. Expected groups live in `known-molecules.json`.
struct KnownMolecule: Decodable, Sendable, CustomTestStringConvertible {
    var name: String
    var smiles: String
    var groups: [String: Int]
    var testDescription: String { name }

    static let all: [KnownMolecule] = {
        struct File: Decodable { var molecules: [KnownMolecule] }
        let bundle = Bundle(for: KnownMoleculesToken.self)
        guard let url = bundle.url(forResource: "known-molecules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.molecules
    }()
}

private final class KnownMoleculesToken {}

@MainActor
@Suite(.serialized)
struct FunctionalGroupLibraryTests {
    let library = FunctionalGroupLibrary.shared

    @Test func knownMoleculeSetIsLargeAndCoversEveryGroup() {
        #expect(KnownMolecule.all.count >= 40)
        let covered = Set(KnownMolecule.all.flatMap { $0.groups.keys })
        for group in library.groups {
            #expect(covered.contains(group.id), "no known molecule exercises \(group.id)")
        }
        // The molecules the brief names explicitly.
        for name in ["Aspirin", "Caffeine", "Ibuprofen", "β-D-Glucose", "Penicillin G"] {
            #expect(KnownMolecule.all.contains { $0.name == name }, "\(name) is in the set")
        }
    }

    @Test func libraryCoversTheRequiredGroupsAndIsWellFormed() {
        let required = ["alkene", "alkyne", "alcohol1", "alcohol2", "alcohol3", "phenol", "ether", "aldehyde", "ketone",
                        "carboxylicAcid", "ester", "amide1", "amide2", "amide3", "amine1", "amine2", "amine3", "nitrile",
                        "nitro", "acylHalide", "anhydride", "alkylHalide", "arylHalide", "thiol", "sulfide", "imine",
                        "epoxide", "aromaticRing", "lactone", "lactam", "acetal", "hemiacetal"]
        let ids = library.groups.map(\.id)
        #expect(Set(ids).count == ids.count, "ids are unique")
        for id in required { #expect(ids.contains(id), "library has \(id)") }
        for group in library.groups {
            #expect(!group.name.isEmpty && !group.description.isEmpty, "\(group.id) has a name and description")
            #expect(!group.smarts.isEmpty)
            for target in group.supersedes ?? [] { #expect(ids.contains(target), "\(group.id) supersedes a real group (\(target))") }
            #expect(GroupPalette.fixed[group.id] != nil, "\(group.id) has a fixed color")
        }
    }

    @Test(arguments: KnownMolecule.all)
    func findsExactlyTheExpectedGroups(_ molecule: KnownMolecule) async throws {
        let result = try await MoleculeEngine.shared.analyze(smiles: molecule.smiles)
        #expect(result.ok, "\(molecule.name) parses")
        let depiction = try #require(result.molecules.first)
        var found: [String: Int] = [:]
        for group in depiction.groups { found[group.id] = group.matches.count }
        #expect(found == molecule.groups, "\(molecule.name): found \(found), expected \(molecule.groups)")

        // Every highlighted atom/bond index is real, and bonds connect atoms of the same instance.
        for group in depiction.groups {
            for match in group.matches {
                #expect(match.atoms.allSatisfy { depiction.atoms.indices.contains($0) })
                for b in match.bonds {
                    let bond = depiction.bonds[b]
                    #expect(match.atoms.contains(bond.a) && match.atoms.contains(bond.b))
                }
            }
        }
    }

    @Test func highlightsAreTheExactSmartsAtoms() async throws {
        // Aspirin: CC(=O)Oc1ccccc1C(=O)O — ester core is C1, O2, O3; the acid is C10, O11, O12.
        let mol = try #require(try await MoleculeEngine.shared.analyze(smiles: "CC(=O)Oc1ccccc1C(=O)O").molecules.first)
        let ester = try #require(mol.groups.first { $0.id == "ester" })
        #expect(ester.matches.map { Set($0.atoms) } == [Set([1, 2, 3])])
        let acid = try #require(mol.groups.first { $0.id == "carboxylicAcid" })
        #expect(acid.matches.map { Set($0.atoms) } == [Set([10, 11, 12])])
        let ring = try #require(mol.groups.first { $0.id == "aromaticRing" })
        #expect(ring.matches.map { Set($0.atoms) } == [Set(4...9)])
        #expect(ring.matches[0].bonds.count == 6)
    }

    @Test func supersessionHidesTheGroupsALargerGroupIsMadeOf() async throws {
        // γ-Butyrolactone: lactone, not also ester/ether.
        let lactone = try #require(try await MoleculeEngine.shared.analyze(smiles: "O=C1CCCO1").molecules.first)
        #expect(lactone.groups.map(\.id) == ["lactone"])
        // Glucose: the anomeric OH belongs to the hemiacetal, not to "secondary alcohol".
        let glucose = try #require(try await MoleculeEngine.shared.analyze(smiles: "OC[C@H]1O[C@@H](O)[C@H](O)[C@@H](O)[C@@H]1O").molecules.first)
        let hemiacetal = try #require(glucose.groups.first { $0.id == "hemiacetal" })
        let alcohols = glucose.groups.filter { $0.id.hasPrefix("alcohol") }.flatMap(\.matches)
        for alcohol in alcohols {
            #expect(Set(alcohol.atoms).isDisjoint(with: hemiacetal.matches[0].atoms), "no alcohol overlaps the hemiacetal")
        }
    }
}
