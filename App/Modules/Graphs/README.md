# Graphs

Interactive, editable graph cards for `insertGraphCard` actions.

## Interface
```swift
struct GraphCardView: View {
    let action: InsertGraphCardAction   // spec: GraphSpec, near: NormRect
}
// Optional, from the environment — enables persistence, resize and flatten:
struct GraphCardHost { pageSize; update(InsertGraphCardAction); flatten(UIImage)? }
EnvironmentValues.graphCardHost
```
- The Inky layer wraps the card in `InkyCardContainer` and sizes it to the card frame.
- Root accessibility identifier: `inky.card.graph`. Controls: `inky.graph.function.<i>`,
  `inky.graph.param.<name>` (slider) / `.edit` (range editor), `inky.graph.expression`,
  `inky.graph.zoomIn|zoomOut|fit|menu|resize|board`.
- Shell wiring for the host: see `INTERFACE_REQUESTS.md` (#1) at the repo root.

## What the card does
- **Plot:** JSXGraph 1.13.3 (MIT), bundled offline in `Resources/web/`, in a `WKWebView`.
  One-finger pan, pinch zoom, zoom/fit buttons, sticky axes with labels, draggable points.
- **Functions:** several per card; tap a curve or its legend chip → popover editor. Valid input
  redraws live; invalid input shows a calm message and keeps the last good curve; an unknown name
  (`k`) offers "Add slider k". Add/delete functions from the ⋯ menu / editor.
- **Sliders:** one per param (native SwiftUI). Tap the name/value to edit min / max / step.
- **Analysis (automatic, live with sliders):** vertical (poles and log-like domain edges),
  horizontal and oblique asymptotes — dashed and labeled; x/y-intercepts, maxima/minima,
  inflection points (tap a dot for its coordinates). Model-given asymptotes win over detected
  duplicates. Toggle in ⋯ › Show.
- **Presets** (⋯ › Presets): exponential and logistic growth, Michaelis–Menten (Km, Vmax),
  dose–response (Hill), Lineweaver–Burk, projectile motion, simple harmonic motion.
- **Appearance:** follows the system, or force Light/Dark per card (⋯ › Appearance).
- **Resize:** corner handle. **Flatten:** ⋯ › Flatten into page renders a standalone image
  (legend + slider values) and replaces the card.

## Safety
Expressions never reach a JS engine as source. `GraphExpr.parse` (Swift) accepts only numbers,
`x`/`t`, declared params, constants, a whitelist of `Math` functions, arithmetic, comparisons,
`&& || !` and `?:`; everything else (`fetch`, `window`, strings, brackets, `=`, `;`, `.` other than
`Math.f`) is rejected with a calm message. The web view receives the parsed tree as JSON data and
interprets it with a frozen function table. The page has a CSP with no `unsafe-eval` and
`default-src 'none'` (no network), navigation is limited to the bundled page, and all text is
plain SVG text (JessieCode/HTML parsing off). Model colors are accepted only as hex or a small
named set.

## Layout
| File | Role |
|---|---|
| `GraphCardView.swift` | the card (board, legend, toolbar, sliders, resize, flatten) |
| `GraphCardModel.swift` | state, web messages, editing, debounced write-back |
| `GraphCardHost.swift` | host interface + environment key |
| `GraphEditors.swift` | expression popover, sliders, range editor |
| `Model/GraphExpression.swift` | lexer, parser, evaluator, wire format |
| `Model/GraphAnalysis.swift` | asymptotes, intercepts, extrema, inflections, number formatting |
| `Model/GraphDocument.swift` | editable spec + compiled expressions, normalization |
| `Model/GraphScene.swift` | render-ready scene shared by web + native renderers, themes |
| `Model/GraphPresets.swift` | presets, palette |
| `Render/GraphWebController.swift` | WKWebView bridge (JSON in, messages out) |
| `Render/GraphPlotView.swift` | native Canvas renderer (flatten, snapshots, loading placeholder) |
| `Resources/web/` | `inky-graph.html/js/css`, JSXGraph core + license |

## Tests (`App/HeyInkyTests/Graphs`, `App/HeyInkyUITests/GraphCardUITests.swift`)
- Parser: accepts model/student syntax, precedence, rejects 25 non-math inputs, limits.
- Analysis: poles (sampled and between samples), log edges, tan, horizontal/oblique, no false
  positives, intercepts/extrema/inflections, merge with model asymptotes.
- Presets: expected science (Vmax asymptote, −1/Km and 1/Vmax intercepts, projectile apex/range,
  inflection at K/2 and log EC50, SHM turning points).
- Card model: persistence, editing flow, board messages, resize, flatten, reload rules.
- Web board (real WKWebView): every preset plots, JS interpreter == Swift evaluator, patches don't
  rebuild, `eval`/`new Function`/`fetch` blocked, curve pixels in a snapshot.
- Snapshots: every preset light + dark (`__Snapshots__/`). Re-record with
  `TEST_RUNNER_INKY_RECORD_SNAPSHOTS=1`.
- UI: "plot" via the mock client → slider, range editor, expression edit + add slider, pan keeps
  the card in place, flatten (interactive parts skip until INTERFACE_REQUESTS #1 lands).

## Next steps
- Land INTERFACE_REQUESTS #1 (host) and #2 (schema: oblique, axis labels).
- Gliders (points constrained to a curve), shaded integrals, parametric/polar curves.
- Undo for card edits (via the page's undo manager).
