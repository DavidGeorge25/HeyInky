import SwiftUI

/// STUB — owned by the Chemistry module agent (see README.md in this folder).
/// Replace the body with the RDKit.js-rendered interactive molecule (WKWebView, bundled JS).
/// Keep the type name and initializer: the Inky layer creates it as
/// `MoleculeCardView(action:)` inside `InkyCardContainer`, sized to the card's frame.
struct MoleculeCardView: View {
    let action: InsertMoleculeCardAction

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "atom")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text(action.smiles)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("Molecule viewer coming soon")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding()
        .accessibilityIdentifier("inky.card.molecule")
    }
}
