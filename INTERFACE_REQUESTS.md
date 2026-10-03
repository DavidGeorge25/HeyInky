# Interface requests

Requests from module agents for changes outside their module. Newest last.

## 1. Chemistry → lead: wire `MoleculeCardContext` into the Inky layer

**Why.** `MoleculeCardView(action:)` only receives the action, so the card can't persist edits:
Ketcher edits (new SMILES), starring / hiding a group, and resizing. Today those edits live in
view state and are lost when the view is recreated (page change, relaunch). The card also can't
scale its chrome with page zoom.

**What.** The Chemistry module defines (in `Modules/Chemistry/MoleculeCardContext.swift`):

```swift
struct MoleculeCardContext: Sendable {
    var scale: CGFloat = 1          // page zoom (same value InkyCardContainer gets)
    var pageSize: CGSize?           // page points; enables the resize grip
    var commit: (@MainActor @Sendable (InsertMoleculeCardAction) -> Void)?
}
extension EnvironmentValues { @Entry var moleculeCardContext = MoleculeCardContext() }
```

Suggested patch in `HeyInky/InkyLayer/InkyLayerView.swift`, inside the `ForEach` in `InkyLayerView`
(it has `editor`, `annotation`, `pageSize`, `scale`):

```swift
InkyAnnotationView(annotation: annotation, pageSize: pageSize, scale: scale)
    .environment(\.moleculeCardContext, MoleculeCardContext(
        scale: scale,
        pageSize: pageSize,
        commit: { [editor] updated in
            var copy = annotation
            copy.action = .insertMoleculeCard(updated)
            editor.updateAnnotation(copy)
        }
    ))
```

Notes:
- The resize grip commits a new `near` rect whose origin is the card's current
  `InkyAnnotationGeometry.cardRect` origin and whose size grows/shrinks with the drag (min
  `minCardSize`). The user `offset` is untouched.
- `highlightGroups == ["none"]` is how the card stores "user hid every highlight" (`[]` keeps
  meaning "all detected groups"). The model never needs to produce it.
- Nothing else in the shell changes; everything is optional, so the card works without it.

## 2. Chemistry → lead / AI agent (optional): prompt hint for `insertMoleculeCard`

The card accepts library group ids/names in `highlightGroups` / `starGroups` as well as SMARTS
(e.g. `"ester"`, `"carboxylic acid"`, `"amide"`, `"β-lactam"`), and reaction SMILES
(`"CCO.CC(=O)O>>CC(=O)OCC.O"`, agents between the `>`s are shown over the arrow). Names are often
more reliable from the model than hand-written SMARTS. A one-line hint in
`shared/inky_system_prompt.md` would let the model use both. Group ids are listed in
`App/Modules/Chemistry/Resources/ChemistryWeb/functional-groups.json`. No schema change needed.
