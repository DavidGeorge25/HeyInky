# Interface requests

Changes other owners are asked to make. Newest first. Each says who owns it, why, and exactly what.

## From Graphs (feat/graphs)

### 1. Shell: give graph cards a host (persist / resize / flatten) — owner: lead
**Why.** `GraphCardView(action:)` is fully interactive on its own, but it can only write edits
back (slider values, expressions, ranges, pan/zoom view, dragged points), resize itself, or
flatten into an image through `GraphCardHost` from the environment
(`App/Modules/Graphs/GraphCardHost.swift`). Without a host nothing persists and the resize
handle / "Flatten into page" are hidden.

Also: the annotation wrapper uses `.accessibilityElement(children: .combine)`, which hides the
card's controls from VoiceOver and UI tests. Cards need `.contain`.
`GraphCardUITests` skip their interactive parts until this lands.

**Patch (verified locally: full unit + UI suites green, flatten/resize/persist exercised in the
simulator).** Apply as-is:

```diff
diff --git a/App/HeyInky/InkyLayer/InkyLayerView.swift b/App/HeyInky/InkyLayer/InkyLayerView.swift
index 5ca58d2..7ea3189 100644
--- a/App/HeyInky/InkyLayer/InkyLayerView.swift
+++ b/App/HeyInky/InkyLayer/InkyLayerView.swift
@@ -27,6 +27,7 @@ struct InkyLayerView: View {
                     let isSelected = editor.selectedAnnotationID == annotation.id
                     let rect = InkyAnnotationGeometry.bounds(for: annotation, pageSize: pageSize).cgRect(in: geo.size)
                     InkyAnnotationView(annotation: annotation, pageSize: pageSize, scale: scale)
+                        .environment(\.graphCardHost, graphCardHost(for: annotation, pageSize: pageSize))
                         .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                         .overlay {
                             if isSelected {
@@ -44,7 +45,7 @@ struct InkyLayerView: View {
                             editor.selectedAnnotationID = isSelected ? nil : annotation.id
                         }
                         .gesture(isSelected ? moveGesture(annotation, viewSize: geo.size) : nil)
-                        .accessibilityElement(children: .combine)
+                        .accessibilityElement(children: annotation.action.type == .insertGraphCard ? .contain : .combine)
                         .accessibilityIdentifier("inky.annotation.\(annotation.action.type.rawValue)")
                         .accessibilityLabel(Self.accessibilityLabel(for: annotation.action))
                         .accessibilityAddTraits(.isButton)
@@ -72,6 +73,21 @@ struct InkyLayerView: View {
         }
     }
 
+    /// Lets a graph card persist its edits, resize itself and flatten into an image.
+    private func graphCardHost(for annotation: InkyAnnotation, pageSize: CGSize) -> GraphCardHost? {
+        guard case .insertGraphCard = annotation.action else { return nil }
+        let id = annotation.id
+        return GraphCardHost(
+            pageSize: pageSize,
+            update: { [editor] action in
+                guard var current = editor.annotations.first(where: { $0.id == id }) else { return }
+                current.action = .insertGraphCard(action)
+                editor.updateAnnotation(current)
+            },
+            flatten: { [editor] image in editor.replaceAnnotationWithImage(id, image: image) }
+        )
+    }
+
     private func moveGesture(_ annotation: InkyAnnotation, viewSize: CGSize) -> some Gesture {
         DragGesture(minimumDistance: 4)
             .updating($dragTranslation) { value, state, _ in state = value.translation }
diff --git a/App/HeyInky/Page/PageEditorModel.swift b/App/HeyInky/Page/PageEditorModel.swift
index 2df965b..96626a1 100644
--- a/App/HeyInky/Page/PageEditorModel.swift
+++ b/App/HeyInky/Page/PageEditorModel.swift
@@ -104,6 +104,18 @@ final class PageEditorModel {
         saveAnnotations()
     }
 
+    /// Replaces an annotation (a flattened card) with a placed image at the same frame.
+    func replaceAnnotationWithImage(_ id: UUID, image: UIImage) {
+        guard let annotation = annotations.first(where: { $0.id == id }), let data = image.pngData() else { return }
+        let frame = InkyAnnotationGeometry.bounds(for: annotation, pageSize: page.size)
+        guard var placed = try? store.addImage(data, to: page.id, in: notebookID, center: frame.center) else { return }
+        placed.frame = frame
+        imageInsertedExternally(placed)
+        updateImage(placed)
+        selectedImageID = nil
+        deleteAnnotation(id)
+    }
+
     private func saveAnnotations() {
         store.saveAnnotations(annotations, for: page.id, in: notebookID)
     }
```

### 2. Schema: oblique asymptotes and axis labels — owners: lead + AI agent (`/shared`)
**Why.** The card detects oblique asymptotes and draws axis labels, but the model can't
specify either:
- `asymptotes[].orientation` only allows `vertical | horizontal`.
- `graphSpec` has no axis labels; today presets are recognized by title to get `[S]`, `v₀`, etc.

**Proposed (strict-mode style, `type`-first ordering unaffected):**
- `asymptote.orientation` enum += `"oblique"`; add `slope: ["number","null"]` (required, null
  unless oblique; `value` = y-intercept for oblique).
- `graphSpec` += `xLabel: ["string","null"]`, `yLabel: ["string","null"]` (required).
- Swift mirror: `GraphSpec.Orientation.oblique`, `Asymptote.slope: Double?`,
  `GraphSpec.xLabel/yLabel: String?`; fixtures updated.

**Graphs side once landed (small):** `GraphDocument.analysis()` maps `.oblique` to
`GraphAsymptoteLine.oblique(slope:intercept:)` (renderers already draw it), and
`GraphPresets.axisLabels(for:)` prefers `spec.xLabel/yLabel`.

### 3. Prompt (optional) — owner: AI agent
Mention in `inky_system_prompt.md` that graph expressions may also use `^`, `ln`, implicit
multiplication, `?:` for piecewise, and that preset titles ("Michaelis–Menten",
"Lineweaver–Burk", "Logistic growth", "Dose–response", "Exponential growth",
"Projectile motion", "Simple harmonic motion") get subject-specific axis labels.
