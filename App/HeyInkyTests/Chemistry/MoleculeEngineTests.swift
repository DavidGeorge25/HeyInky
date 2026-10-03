import Foundation
import Testing
@testable import HeyInky

/// Exercises the real RDKit engine (bundled WASM in a headless WKWebView).
@MainActor
@Suite(.serialized)
struct MoleculeEngineTests {
    let engine = MoleculeEngine.shared

    @Test func engineStartsFromBundledResources() async throws {
        #expect(ChemistryWebResources.root != nil)
        let version = try await engine.version()
        #expect(version.hasPrefix("20"), "RDKit version string, got \(version)")
    }

    @Test func depictsAspirin() async throws {
        let result = try await engine.analyze(smiles: "CC(=O)Oc1ccccc1C(=O)O")
        #expect(result.ok)
        let mol = try #require(result.molecules.first)
        #expect(mol.formula == "C9H8O4")
        #expect(mol.atoms.count == 13 && mol.bonds.count == 13)
        #expect(mol.width > 0 && mol.height > 0)
        #expect(!mol.primitives.isEmpty)
        #expect(mol.primitives.allSatisfy { !$0.path.isEmpty })
        #expect(mol.inchiKey == "BSYNRYMUTXBXSQ-UHFFFAOYSA-N")
        for atom in mol.atoms {
            #expect((0...mol.width).contains(atom.x) && (0...mol.height).contains(atom.y), "atom \(atom.index) inside the drawing")
        }
    }

    @Test func invalidSmilesIsACalmError() async throws {
        let result = try await engine.analyze(smiles: "C1CC(")
        #expect(!result.ok)
        #expect(result.molecules.isEmpty)
        #expect(result.error?.isEmpty == false)
    }
}
