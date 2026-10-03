# Chemistry

Interactive molecule cards for `insertMoleculeCard` actions.

## Interface you must implement
```swift
struct MoleculeCardView: View {
    let action: InsertMoleculeCardAction   // smiles, near, highlightGroups, starGroups, caption
    var body: some View { … }
}
```
- Keep the type name and `init(action:)`. The Inky layer (`App/HeyInky/InkyLayer/InkyLayerView.swift`)
  wraps it in `InkyCardContainer` (title bar with caption, rounded card) and sizes it to the card
  frame (`InkyAnnotationGeometry.cardRect`, minimum 300×220 page points, scaled with zoom).
  Just fill the space you are given.
- The current file is a **stub** placeholder; replace its body.
- Keep accessibility identifier `inky.card.molecule` on your root view (UI tests will look for it).

## Requirements
- Render with **RDKit.js** (MinimalLib WASM) in a `WKWebView`. **Bundle all JS/WASM offline** under
  `Modules/Chemistry/Resources/web/` — no CDN at runtime. Load via `loadFileURL(_:allowingReadAccessTo:)`.
  (XcodeGen adds files in `Modules/` to the app target automatically; for a folder reference that
  keeps the directory structure, add a `type: folder` source entry for `Modules/Chemistry/Resources/web`
  in `App/project.yml`.)
- `highlightGroups` / `starGroups` are **SMARTS** patterns: use RDKit substructure matching to
  highlight matched atoms/bonds (accent-tinted) and mark starred groups.
- Invalid SMILES must not crash: show a calm inline error with the raw SMILES.
- Editing: integrate **Ketcher** (bundled) behind an "Edit" affordance; on save, update the
  annotation's SMILES via `PageEditorModel.updateAnnotation`.
- Rendering must be sharp at any zoom and work in light mode on white paper.
- Gestures inside the card must not fall through to PencilKit (the overlay already claims touches
  inside card bounds).

## Tests to add
- Unit: SMILES → render succeeds for a set of common molecules; SMARTS matching returns the expected
  atom indices (can be done through a JS bridge test harness).
- UI: insert via mock ("show me the molecule" triggers a molecule card in `MockInkyModelClient`) and
  assert `inky.card.molecule` exists.
