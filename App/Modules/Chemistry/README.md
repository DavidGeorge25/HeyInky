# Chemistry

Interactive molecule cards for `insertMoleculeCard` actions: an accurate 2D depiction from
SMILES, functional groups highlighted by exact SMARTS matches, tap-for-info, stars, labels,
R/S · E/Z tags, reaction SMILES, and structure editing in Ketcher. Fully offline.

## Interface (unchanged)
```swift
struct MoleculeCardView: View {
    let action: InsertMoleculeCardAction   // smiles, near, highlightGroups, starGroups, caption
}
```
- Fills whatever the Inky layer gives it inside `InkyCardContainer`; root identifier `inky.card.molecule`.
- Optional environment `\.moleculeCardContext` (`MoleculeCardContext`: `scale`, `pageSize`, `commit`)
  lets the shell persist edits and enables resizing. Not wired yet — see `/INTERFACE_REQUESTS.md` #1.
  Without it, edits (Ketcher, stars, highlight toggles) last until the view is recreated.

### What the model may send
- `smiles`: a molecule, a salt (`[Na+].[O-]C(C)=O`), or a reaction (`A.B>>C`, `A>agent>C`).
- `highlightGroups` / `starGroups`: SMARTS **or** a library group id/name/alias (`ester`,
  `Carboxylic acid`, `amide`, `β-lactam`, `hydroxyl`…). Empty `highlightGroups` = show every
  detected group. `["none"]` = user hid all highlights.
- **The model never decides which atoms are highlighted.** A name maps to the library's SMARTS; a
  raw SMARTS is matched by RDKit and, if a library group explains its matches, shown as that group.
  A group the molecule doesn't contain highlights nothing; an unparseable SMARTS is ignored.

## Architecture
```
MoleculeCardView ── .task ──> MoleculeEngine.shared (one hidden WKWebView, whole app)
      │                          └─ inkychem://app/engine.html → RDKit MinimalLib (WASM) + chem-core.js
      │                               analyze(): depiction SVG + draw coords, SMARTS library matches,
      │                               caller patterns, CIP labels, formula, InChIKey, reactions
      ├─ MoleculeGroups   (what to highlight/star; toggles → action patterns)
      ├─ MoleculeLayout   (fit/scale, reaction layout, hit-testing)
      ├─ MoleculeCanvas   (native SwiftUI Canvas: RDKit paths + highlights + labels + tags)
      ├─ MoleculeInfoView (names, IUPAC, formula, mass, charge, stereo, SMILES)
      └─ KetcherEditorView (full-screen bundled Ketcher; result validated by RDKit)
```
Why native drawing of RDKit's SVG instead of a web view per card: one WASM instance for any number
of cards, vector rendering that stays sharp at any zoom, native gestures that never fall through to
PencilKit, dark mode by recoloring, and snapshot tests with `ImageRenderer`.

Why a custom URL scheme (`ChemistryWebResources`) instead of `loadFileURL`: WebKit only streams
WASM / lets `fetch()` read bundle files from a scheme that serves real MIME types. The handler
refuses paths outside the bundled folder.

## Files
| File | |
|---|---|
| `Resources/ChemistryWeb/` | Folder reference (`project.yml`): `rdkit/`, `ketcher/` (main entry only, ~30 MB), `engine.html`, `chem-core.js`, `functional-groups.json`, `ketcher-bridge.js`, licenses. Named `ChemistryWeb` so it can't collide with another module's `web` folder at the bundle root. |
| `functional-groups.json` | **The SMARTS library** (33 groups). `core` = highlighted SMARTS atoms, `supersedes` = e.g. lactone hides its ester, hemiacetal hides its alcohol; overlapping matches of one group merge into one instance. |
| `chem-core.js` | Pure functions over RDKit; runs in the app and in Node. |
| `MoleculeEngine.swift` | Bridge + LRU cache. `analyze(smiles:highlightGroups:starGroups:)`. |
| `MoleculeNames.swift` | Offline common/IUPAC names for ~90 molecules by InChIKey (no offline IUPAC generator exists for arbitrary structures). |

### Adding a functional group
1. Add an entry to `functional-groups.json` (id, name, optional short, description, smarts, core, supersedes).
2. Give it a color in `GroupPalette.fixed`.
3. Add at least one molecule to `App/HeyInkyTests/Chemistry/known-molecules.json` and make sure no
   existing expectation changes unintentionally. Quick loop without Xcode:
   ```bash
   node -e "const d='App/Modules/Chemistry/Resources/ChemistryWeb/';require('./'+d+'rdkit/RDKit_minimal.js')().then(R=>{
     const c=require('./'+d+'chem-core.js').create(R,require('./'+d+'functional-groups.json'));
     console.log(JSON.stringify(c.analyze({smiles:'CC(=O)OC'}).molecules[0].groups))})"
   ```

## Tests (`App/HeyInkyTests/Chemistry`, `App/HeyInkyUITests/MoleculeCardUITests.swift`)
- `FunctionalGroupLibraryTests`: 77 known molecules (aspirin, caffeine, ibuprofen, glucose,
  penicillin G, sucrose, steroids, drugs, simple references) → exact group instance counts through the
  real RDKit engine; every group covered; exact atom indices; supersession.
- `MoleculeCardLogicTests`: pattern resolution (names, aliases, raw SMARTS, absent/invalid groups),
  toggle round trips, reactions, layout & hit-testing, stereo, charges, names, malformed input, SVG
  path parser, resource handler.
- `MoleculeCardSnapshotTests`: reference PNGs in `__Snapshots__/` (light, dark, starred, reaction,
  error). Re-record with `TEST_RUNNER_SNAPSHOT_RECORD=1`.
- `KetcherBridgeTests`: Ketcher boots offline and round-trips a structure via SMILES.
- UI: mock "show me the molecule" → card, RDKit chip, group info + star, labels toggle, Ketcher open/cancel.

## Next steps
- Shell wiring of `moleculeCardContext` (INTERFACE_REQUESTS #1) to persist edits and enable resize.
- Ketcher's toolbar is desktop-dense; a trimmed iPad toolbar (Ketcher `buttons` config) would help.
- More groups if students need them (sulfone, phosphate ester, carbamate, urea, enol, enamine).
