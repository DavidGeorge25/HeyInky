import SwiftUI

/// What the Inky layer can tell a molecule card about where it lives. The shell provides it
/// with `.environment(\.moleculeCardContext, …)` (see INTERFACE_REQUESTS.md); without it the
/// card still works, but edits (Ketcher, stars, highlight toggles, resize) only last until
/// the view is recreated.
struct MoleculeCardContext: Sendable {
    /// Page zoom factor (the same `scale` `InkyCardContainer` gets), so chrome scales with the page.
    var scale: CGFloat = 1
    /// Page size in page points, to turn a resize drag into a new normalized `near` rect.
    var pageSize: CGSize?
    /// Persists an edited action (new SMILES, stars, highlights, size) on the annotation.
    var commit: (@MainActor @Sendable (InsertMoleculeCardAction) -> Void)?
}

extension EnvironmentValues {
    @Entry var moleculeCardContext = MoleculeCardContext()
}
