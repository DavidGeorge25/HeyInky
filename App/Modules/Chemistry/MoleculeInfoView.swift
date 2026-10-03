import SwiftUI

/// Popover with names, formula, mass, charge, stereo descriptors and SMILES for each species.
struct MoleculeInfoView: View {
    let analysis: MoleculeAnalysis

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(analysis.molecules.enumerated()), id: \.offset) { index, molecule in
                    if analysis.arrowAfter == index {
                        Label("Products", systemImage: "arrow.right")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    section(molecule)
                }
            }
            .padding(18)
        }
        .frame(idealWidth: 340, maxWidth: 380, idealHeight: 300, maxHeight: 460)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("inky.molecule.infoSheet")
    }

    private func section(_ molecule: MoleculeDepiction) -> some View {
        let name = MoleculeNames.lookup(molecule.inchiKey)
        return VStack(alignment: .leading, spacing: 6) {
            Text(name?.common ?? MoleculeCardContent.formulaText(molecule.formula, charge: molecule.charge))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            if let iupac = name?.iupac, iupac.lowercased() != name?.common.lowercased() {
                row("IUPAC", iupac)
            }
            row("Formula", MoleculeCardContent.formulaText(molecule.formula, charge: molecule.charge))
            if let mw = molecule.molWeight {
                row("Molar mass", String(format: "%.2f g/mol", mw))
            }
            if molecule.charge != 0 {
                row("Net charge", molecule.charge > 0 ? "+\(molecule.charge)" : "−\(abs(molecule.charge))")
            }
            if !molecule.stereocenters.isEmpty || !molecule.stereobonds.isEmpty {
                let centers = molecule.stereocenters.map { "\(molecule.atoms[$0.atom].symbol)\($0.atom + 1) (\($0.label))" }
                let bonds = molecule.stereobonds.map { "C\($0.a + 1)=C\($0.b + 1) (\($0.label))" }
                row("Stereo", (centers + bonds).joined(separator: ", "))
            }
            row("SMILES", molecule.smiles, monospaced: true)
        }
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13, design: .rounded))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
