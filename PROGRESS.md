# Progress

_Last updated: 2026-10-04 (integration, QA, Inky-as-tutor, drawing, notebook tools)._

## Latest: precise marks and typeset figures (perceive → reason → place) ✅
Field report: "add the hidden hydrogens" on a hand-drawn image put H bonds floating next to the atoms, and
"draw the resonance structures" wrote SMILES-like text in handwriting. Root cause: the model was asked to do
geometry it can't do, and images gave it no geometry at all.

- **Perception** (`HeyInky/Perception`): images, pen ink and PDF figures → line art → bond graph → atom labels →
  RDKit. The hand-drawn acetaminophen image is read exactly (11 atoms, 11 bonds, 4 double bonds, O/NH/OH,
  `CC(=O)Nc1ccc(O)cc1`, 7 hidden H); pen-drawn molecules too. Structures go to the model as S1 with atom ids.
- **`annotateStructure`**: hydrogens, lone pairs, charges, group highlights (RDKit SMARTS on the student's
  drawing), atom labels, curved/fishhook arrows — the model names atoms, `StructureAnnotator` places
  everything (H's on the carbon, in the open angles, at the drawing's bond length).
- **`insertChemScheme`**: typeset resonance/reaction/mechanism figures (RDKit, Kekulé forms kept, forms aligned,
  atom-map arrows). Deep check rejects non-parsing steps and "resonance forms" that are different molecules.
- **`insertDiagram`**: model SVG + Inky's style kit, sanitized; **callouts** laid out by the app (label columns,
  uncrossed leaders); checked for overlapping labels, lines through text, crossing leaders and tiny text; one
  retry; vector PDF.
- Figures are placed in free space; label arrows on images snap onto the drawing; zoomed fine-grid view of the
  main image for labeling.
- Live (gpt-5.4-mini): hydrogens on the image ✅ exact; lone pairs + amide ✅; phenoxide resonance ✅ (a bad
  seven-membered "form" from one run is now caught by the deep check); labeled animal cell ✅ (clean after
  callouts). Screenshots were reviewed for each.
- Tests: `PerceptionTests` (15), `PrecisionUITests` (4 flows, mock + live); full suite green.

### Next
- Condensed labels ("CO2H", "OMe", "CH2CH3") in drawings; wedge/dash bonds; charges written in drawings.
- Snap callout points onto the part's outline/interior from the rendered SVG (the model can still point a
  callout at the wrong part).
- Perception on photos of paper (perspective, shadows) — thresholding is local, but no deskew yet.

## Latest: Inky tutors on the page + notebook tools ✅
- **Inky draws** (`draw` action, schema v3): real PencilKit ink + handwriting — bonds/atoms, arrows,
  curved mechanism arrows, dashed lines, polygons, ellipses, worked steps. Inky's character draws each
  stroke under its nib. **`addPage`**: longer work goes on a fresh page.
- **Tutor-first prompt:** "explain / solve / show / draw" are answered on the page; the sidebar is for
  explicit "notes / summarize". Adaptive reasoning (medium for drawing/solving).
- **Readable by construction:** labels and notes placed off other text, marks and ink; drawing text
  doesn't collide; circles/boxes snap around the text they enclose; atom labels centered on bond ends;
  clean bond angles from the student's skeleton; carbon valence check drops duplicated H's.
- **Context:** the student's pen strokes as corner points + junctions with bond counts.
- **Select tool:** lasso/tap ink, images, text and Inky marks; move, resize, copy/cut/paste/duplicate/
  delete, Ask Inky about the selection, Convert to Text, Make it my ink. Undo for all of it.
- **Text tool**, **draw-and-hold shape correction** (line/circle/ellipse/triangle/rectangle/polygon, angle
  snapping), **handwriting → text** (Vision), **PDF export** (with/without Inky), **pixel eraser default**,
  tool bar returns after typing.

