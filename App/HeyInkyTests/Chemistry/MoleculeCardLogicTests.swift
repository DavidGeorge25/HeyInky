import SwiftUI
import Testing
@testable import HeyInky

@MainActor
@Suite(.serialized)
struct MoleculeGroupsTests {
    let aspirin = "CC(=O)Oc1ccccc1C(=O)O"
    let penicillin = "CC1(C)S[C@@H]2[C@H](NC(=O)Cc3ccccc3)C(=O)N2[C@H]1C(=O)O"

    func groups(_ smiles: String, highlight: [String] = [], star: [String] = []) async throws -> MoleculeGroups {
        let analysis = try await MoleculeEngine.shared.analyze(smiles: smiles, highlightGroups: highlight, starGroups: star)
        #expect(analysis.ok)
        return MoleculeGroups(analysis: analysis, highlightGroups: highlight, starGroups: star)
    }

    @Test func freshCardHighlightsEveryLibraryGroup() async throws {
        let g = try await groups(aspirin)
        #expect(g.all.map(\.key) == ["carboxylicAcid", "ester", "aromaticRing"], "library order")
        #expect(g.highlighted == ["carboxylicAcid", "ester", "aromaticRing"])
        #expect(g.starred.isEmpty)
    }

    @Test func namedGroupsHighlightOnlyThoseGroups() async throws {
        let g = try await groups(aspirin, highlight: ["ester"], star: ["Carboxylic acid"])
        #expect(g.highlighted == ["ester"])
        #expect(g.starred == ["carboxylicAcid"])
        #expect(g.all.count == 3, "other groups stay available in the bar")
    }

    @Test func rawSmartsIsNamedByTheLibraryGroupItMatches() async throws {
        let g = try await groups(aspirin, highlight: ["C(=O)[OH]"])
        #expect(g.highlighted == ["carboxylicAcid"])
        #expect(!g.all.contains { !$0.isLibraryGroup }, "no duplicate pattern row")
    }

    @Test func smartsWithoutALibraryGroupHighlightsExactlyItsMatches() async throws {
        let g = try await groups(aspirin, highlight: ["[CH3]"])
        let key = DisplayGroup.patternPrefix + "[CH3]"
        #expect(g.highlighted == [key])
        let group = try #require(g.group(key))
        #expect(group.instances.map(\.atoms) == [[0]], "RDKit's match, the methyl carbon")
        #expect(group.name == "Matched pattern")
    }

    @Test func groupsTheMoleculeLacksHighlightNothing() async throws {
        // A model claiming aspirin has a nitrile can't make one appear.
        let g = try await groups(aspirin, highlight: ["nitrile", "C#N"])
        #expect(g.highlighted.isEmpty)
        #expect(!g.all.contains { $0.key == "nitrile" })
    }

    @Test func invalidPatternsAreReportedNotGuessed() async throws {
        let g = try await groups(aspirin, highlight: ["ester", "C(=O"])
        #expect(g.highlighted == ["ester"])
        #expect(g.invalidPatterns == ["C(=O"])
    }

    @Test func aliasesResolveToLibraryGroups() async throws {
        let g = try await groups(penicillin, highlight: ["amide"], star: ["β-lactam"])
        #expect(g.highlighted == ["lactam", "amide2"])
        #expect(g.starred == ["lactam"])
    }

    @Test func togglesRoundTripThroughTheAction() async throws {
        let g = try await groups(aspirin)
        #expect(g.highlightPatterns(for: Set(g.all.map(\.key))) == [], "all → default")
        #expect(g.highlightPatterns(for: []) == [MoleculeGroups.noneSentinel])
        #expect(g.highlightPatterns(for: ["ester", "aromaticRing"]) == ["ester", "aromaticRing"])
        #expect(g.starPatterns(for: ["carboxylicAcid"]) == ["carboxylicAcid"])

        let hidden = try await groups(aspirin, highlight: [MoleculeGroups.noneSentinel])
        #expect(hidden.highlighted.isEmpty)
        let some = try await groups(aspirin, highlight: g.highlightPatterns(for: ["ester", "aromaticRing"]))
        #expect(some.highlighted == ["ester", "aromaticRing"])
    }

    @Test func reactionGroupsSpanEveryMolecule() async throws {
        let analysis = try await MoleculeEngine.shared.analyze(smiles: "CCO.CC(=O)O>H2SO4>CC(=O)OCC.O")
        #expect(analysis.ok && analysis.isReaction)
        #expect(analysis.arrowAfter == 2 && analysis.molecules.count == 4)
        #expect(analysis.agents == ["H2SO4"])
        let g = MoleculeGroups(analysis: analysis, highlightGroups: [], starGroups: [])
        #expect(Set(g.all.map(\.key)) == ["alcohol1", "carboxylicAcid", "ester"])
        #expect(g.group("ester")?.instances.first?.molecule == 2)
    }
}

