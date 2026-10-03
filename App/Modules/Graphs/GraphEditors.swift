import SwiftUI

/// Minimal inline field for one function's expression. Valid input redraws live; invalid
/// input shows a calm message and keeps the last good curve.
struct GraphExpressionEditor: View {
    @Bindable var model: GraphCardModel
    let k: Double
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * k) {
            HStack(spacing: 6 * k) {
                if let i = model.editingFunction, let doc = model.document, doc.spec.functions.indices.contains(i) {
                    Text("\(doc.functionName(at: i)) =")
                        .font(.system(size: 12 * k, weight: .semibold, design: .rounded))
                        .foregroundStyle(GraphTheme.color(GraphPalette.color(for: doc.spec.functions[i].color, index: i, dark: model.currentTheme.dark)))
                }
                TextField("expression in x", text: $model.draft)
                    .font(.system(size: 13 * k, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($focused)
                    .onChange(of: model.draft) { model.draftChanged() }
                    .onSubmit { model.finishEditing() }
                    .padding(.horizontal, 8 * k)
                    .padding(.vertical, 5 * k)
                    .background(RoundedRectangle(cornerRadius: 7 * k).fill(GraphTheme.color(model.currentTheme.grid)))
                    .accessibilityIdentifier("inky.graph.expression")
                Button { model.deleteEditedFunction() } label: {
                    Image(systemName: "trash").font(.system(size: 12 * k))
                }
                .buttonStyle(.plain)
                .foregroundStyle(GraphTheme.color(model.currentTheme.muted))
                .accessibilityIdentifier("inky.graph.expression.delete")
                .accessibilityLabel("Delete function")
                Button { model.finishEditing() } label: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18 * k))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("inky.graph.expression.done")
                .accessibilityLabel("Done")
            }
            if let error = model.draftError {
                HStack(spacing: 6 * k) {
                    Text(error.message)
                        .font(.system(size: 10.5 * k, design: .rounded))
                        .foregroundStyle(GraphTheme.color(model.currentTheme.muted))
                        .accessibilityIdentifier("inky.graph.expression.error")
                    if let name = error.unknownIdentifier {
                        Button("Add slider \(name)") { model.addSliderForDraftUnknown() }
                            .font(.system(size: 10.5 * k, weight: .semibold, design: .rounded))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .accessibilityIdentifier("inky.graph.expression.addSlider")
                    }
                }
            }
        }
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 7 * k)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .onAppear { focused = true }
    }
}

/// One slider per param. Tap a slider's name/value to edit its min, max and step.
struct GraphParamSliders: View {
    @Bindable var model: GraphCardModel
    let k: Double
    let maxHeight: CGFloat

    var body: some View {
        let params = model.spec?.params ?? []
        ScrollView(.vertical) {
            VStack(spacing: 2 * k) {
                ForEach(Array(params.enumerated()), id: \.offset) { i, p in
                    row(i, p)
                }
            }
            .padding(.horizontal, 10 * k)
            .padding(.vertical, 5 * k)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(maxHeight, CGFloat(Double(params.count) * 30 * k + 10 * k)))
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private func row(_ i: Int, _ p: GraphSpec.Param) -> some View {
        HStack(spacing: 8 * k) {
            Button { model.editingParam = i } label: {
                HStack(spacing: 3 * k) {
                    Text(p.name).fontWeight(.semibold)
                    Text("= \(GraphFormat.number(p.value))").monospacedDigit()
                }
                .font(.system(size: 11.5 * k, design: .rounded))
                .foregroundStyle(GraphTheme.color(model.currentTheme.text))
                .frame(minWidth: 70 * k, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inky.graph.param.\(p.name).edit")
            .popover(isPresented: Binding(get: { model.editingParam == i }, set: { if !$0 { model.editingParam = nil } })) {
                GraphRangeEditor(model: model, index: i, param: p)
            }

            Text(GraphFormat.number(p.min))
                .font(.system(size: 9 * k, design: .rounded))
                .foregroundStyle(GraphTheme.color(model.currentTheme.muted))
            slider(i, p)
            Text(GraphFormat.number(p.max))
                .font(.system(size: 9 * k, design: .rounded))
                .foregroundStyle(GraphTheme.color(model.currentTheme.muted))
        }
        .frame(height: 28 * k)
    }

    @ViewBuilder
    private func slider(_ i: Int, _ p: GraphSpec.Param) -> some View {
        let value = Binding<Double>(
            get: { model.spec?.params[safe: i]?.value ?? p.value },
            set: { model.setParam(i, to: $0) }
        )
        Group {
            if let step = p.step, step > 0, step < p.max - p.min {
                Slider(value: value, in: p.min...p.max, step: step)
            } else {
                Slider(value: value, in: p.min...p.max)
            }
        }
        .tint(Theme.accent)
        .controlSize(.mini)
        .accessibilityIdentifier("inky.graph.param.\(p.name)")
        .accessibilityLabel(p.name)
    }
}

/// Popover for a slider's range.
struct GraphRangeEditor: View {
    let model: GraphCardModel
    let index: Int
    let param: GraphSpec.Param
    @State private var minText = ""
    @State private var maxText = ""
    @State private var stepText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Slider \(param.name)")
                .font(.system(.headline, design: .rounded))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                field("Min", $minText, id: "min")
                field("Max", $maxText, id: "max")
                field("Step", $stepText, id: "step", placeholder: "auto")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("inky.graph.range.error")
            }
            HStack {
                Button(role: .destructive) { model.removeParam(index) } label: { Text("Remove") }
                    .accessibilityIdentifier("inky.graph.range.remove")
                Spacer()
                Button("Done") { apply() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("inky.graph.range.done")
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            minText = GraphFormat.plain(param.min)
            maxText = GraphFormat.plain(param.max)
            stepText = param.step.map(GraphFormat.plain) ?? ""
        }
    }

    private func field(_ title: String, _ text: Binding<String>, id: String, placeholder: String = "") -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .onSubmit(apply)
                .accessibilityIdentifier("inky.graph.range.\(id)")
        }
    }

    private func apply() {
        guard let lo = GraphFormat.parse(minText), let hi = GraphFormat.parse(maxText) else {
            error = "Min and max need to be numbers."
            return
        }
        let trimmedStep = stepText.trimmingCharacters(in: .whitespaces)
        let step: Double?
        if trimmedStep.isEmpty { step = nil } else if let s = GraphFormat.parse(trimmedStep) { step = s } else {
            error = "Step needs to be a number (or empty for smooth)."
            return
        }
        do {
            try model.setParamRange(index, min: lo, max: hi, step: step)
            model.editingParam = nil
        } catch {
            self.error = error.message
        }
    }
}

extension GraphFormat {
    /// Plain ASCII for text fields ("-0.5", not "−0.5").
    static func plain(_ v: Double) -> String { number(v).replacingOccurrences(of: "−", with: "-") }

    /// Parses a typed number; also accepts constants and simple arithmetic ("2*pi", "1/3").
    static func parse(_ text: String) -> Double? {
        guard let e = try? GraphExpr.parse(text), !e.usesVariable, e.paramIndexes.isEmpty else { return nil }
        let v = e.evaluate(x: 0, params: [])
        return v.isFinite ? v : nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
