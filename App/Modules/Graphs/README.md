# Graphs

Interactive graph cards for `insertGraphCard` actions.

## Interface you must implement
```swift
struct GraphCardView: View {
    let action: InsertGraphCardAction   // spec: GraphSpec, near: NormRect
    var body: some View { … }
}
```
- Keep the type name and `init(action:)`. The Inky layer wraps it in `InkyCardContainer`
  (title = `spec.title`) and sizes it to the card frame (min 300×220 page points, scaled with zoom).
- The current file is a **stub** placeholder; replace its body.
- Keep accessibility identifier `inky.card.graph` on your root view.

## GraphSpec (from the schema)
`title?`, `xMin/xMax/yMin/yMax`, `functions[{expression, label?, color?}]`,
`params[{name, min, max, value, step?}]`, `asymptotes[{orientation: vertical|horizontal, value, label?}]`,
`points[{x, y, label?, draggable}]`, `labels[{x, y, text}]`.
Expressions are JavaScript math in `x` and param names, e.g. `a*Math.sin(b*x)`.

## Requirements
- Render with **JSXGraph** in a `WKWebView`; bundle the library offline under
  `Modules/Graphs/Resources/web/` (no CDN at runtime).
- One slider per param; functions re-evaluate live; draggable points draggable.
- **Never `eval` raw model strings unguarded**: compile expressions with a whitelist (`Math.*`,
  numbers, operators, `x`, declared params) or a small expression parser; show a calm error otherwise.
- Persist slider values / dragged points back into the annotation (update the spec via
  `PageEditorModel.updateAnnotation`) so the card reopens as the student left it.
- Editable: let the student change the expression and ranges (small inline editor).
- Touches inside the card must work (the overlay claims touches within card bounds).

## Tests to add
- Unit: expression whitelist accepts `a*Math.sin(b*x)`, rejects `fetch(…)`/`window`.
- UI: "plot this" via the mock client inserts a graph card; assert `inky.card.graph` exists.