@MainActor
@Suite(.serialized)
struct MoleculeLayoutTests {
    @Test func tapsFindAtomsBondsAndGroups() async throws {
        let analysis = try await MoleculeEngine.shared.analyze(smiles: "CC(=O)Oc1ccccc1C(=O)O")
        let groups = MoleculeGroups(analysis: analysis, highlightGroups: [], starGroups: [])
        let layout = MoleculeLayout(analysis: analysis, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let mol = analysis.molecules[0]
        #expect(layout.bondLength <= 46 + 0.001, "small molecules don't balloon")

        // The ester's carbonyl oxygen (atom 2).
        let carbonylO = layout.point(mol.atoms[2].point, molecule: 0)
        #expect(layout.hitTest(carbonylO, analysis: analysis) == .atom(molecule: 0, atom: 2))
        #expect(MoleculeCardContent.groupKey(at: carbonylO, layout: layout, analysis: analysis, groups: groups, preferring: nil) == "ester")

        // Ring atom → aromatic ring; methyl carbon (atom 0) → no group.
        let ring = layout.point(mol.atoms[6].point, molecule: 0)
        #expect(MoleculeCardContent.groupKey(at: ring, layout: layout, analysis: analysis, groups: groups, preferring: nil) == "aromaticRing")
        let methyl = layout.point(mol.atoms[0].point, molecule: 0)
        #expect(MoleculeCardContent.groupKey(at: methyl, layout: layout, analysis: analysis, groups: groups, preferring: nil) == nil)
        #expect(layout.hitTest(CGPoint(x: -100, y: -100), analysis: analysis) == nil)

        // Every atom lands inside the drawing rect.
        for atom in mol.atoms {
            #expect(layout.bounds.insetBy(dx: -1, dy: -1).contains(layout.point(atom.point, molecule: 0)))
        }
    }

    @Test func tappingTheSelectedGroupAgainDismissesIt() async throws {
        // With a single candidate group, tapping the selected group again dismisses it.
        let analysis = try await MoleculeEngine.shared.analyze(smiles: "CC(=O)Oc1ccccc1C(=O)O")
        let groups = MoleculeGroups(analysis: analysis, highlightGroups: [], starGroups: [])
        let layout = MoleculeLayout(analysis: analysis, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let p = layout.point(analysis.molecules[0].atoms[2].point, molecule: 0)
        #expect(MoleculeCardContent.groupKey(at: p, layout: layout, analysis: analysis, groups: groups, preferring: "ester") == nil, "tap again to dismiss")
    }

    @Test func reactionsLayOutLeftToRightWithAnArrow() async throws {
        let analysis = try await MoleculeEngine.shared.analyze(smiles: "C=C.[H][H]>>CC")
        let layout = MoleculeLayout(analysis: analysis, in: CGRect(x: 0, y: 0, width: 500, height: 200))
        #expect(layout.placements.count == 3)
        #expect(layout.placements[0].origin.x < layout.placements[1].origin.x && layout.placements[1].origin.x < layout.placements[2].origin.x)
        #expect(layout.glyphs.count == 2)
        guard case .plus = layout.glyphs[0], case .arrow(let from, let to) = layout.glyphs[1] else {
            Issue.record("expected plus then arrow"); return
        }
        #expect(from.x > layout.placements[1].origin.x + layout.placements[1].size.width - 0.5 && to.x < layout.placements[2].origin.x + 0.5)
    }
}

@MainActor
@Suite(.serialized)
struct ChemistryDetailsTests {
    @Test func stereoDescriptorsComeFromRDKit() async throws {
        let alanine = try #require(try await MoleculeEngine.shared.analyze(smiles: "C[C@@H](C(=O)O)N").molecules.first)
        #expect(alanine.stereocenters.map(\.label) == ["S"])
        let fumaric = try #require(try await MoleculeEngine.shared.analyze(smiles: "OC(=O)/C=C/C(=O)O").molecules.first)
        #expect(fumaric.stereobonds.map(\.label) == ["E"])
        let maleic = try #require(try await MoleculeEngine.shared.analyze(smiles: "OC(=O)/C=C\\C(=O)O").molecules.first)
        #expect(maleic.stereobonds.map(\.label) == ["Z"])
        // Unspecified centers ("(?)") are not labeled.
        let ibuprofen = try #require(try await MoleculeEngine.shared.analyze(smiles: "CC(C)Cc1ccc(cc1)C(C)C(=O)O").molecules.first)
        #expect(ibuprofen.stereocenters.isEmpty)
        let penicillin = try #require(try await MoleculeEngine.shared.analyze(smiles: "CC1(C)S[C@@H]2[C@H](NC(=O)Cc3ccccc3)C(=O)N2[C@H]1C(=O)O").molecules.first)
        #expect(Set(penicillin.stereocenters.map(\.label)) == ["R", "S"] && penicillin.stereocenters.count == 3)
    }

    @Test func formalChargesAndFormulas() async throws {
        let glycine = try #require(try await MoleculeEngine.shared.analyze(smiles: "[NH3+]CC(=O)[O-]").molecules.first)
        #expect(glycine.formula == "C2H5NO2" && glycine.charge == 0)
        let acetate = try #require(try await MoleculeEngine.shared.analyze(smiles: "CC(=O)[O-]").molecules.first)
        #expect(acetate.charge == -1)
        #expect(MoleculeCardContent.formulaText(acetate.formula, charge: acetate.charge) == "C₂H₃O₂⁻")
        #expect(MoleculeCardContent.formulaText("C9H8O4") == "C₉H₈O₄")
        #expect(MoleculeCardContent.formulaText("Ca", charge: 2) == "Ca²⁺")
        // RDKit draws the charges itself: the glyphs for N+ and O− are in the depiction.
        #expect(glycine.primitives.contains { $0.atoms == [0] && $0.kind == .fill })
    }

    @Test func offlineNamesFollowTheStructureNotTheSpelling() async throws {
        let spellings = [
            ("Cn1cnc2c1c(=O)n(C)c(=O)n2C", "Caffeine"),
            ("CN1C=NC2=C1C(=O)N(C(=O)N2C)C", "Caffeine"),
            ("O=C(O)c1ccccc1OC(C)=O", "Aspirin"),
            ("OC[C@H]1O[C@@H](O)[C@H](O)[C@@H](O)[C@@H]1O", "β-D-Glucose"),
            ("CC1(C)S[C@@H]2[C@H](NC(=O)Cc3ccccc3)C(=O)N2[C@H]1C(=O)O", "Penicillin G"),
            ("C[C@@H](C(=O)O)N", "L-Alanine"),
        ]
        for (smiles, name) in spellings {
            let mol = try #require(try await MoleculeEngine.shared.analyze(smiles: smiles).molecules.first)
            #expect(MoleculeNames.lookup(mol.inchiKey)?.common == name, "\(smiles) → \(name)")
        }
        let unknown = try #require(try await MoleculeEngine.shared.analyze(smiles: "CCCCCCCCCCCCCCCCC(O)CCl").molecules.first)
        #expect(MoleculeNames.lookup(unknown.inchiKey) == nil)
    }

    @Test func emptyAndMalformedInputFailCalmly() async throws {
        for bad in ["", "   ", "C1CC", "xyz", "CC>>", "C>>C>>C"] {
            let result = try await MoleculeEngine.shared.analyze(smiles: bad)
            #expect(!result.ok, "\(bad.debugDescription) fails")
            #expect(result.error?.isEmpty == false)
            #expect(result.molecules.isEmpty)
        }
    }

    @Test func largeMoleculesStayFast() async throws {
        // Vancomycin-sized input (a 20-residue polyglycine) still analyzes quickly.
        let peptide = "NCC(=O)" + String(repeating: "NCC(=O)", count: 19) + "O"
        let start = Date()
        let result = try await MoleculeEngine.shared.analyze(smiles: peptide)
        #expect(result.ok)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(result.molecules[0].groups.first { $0.id == "amide2" }?.matches.count == 19)
    }
}

struct SVGPathTests {
    @Test func parsesRDKitPathData() {
        let line = SVGPath.parse("M 242.3,147.7 L 213.0,121.3")
        #expect(abs(line.boundingRect.minX - 213.0) < 0.01 && abs(line.boundingRect.maxY - 147.7) < 0.01)

        let glyph = SVGPath.parse("M 195.9 162.9 L 201.8 172.5 Q 202.4 173.4, 203.3 175.1 L 195.9 162.9 Z M 1e1 2E1 L 11 21")
        #expect(glyph.boundingRect.minX <= 10.0001 && glyph.boundingRect.maxX >= 203.2)

        let relative = SVGPath.parse("m10 10 l5 0 h5 v5 z")
        #expect(relative.boundingRect == CGRect(x: 10, y: 10, width: 10, height: 5))

        let curve = SVGPath.parse("M0,0 C 10,10 20,10 30,0")
        #expect(curve.boundingRect.maxX == 30)

        let arc = SVGPath.parse("M 0 10 A 10 10 0 1 1 20 10")
        #expect(abs(arc.boundingRect.minY - 0) < 0.6 && abs(arc.boundingRect.width - 20) < 0.6, "half circle above the chord")

        #expect(SVGPath.parse("").isEmpty)
        #expect(!SVGPath.parse("M 0 0 L 1 1 garbage 5").isEmpty, "stops quietly on junk")
    }
}

@MainActor
struct ChemistryWebResourcesTests {
    @Test func servesOnlyBundledFilesWithRealMimeTypes() throws {
        let wasm = try #require(ChemistryWebResources.fileURL(for: ChemistryWebResources.url("rdkit/RDKit_minimal.wasm")))
        #expect(ChemistryWebResources.mimeType(for: wasm) == "application/wasm")
        #expect(ChemistryWebResources.fileURL(for: ChemistryWebResources.url("ketcher/index.html")) != nil, "Ketcher is bundled")
        #expect(ChemistryWebResources.fileURL(for: ChemistryWebResources.url("functional-groups.json")) != nil)
        #expect(ChemistryWebResources.fileURL(for: URL(string: "inkychem://app/../Info.plist")!) == nil, "can't escape the folder")
        #expect(ChemistryWebResources.fileURL(for: URL(string: "inkychem://app/nope.js")!) == nil)
        #expect(ChemistryWebResources.fileURL(for: URL(string: "https://example.com/engine.html")!) == nil)
    }
}
