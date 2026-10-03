import Testing
import UIKit
@testable import HeyInky

/// The bundled Ketcher boots offline and round-trips a structure through its SMILES API,
/// which is what "Edit → Done" relies on before the card recomputes its groups.
@MainActor
@Suite(.serialized)
struct KetcherBridgeTests {
    @Test(.timeLimit(.minutes(2)))
    func ketcherRoundTripsAStructure() async throws {
        let bridge = KetcherBridge()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let view = bridge.makeWebView()
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }

        await bridge.open(smiles: "CC(=O)Oc1ccccc1C(=O)O")
        #expect(bridge.isReady)
        let edited = try await bridge.smiles()
        let original = try #require(try await MoleculeEngine.shared.analyze(smiles: "CC(=O)Oc1ccccc1C(=O)O").molecules.first)
        let roundTrip = try #require(try await MoleculeEngine.shared.analyze(smiles: edited).molecules.first, "RDKit reads Ketcher's SMILES: \(edited)")
        #expect(roundTrip.inchiKey == original.inchiKey, "same molecule after the round trip")
    }
}
