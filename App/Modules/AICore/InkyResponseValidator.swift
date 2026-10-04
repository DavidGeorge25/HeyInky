import Foundation

/// Semantic checks on top of the strict JSON schema (which only guarantees shape and 0–1
/// coordinates). Small slips are repaired (a region poking 1% past the page edge is clamped);
/// real mistakes become problems the model is told about on its one retry.
///
/// Mirrored in `evals/inky_eval/validate.py`; both run against `/shared/fixtures/validation`.
enum InkyResponseValidator {
    enum Outcome: Equatable {
        case valid(InkyAction)
        case invalid(String)
    }

    /// How far past the page edge a region may reach before it counts as invented coordinates.
    static let edgeTolerance = 0.02
    static let minRegionSide = 0.004
    static let maxMarkArea = 0.85

    static func check(_ action: InkyAction) -> Outcome {
        check(action, request: nil)
    }

    /// `request` lets structure marks be checked against the structures the model was shown.
    static func check(_ action: InkyAction, request: InkyRequest?) -> Outcome {
        switch action {
        case .highlight(var a):
            switch checkRegion(a.region, what: "highlight") {
            case .failure(let p): return .invalid(p.description)
            case .success(let r): a.region = r
            }
            if a.region.width * a.region.height > maxMarkArea { return .invalid("highlight covers almost the whole page; mark only the target") }
            if let note = a.note, note.count > 60 { return .invalid("highlight note is too long (max ~4 words)") }
            return .valid(.highlight(a))
        case .circle(var a):
            switch checkRegion(a.region, what: "circle") {
            case .failure(let p): return .invalid(p.description)
            case .success(let r): a.region = r
            }
            if a.region.width * a.region.height > maxMarkArea { return .invalid("circle covers almost the whole page; circle only the target") }
            return .valid(.circle(a))
        case .star(let a):
            return .valid(.star(a))
        case .label(let a):
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .invalid("label text is empty") }
            if text.count > 80 { return .invalid("label text is too long (use 1–6 words; put explanations in openSidebar)") }
            return .valid(.label(a))
        case .fillText(var a):
            switch checkRegion(a.region, what: "fillText") {
            case .failure(let p): return .invalid(p.description)
            case .success(let r): a.region = r
            }
            if a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .invalid("fillText text is empty") }
            return .valid(.fillText(a))
        case .insertMoleculeCard(var a):
            a.smiles = a.smiles.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = smilesProblem(a.smiles) { return .invalid("insertMoleculeCard smiles \"\(a.smiles)\" is not valid SMILES: \(problem)") }
            for group in a.highlightGroups + a.starGroups {
                if let problem = smartsProblem(group) { return .invalid("insertMoleculeCard group \"\(group)\" is not valid SMARTS: \(problem)") }
            }
            switch checkRegion(a.near, what: "insertMoleculeCard near") {
            case .failure(let p): return .invalid(p.description)
            case .success(let r): a.near = r
            }
            return .valid(.insertMoleculeCard(a))
        case .insertGraphCard(var a):
            if let problem = graphProblem(a.spec) { return .invalid("insertGraphCard: \(problem)") }
            switch checkRegion(a.near, what: "insertGraphCard near") {
            case .failure(let p): return .invalid(p.description)
            case .success(let r): a.near = r
            }
            return .valid(.insertGraphCard(a))
        case .draw(let a):
            if let problem = drawProblem(a) { return .invalid("draw: \(problem)") }
            return .valid(.draw(a))
        case .annotateStructure(let a):
            if let problem = structureProblem(a, request: request) { return .invalid("annotateStructure: \(problem)") }
            return .valid(action)
        case .insertChemScheme(var a):
            if let problem = schemeProblem(&a) { return .invalid("insertChemScheme: \(problem)") }
            switch checkRegion(a.near, what: "insertChemScheme near") {
            case .failure(let p): return .invalid(p.description)
            case .success(let r): a.near = r
            }
            return .valid(.insertChemScheme(a))
        case .insertDiagram(var a):
            let svg = a.svg.trimmingCharacters(in: .whitespacesAndNewlines)
            if !svg.lowercased().hasPrefix("<svg") { return .invalid("insertDiagram: svg must be a single <svg …> element") }
            if svg.count > maxDiagramLength { return .invalid("insertDiagram: the SVG is too long (max \(maxDiagramLength) characters); simplify it") }
            if svg.lowercased().contains("<script") || svg.lowercased().contains("<foreignobject") || svg.lowercased().contains("<image") {
                return .invalid("insertDiagram: no scripts, images or foreignObject in the SVG")
            }
            a.svg = svg
            switch checkRegion(a.near, what: "insertDiagram near") {
            case .failure(let p): return .invalid(p.description)
            case .success(let r): a.near = r
            }
            return .valid(.insertDiagram(a))
        case .addPage:
            return .valid(action)
        case .openSidebar(let a):
            if a.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .invalid("openSidebar markdown is empty") }
            return .valid(.openSidebar(a))
        case .say(let a):
            let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .invalid("say text is empty") }
            if text.count > 400 { return .invalid("say is too long; keep it to one sentence and put longer explanations in openSidebar") }
            return .valid(.say(a))
        }
    }

    /// Whole-response checks after the per-action ones.
    static func responseProblems(_ response: InkyResponse, request: InkyRequest) -> [String] {
        var problems: [String] = []
        if response.actions.isEmpty && response.removeAnnotations.isEmpty {
            problems.append("the answer has no actions; include at least a say")
        }
        if response.actions.filter({ $0.type == .addPage }).count > 1 {
            problems.append("add at most one page per answer")
        }
        let unknown = response.removeAnnotations.filter { request.annotationID(forShortID: $0) == nil }
        if !unknown.isEmpty {
            let known = request.pageAnnotations.indices.map { "m\($0 + 1)" }.joined(separator: ", ")
            problems.append("removeAnnotations has unknown ids \(unknown) (existing marks: \(known.isEmpty ? "none" : known))")
        }
        return problems
    }

    // MARK: Structures and figures

    static let maxDiagramLength = 40_000
    static let maxSchemeSteps = 8

    static func structureProblem(_ a: AnnotateStructureAction, request: InkyRequest?) -> String? {
        guard let request else { return nil }
        guard let structure = request.structure(a.structure) else {
            if request.structures.isEmpty { return "no structures were recognized on this page, so there is nothing to annotate by id; use draw instead" }
            return "there is no structure \(a.structure) (recognized: \(request.structures.map(\.id).joined(separator: ", ")))"
        }
        func known(_ id: String) -> Bool { id.lowercased() == "all" || structure.atomIndex(id) != nil }
        var ids = a.hydrogens + a.lonePairs + a.relabel.map(\.atom) + a.charges.map(\.atom) + a.labels.map(\.atom)
        ids += a.highlights.flatMap(\.atoms)
        for arrow in a.arrows {
            ids += [arrow.from, arrow.to].flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "=" || $0 == "," }).map(String.init) }
        }
        let unknown = Set(ids.filter { !known($0) })
        if !unknown.isEmpty {
            return "\(structure.id) has no atom(s) \(unknown.sorted().joined(separator: ", ")) (atoms are a1…a\(structure.atoms.count))"
        }
        if a.highlights.contains(where: { $0.atoms.isEmpty && ($0.group ?? "").isEmpty }) {
            return "each highlight needs atoms or a group"
        }
        if a.hydrogens.isEmpty && a.lonePairs.isEmpty && a.charges.isEmpty && a.highlights.isEmpty && a.labels.isEmpty && a.arrows.isEmpty {
            return "nothing to add; fill at least one list"
        }
        return nil
    }

    static func schemeProblem(_ a: inout InsertChemSchemeAction) -> String? {
        if a.steps.isEmpty { return "add at least one structure" }
        if a.steps.count > maxSchemeSteps { return "too many structures (max \(maxSchemeSteps))" }
        for (i, step) in a.steps.enumerated() {
            let smiles = step.smiles.trimmingCharacters(in: .whitespacesAndNewlines)
            if smiles.contains(">") { return "step \(i) is a reaction SMILES; give each structure as its own step with a reaction connector" }
            if let problem = smilesProblem(smiles) { return "step \(i) smiles \"\(smiles)\" is not valid SMILES: \(problem)" }
            a.steps[i].smiles = smiles
        }
        // One connector per gap: repair small miscounts rather than reject.
        let gaps = a.steps.count - 1
        if a.connectors.count > gaps { a.connectors = Array(a.connectors.prefix(gaps)) }
        while a.connectors.count < gaps {
            a.connectors.append(.init(kind: a.connectors.last?.kind ?? .reaction, above: nil, below: nil))
        }
        func maps(_ step: Int) -> Set<String> {
            guard step >= 0, step < a.steps.count else { return [] }
            let smiles = a.steps[step].smiles
            var found = Set<String>()
            var digits = ""
            var inMap = false
            for c in smiles {
                if c == ":" { inMap = true; digits = ""; continue }
                if inMap {
                    if c.isNumber { digits.append(c) } else { if c == "]", !digits.isEmpty { found.insert(digits) }; inMap = false }
                }
            }
            return found
        }
        for arrow in a.arrows {
            guard arrow.step >= 0, arrow.step < a.steps.count else { return "arrow step \(arrow.step) doesn't exist (steps are 0…\(a.steps.count - 1))" }
            let available = maps(arrow.step)
            let refs = [arrow.from, arrow.to].flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "=" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) } }
            if let missing = refs.first(where: { !available.contains($0) }) {
                return "arrow refers to atom map number \(missing), but step \(arrow.step)'s SMILES has no atom written with :\(missing) (e.g. [O-:\(missing)])"
            }
        }
        for lp in a.lonePairs where !maps(lp.step).contains(lp.atom) {
            return "lone pair refers to atom map number \(lp.atom), which step \(lp.step)'s SMILES doesn't have"
        }
        for h in a.highlights where !h.atoms.allSatisfy(maps(h.step).contains) {
            return "a highlight refers to atom map numbers missing from step \(h.step)'s SMILES"
        }
        return nil
    }

    // MARK: Drawings

    static let maxDrawShapes = 80
    static let maxDrawPoints = 800

    static func drawProblem(_ a: DrawAction) -> String? {
        if a.shapes.isEmpty { return "add at least one shape" }
        if a.shapes.count > maxDrawShapes { return "too many shapes (max \(maxDrawShapes)); draw the essentials" }
        if a.shapes.reduce(0, { $0 + $1.points.count }) > maxDrawPoints { return "too many points (max \(maxDrawPoints))" }
        for (i, shape) in a.shapes.enumerated() {
            let n = shape.points.count
            let name = "shape \(i + 1) (\(shape.kind.rawValue))"
            if shape.points.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) { return "\(name) has non-numeric points" }
            switch shape.kind {
            case .line, .dashedLine, .arrow, .doubleArrow, .polyline:
                if n < 2 { return "\(name) needs at least 2 points" }
            case .curvedArrow:
                if n < 2 || n > 3 { return "\(name) needs [start, end] or [start, through, end]" }
            case .polygon:
                if n < 3 { return "\(name) needs at least 3 points" }
            case .ellipse:
                if n != 2 { return "\(name) needs exactly 2 points: its box's top-left and bottom-right" }
            case .text:
                if n < 1 { return "\(name) needs its top-left point" }
                let text = shape.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty { return "\(name) has no text" }
                if text.count > 400 { return "\(name) text is too long (max ~400 characters; split it or add a page)" }
            }
            if shape.kind != .text, n >= 2 {
                let xs = shape.points.map(\.x), ys = shape.points.map(\.y)
                if (xs.max()! - xs.min()!) + (ys.max()! - ys.min()!) < 0.002 { return "\(name) has zero length; its points are all the same" }
            }
        }
        return nil
    }

    // MARK: Regions

    static func checkRegion(_ r: NormRect, what: String) -> Result<NormRect, Problem> {
        let values = [r.x, r.y, r.width, r.height]
        if values.contains(where: { !$0.isFinite }) { return .failure(Problem("\(what) region has non-numeric values")) }
        if r.width < minRegionSide || r.height < minRegionSide {
            return .failure(Problem("\(what) region \(InkyPromptBuilder.format(r)) is empty; give the target's real width and height"))
        }
        if r.x < -edgeTolerance || r.y < -edgeTolerance || r.maxX > 1 + edgeTolerance || r.maxY > 1 + edgeTolerance {
            return .failure(Problem("\(what) region \(InkyPromptBuilder.format(r)) extends outside the page; x+width and y+height must be ≤ 1"))
        }
        return .success(r.clamped)
    }

    struct Problem: Error, Equatable, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Chemistry (syntax only; RDKit in the Chemistry module does the real parse)

    static func smilesProblem(_ smiles: String) -> String? {
        if smiles.isEmpty { return "empty" }
        if smiles.contains(where: \.isWhitespace) { return "contains spaces" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789[]()=#$:/\\@+-.%*~")
        if smiles.unicodeScalars.contains(where: { !allowed.contains($0) }) { return "unexpected characters" }
        if !balanced(smiles, open: "(", close: ")") { return "unbalanced parentheses" }
        if !balanced(smiles, open: "[", close: "]") { return "unbalanced brackets" }
        if !smiles.contains(where: \.isLetter) { return "no atoms" }
        // Ring-closure digits outside brackets must pair up.
        var open = Set<String>()
        var inBracket = false
        var chars = Array(smiles)[...]
        while let ch = chars.popFirst() {
            if ch == "[" { inBracket = true; continue }
            if ch == "]" { inBracket = false; continue }
            guard !inBracket else { continue }
            var label: String?
            if ch == "%" {
                let two = String(chars.prefix(2))
                chars = chars.dropFirst(2)
                label = "%" + two
            } else if ch.isNumber {
                label = String(ch)
            }
            if let label {
                if open.contains(label) { open.remove(label) } else { open.insert(label) }
            }
        }
        if !open.isEmpty { return "unclosed ring bond(s) \(open.sorted())" }
        return nil
    }

    static func smartsProblem(_ smarts: String) -> String? {
        let s = smarts.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "empty" }
        if !balanced(s, open: "(", close: ")") { return "unbalanced parentheses" }
        if !balanced(s, open: "[", close: "]") { return "unbalanced brackets" }
        return nil
    }

    private static func balanced(_ s: String, open: Character, close: Character) -> Bool {
        var depth = 0
        for ch in s {
            if ch == open { depth += 1 }
            if ch == close { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }

    // MARK: Graphs

    static let mathMembers: Set<String> = [
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
        "exp", "expm1", "log", "log10", "log2", "log1p", "sqrt", "cbrt", "abs", "pow", "floor", "ceil", "round",
        "trunc", "sign", "min", "max", "hypot", "PI", "E", "LN2", "LN10", "SQRT2",
    ]

    static func graphProblem(_ spec: GraphSpec) -> String? {
        let numbers = [spec.xMin, spec.xMax, spec.yMin, spec.yMax]
        if numbers.contains(where: { !$0.isFinite }) { return "axis ranges must be numbers" }
        if spec.xMin >= spec.xMax { return "xMin must be less than xMax" }
        if spec.yMin >= spec.yMax { return "yMin must be less than yMax" }
        if spec.functions.isEmpty { return "add at least one function" }
        for a in spec.asymptotes {
            if !a.value.isFinite { return "asymptote value must be a number" }
            if a.orientation == .oblique && !(a.slope.map(\.isFinite) ?? false) { return "an oblique asymptote needs a slope" }
        }
        let paramNames = Set(spec.params.map(\.name))
        for p in spec.params {
            if p.name.isEmpty || !p.name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) || p.name.first!.isNumber {
                return "param name \"\(p.name)\" must be an identifier"
            }
            if p.name == "x" { return "\"x\" is the variable, not a param" }
            if !(p.min <= p.value && p.value <= p.max) || p.min == p.max { return "param \(p.name) needs min < max and min ≤ value ≤ max" }
        }
        for f in spec.functions {
            if let problem = expressionProblem(f.expression, params: paramNames) {
                return "expression \"\(f.expression)\": \(problem)"
            }
        }
        return nil
    }

    /// Allows JavaScript arithmetic in `x`, the param names and `Math.*` only.
    static func expressionProblem(_ expression: String, params: Set<String>) -> String? {
        let e = expression.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return "empty" }
        if e.contains("^") { return "use Math.pow(a, b) or a**b instead of ^" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-*/%().,<>=?:!&| ")
        if e.unicodeScalars.contains(where: { !allowed.contains($0) }) { return "only JavaScript math is allowed (no Unicode symbols like ² or π)" }
        if !balanced(e, open: "(", close: ")") { return "unbalanced parentheses" }
        // Identifiers: x, params, Math.member. Numbers like 1e-3 are fine.
        let chars = Array(e)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isNumber || (ch == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                // Skip a numeric literal including exponent.
                i += 1
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E" ||
                        ((chars[i] == "-" || chars[i] == "+") && (chars[i - 1] == "e" || chars[i - 1] == "E")) {
                    i += 1
                }
                continue
            }
            if ch.isLetter || ch == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let name = String(chars[i..<j])
                if name == "Math" {
                    guard j < chars.count, chars[j] == "." else { return "Math must be followed by a member" }
                    var k = j + 1
                    while k < chars.count, chars[k].isLetter || chars[k].isNumber { k += 1 }
                    let member = String(chars[(j + 1)..<k])
                    if !mathMembers.contains(member) { return "Math.\(member) is not supported" }
                    i = k
                    continue
                }
                if name != "x" && !params.contains(name) {
                    return "unknown name \"\(name)\" (use x, the param names, and Math.*; declare constants as params)"
                }
                i = j
                continue
            }
            i += 1
        }
        return nil
    }
}