Live checks (real proxy): methylcyclohexane → 14 H's drawn with clean angles (gpt-5.4, medium; mini/low
gets close but can miscount, which the valence check partly catches); "explain why raising T shifts this
left" → highlight + note + fill + red reasoning arrow on the page, no sidebar; "intercepts step by step on
a new page" → full correct worked solution on a new grid page with answers circled.

## Status: all modules integrated on `main` ✅
Merged in order (PRs #4, #2, #3, #1): **AICore** → **Chemistry** → **Graphs** → **InkyCharacter**. Every
request in `INTERFACE_REQUESTS.md` is fulfilled (status line on each). After each merge the app built with
zero warnings and the full suite passed.

- **Unit tests:** Swift Testing, all green (schema⇄Swift sync, AICore context/validation/retry, chemistry
  RDKit groups on 77 molecules + snapshots, graphs parser/analysis/presets/web bridge + snapshots, Inky
  character snapshots + choreography, store/persistence, undo, renderers, session).
- **UI tests (mock client, offline):** basic flows, molecule card + Ketcher, graph card (sliders, expression
  editor, pan, flatten), choreography, and `EndToEndUITests` (6 flows below). All green.
- **Proxy:** `npm run check` green. **Evals:** see `evals/RESULTS.md`.

## End-to-end QA (iPad Pro 11" M5 simulator, iOS 26.3, real proxy + OpenAI)
`TEST_RUNNER_INKY_LIVE=1 xcodebuild test … -only-testing:HeyInkyUITests/EndToEndUITests` runs these against
the real model; the same tests run offline with the mock client by default.

| Flow | Live result |
|---|---|
| Handwritten acetaminophen (image on a grid page) → "what functional groups are here?" | ✅ molecule card, RDKit structure correct, 2° amide + phenol highlighted, aromatic ring detected |
| Imported PDF slide `f(x) = (2x + 1)/(x − 3)` → "label the asymptotes" | ✅ graph card, asymptotes x = 3 and y = 2 labeled by Inky, slider moves the curve and its asymptote (after the prompt fix below) |
| Worksheet PDF with 4 empty boxes → "fill these in" | ✅ 56 · 12 · 12 · 18, each inside its box |
| "explain SN1 vs SN2" | ✅ sidebar with a Markdown explanation; Listen → TTS speaks (word progress observed) and pauses |
| Voice question ("highlight the title", scripted transcript in the simulator) | ✅ transcript streams into the field, send, title highlighted |
| Undo / redo / delete / hide layer, relaunch | ✅ toolbar Undo removes the whole Inky turn, Redo restores; deleted mark stays deleted; hidden layer stays hidden after relaunch; marks persist |

Live runs used `gpt-5.4` and `gpt-5.5` via `TEST_RUNNER_INKY_MODEL`: the org's 50 requests/day cap for the
default `gpt-5.4-mini` was already used up that day (the app then shows "Inky is getting too many questions
right now"). The worksheet and undo/relaunch flows passed live on `gpt-5.4`, before the last prompt/label
changes; the final `gpt-5.5` run passed molecule, asymptotes, explanation and voice, then hit that model's
daily cap too. **To do:** re-run the whole live suite on the default model once the quota resets.

### Bugs found and fixed in this session
- **Asymptotes stayed put when a slider moved** (Inky's `y = 2` stayed next to the true `y = a`). Given
  lines the curve now contradicts are dropped (single-curve graphs); detected ones follow the slider.
- **Inky's fixed points (intercepts, vertex) stayed put when a slider moved** → hidden once no curve passes
  through them (`GraphDocument.stalePointIndices`, sent with every slider patch).
- **"label the asymptotes" put two overlapping page labels over the equation** instead of a graph card →
  prompt: graph features of a function written only as an equation go on a graph card, with a slider.
- **Overlapping / truncated labels:** a new label picks the first side of its anchor that doesn't cover
  another label (`InkyAnnotation.labelPlacement`); label boxes got width slack so text isn't cut off.
- **Undo didn't cover Inky** and ink undo used the window's shared undo manager (could act across pages) →
  per-page `UndoManager` shared by ink and Inky; an Inky turn is one step; delete/hide/move/clear/edit undoable.
- **Hiding the Inky layer didn't persist** (lost on page change and relaunch) → stored per notebook.
- **Graph cards were cramped** on landscape slides → minimum card size 320×260 pt.
- Fill-in answers sat on the box's left border → small inset.
- Integration: duplicate `Snapshot` test helper (renamed Chemistry's); character reveal view rebuilt card
  web views when the reveal ended (now one stable structure).
- Rate-limit toast no longer shows a raw HTTP status.

### Added for QA
- DEBUG launch arguments `-InkyUITestScenario`, `-InkyUITestImage`, `-InkyUITestLibrary`, `-InkyUITestSpeech`
  (see README); fixture `App/HeyInkyUITests/Fixtures/acetaminophen_hand.png`.
- Accessibility: graph cards announce their asymptotes (`inky.graph.asymptotes`); the Listen button reports
  how much has been read.

## Needs a human on a real iPad + Apple Pencil
- **Draw-and-hold** with a real Pencil (hold time 0.4 s feels right? false triggers while pausing mid-word?).
- **Text tool** with Scribble (writing into text boxes with the Pencil) and the hardware keyboard.
- **Select tool** with Pencil vs finger (lasso precision, dragging small selections, the resize handle).
- **Watching Inky draw**: is the stroke-by-stroke speed pleasant for long answers (worked steps take ~5 s)?
The simulator draws with a mouse/touch and has no Pencil, so these can't be verified here:
- **Pencil feel:** stroke latency and prediction with the Inky layer and cards on screen; palm rejection
  while a card or the ask popover is up; pressure/tilt with each tool.
- **Latency:** time from lifting the Pencil to ink saved; Inky summon → first mark on a real network
  (Mac proxy over Wi-Fi with `-InkyProxyURL`); scroll/zoom smoothness on long PDF notebooks.
- **Squeeze (Pencil Pro):** squeeze summons Inky at the hover point; haptic on summon/land; squeeze while
  zoomed in/scrolled; double-tap still follows the system setting.
- **Hover (M2+ iPad / Pencil Pro):** squeeze anchor follows hover; no stray lasso from hover.
- **Lasso with Pencil:** circling a region while Inky is summoned, then asking; two-finger scroll during lasso.
- **Touches on cards:** slider dragging, graph panning and molecule tapping never leave ink; drawing right
  next to a card still inks.
- **Voice:** real microphone + on-device recognition (permission prompts, STEM words like "carbonyl",
  "asymptote"), stopping with the mic button; TTS volume/route with headphones and with the silent switch.
- **Ketcher** editing with Pencil (fine taps on atoms/bonds) and the on-screen keyboard.
- **Performance:** many cards on one page (one RDKit engine, one web view per graph card), memory after
  opening several notebooks; thermal on long sessions.
- **Visuals:** Inky's hop/draw choreography timing on a 120 Hz display; app icon and launch screen on device.

## Known gaps / next steps
- Hydrogen/atom placement is reliable only for skeletons drawn as pen ink (images give no stroke geometry).
- mini/low sometimes miscounts atoms; the app fixes duplicates but can't add missing ones.
- Text boxes don't wrap around ink; no rich text (bold/lists) yet. No handwriting search yet.
- Eval cases in `evals/` still expect sidebars for "explain" questions; update them to the tutor format.
- Stale-asymptote/point logic is heuristic for multi-curve graphs (only single-curve graphs drop given lines).
- PDF pages with rotation: rendered, but text-layer boxes are skipped (OCR covers them).
- One page on screen at a time (no continuous vertical scroll); no iCloud sync, search or export yet.
- AICore: "Sign in with ChatGPT" client, eval re-run on the latest prompt (`evals/run_evals.py`).
- Chemistry: offline IUPAC names only for ~90 known molecules.
- InkyCharacter: Pencil Pro haptics at the hover point.
