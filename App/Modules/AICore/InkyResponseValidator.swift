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
        let unknown = response.removeAnnotations.filter { request.annotationID(forShortID: $0) == nil }
        if !unknown.isEmpty {
            let known = request.pageAnnotations.indices.map { "m\($0 + 1)" }.joined(separator: ", ")
            problems.append("removeAnnotations has unknown ids \(unknown) (existing marks: \(known.isEmpty ? "none" : known))")
        }
        return problems
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
