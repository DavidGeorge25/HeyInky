import Foundation

// Safe math expressions for graph cards.
//
// Expressions come from the model ("JavaScript Math syntax", e.g. `a*Math.sin(b*x)`) or from
// the student typing in the card. They are NEVER handed to a JavaScript engine as source:
// this parser accepts a small whitelist (numbers, `x`, declared params, a few constants,
// `Math.*` functions, arithmetic, comparisons, `?:`) and produces a `GraphExpr` tree. Swift
// evaluates the tree for analysis and the native renderer; the web view receives the tree as
// JSON data and interprets it with its own fixed function table (`inky-graph.js`).

/// Parsed expression. Params are resolved to indexes into the param list at parse time.
indirect enum GraphExpr: Hashable, Sendable {
    case number(Double)
    /// The independent variable (`x`, or `t` when no param is called `t`).
    case variable
    case param(Int)
    case negate(GraphExpr)
    case not(GraphExpr)
    case binary(GraphBinaryOp, GraphExpr, GraphExpr)
    case call(GraphMathFunction, [GraphExpr])
    case conditional(GraphExpr, GraphExpr, GraphExpr)
}

enum GraphBinaryOp: String, Hashable, Sendable, CaseIterable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", power = "^", modulo = "%"
    case less = "<", greater = ">", lessEqual = "<=", greaterEqual = ">=", equal = "==", notEqual = "!="
    case and = "&&", or = "||"
}

/// Every function an expression may call. Names follow JavaScript's `Math` (so `log` is the
/// natural log), plus a few student-friendly extras (`ln`, `sec`, `csc`, `cot`).
enum GraphMathFunction: String, Hashable, Sendable, CaseIterable {
    case sin, cos, tan, asin, acos, atan, atan2, sinh, cosh, tanh, asinh, acosh, atanh
    case sec, csc, cot
    case exp, expm1, log, ln, log10, log2, log1p
    case sqrt, cbrt, abs, floor, ceil, round, trunc, sign
    case min, max, pow, hypot

    var arity: ClosedRange<Int> {
        switch self {
        case .atan2, .pow: 2...2
        case .min, .max, .hypot: 1...8
        default: 1...1
        }
    }

    func apply(_ a: [Double]) -> Double {
        let x = a.first ?? .nan
        switch self {
        case .sin: return Foundation.sin(x)
        case .cos: return Foundation.cos(x)
        case .tan: return Foundation.tan(x)
        case .asin: return Foundation.asin(x)
        case .acos: return Foundation.acos(x)
        case .atan: return Foundation.atan(x)
        case .atan2: return Foundation.atan2(x, a[1])
        case .sinh: return Foundation.sinh(x)
        case .cosh: return Foundation.cosh(x)
        case .tanh: return Foundation.tanh(x)
        case .asinh: return Foundation.asinh(x)
        case .acosh: return Foundation.acosh(x)
        case .atanh: return Foundation.atanh(x)
        case .sec: return 1 / Foundation.cos(x)
        case .csc: return 1 / Foundation.sin(x)
        case .cot: return 1 / Foundation.tan(x)
        case .exp: return Foundation.exp(x)
        case .expm1: return Foundation.expm1(x)
        case .log, .ln: return Foundation.log(x)
        case .log10: return Foundation.log10(x)
        case .log2: return Foundation.log2(x)
        case .log1p: return Foundation.log1p(x)
        case .sqrt: return x.squareRoot()
        case .cbrt: return Foundation.cbrt(x)
        case .abs: return Swift.abs(x)
        case .floor: return x.rounded(.down)
        case .ceil: return x.rounded(.up)
        case .round: return (x + 0.5).rounded(.down) // JavaScript Math.round: halves round up
        case .trunc: return x.rounded(.towardZero)
        case .sign: return x.isNaN ? .nan : (x > 0 ? 1 : (x < 0 ? -1 : x))
        case .min: return a.contains(where: \.isNaN) ? .nan : a.min() ?? .nan
        case .max: return a.contains(where: \.isNaN) ? .nan : a.max() ?? .nan
        case .pow: return GraphExpr.power(x, a[1])
        case .hypot: return a.reduce(0) { $0 + $1 * $1 }.squareRoot()
        }
    }
}

struct GraphExpressionError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Short, calm explanation for the student.
    var message: String
    /// Character offset where the problem was found.
    var position: Int
    /// Set when the problem is an unknown name that could become a slider (e.g. `k`).
    var unknownIdentifier: String?

    var description: String { message }
}

extension GraphExpr {
    static let maxLength = 400
    static let maxDepth = 60

    /// Parses `source`. `params` are the declared parameter names, in order.
    static func parse(_ source: String, params: [String] = []) throws(GraphExpressionError) -> GraphExpr {
        guard source.count <= maxLength else {
            throw GraphExpressionError(message: "That expression is too long.", position: maxLength)
        }
        var parser = GraphExpressionParser(tokens: try GraphExpressionLexer.tokens(source), params: params)
        return try parser.parseAll()
    }

    // MARK: Evaluation

    func evaluate(x: Double, params: [Double]) -> Double {
        switch self {
        case .number(let v): return v
        case .variable: return x
        case .param(let i): return i < params.count ? params[i] : .nan
        case .negate(let e): return -e.evaluate(x: x, params: params)
        case .not(let e): return Self.truth(e.evaluate(x: x, params: params)) ? 0 : 1
        case .binary(let op, let l, let r):
            let a = l.evaluate(x: x, params: params)
            // Short-circuit like JavaScript (matters only for NaN propagation).
            switch op {
            case .and: return Self.truth(a) ? (Self.truth(r.evaluate(x: x, params: params)) ? 1 : 0) : 0
            case .or: return Self.truth(a) ? 1 : (Self.truth(r.evaluate(x: x, params: params)) ? 1 : 0)
            default: break
            }
            let b = r.evaluate(x: x, params: params)
            switch op {
            case .add: return a + b
            case .subtract: return a - b
            case .multiply: return a * b
            case .divide: return a / b
            case .power: return Self.power(a, b)
            case .modulo: return a.truncatingRemainder(dividingBy: b)
            case .less: return a < b ? 1 : 0
            case .greater: return a > b ? 1 : 0
            case .lessEqual: return a <= b ? 1 : 0
            case .greaterEqual: return a >= b ? 1 : 0
            case .equal: return a == b ? 1 : 0
            case .notEqual: return a != b ? 1 : 0
            case .and, .or: return .nan
            }
        case .call(let f, let args):
            return f.apply(args.map { $0.evaluate(x: x, params: params) })
        case .conditional(let c, let t, let e):
            return Self.truth(c.evaluate(x: x, params: params)) ? t.evaluate(x: x, params: params) : e.evaluate(x: x, params: params)
        }
    }

    static func truth(_ v: Double) -> Bool { !v.isNaN && v != 0 }

    /// `pow` with one student-friendly extension over JavaScript: odd roots of negatives are real,
    /// so `x^(1/3)` draws on both sides of 0.
    static func power(_ a: Double, _ b: Double) -> Double {
        // Rational exponents p/q with small odd q (1/3, 2/3, 1/5 …) are real for negative bases.
        if a < 0, b.isFinite, b.rounded() != b {
            for q in [3.0, 5, 7, 9] where (b * q).rounded() == b * q && Swift.abs(b * q) < 1e6 {
                let root = -Foundation.pow(-a, 1 / q)
                return Foundation.pow(root, (b * q).rounded())
            }
        }
        return Foundation.pow(a, b)
    }

    // MARK: Inspection

    /// Indexes of params the expression reads.
    var paramIndexes: Set<Int> {
        switch self {
        case .number, .variable: []
        case .param(let i): [i]
        case .negate(let e), .not(let e): e.paramIndexes
        case .binary(_, let l, let r): l.paramIndexes.union(r.paramIndexes)
        case .call(_, let args): args.reduce(into: Set<Int>()) { $0.formUnion($1.paramIndexes) }
        case .conditional(let c, let t, let e): c.paramIndexes.union(t.paramIndexes).union(e.paramIndexes)
        }
    }

    var usesVariable: Bool {
        switch self {
        case .number, .param: false
        case .variable: true
        case .negate(let e), .not(let e): e.usesVariable
        case .binary(_, let l, let r): l.usesVariable || r.usesVariable
        case .call(_, let args): args.contains(where: \.usesVariable)
        case .conditional(let c, let t, let e): c.usesVariable || t.usesVariable || e.usesVariable
        }
    }

    // MARK: Wire format for the web view

    /// Compact JSON-able tree: `["n",1]`, `["x"]`, `["p",0]`, `["neg",e]`, `["not",e]`,
    /// `["b","+",l,r]`, `["f","sin",[args]]`, `["?",c,t,e]`. Interpreted by `inky-graph.js`.
    var wire: GraphWireNode {
        switch self {
        case .number(let v): .array([.string("n"), .number(v)])
        case .variable: .array([.string("x")])
        case .param(let i): .array([.string("p"), .number(Double(i))])
        case .negate(let e): .array([.string("neg"), e.wire])
        case .not(let e): .array([.string("not"), e.wire])
        case .binary(let op, let l, let r): .array([.string("b"), .string(op.rawValue), l.wire, r.wire])
        case .call(let f, let args): .array([.string("f"), .string(f.rawValue), .array(args.map(\.wire))])
        case .conditional(let c, let t, let e): .array([.string("?"), c.wire, t.wire, e.wire])
        }
    }
}

/// Minimal JSON value used to ship expression trees to JavaScript.
enum GraphWireNode: Hashable, Sendable, Encodable {
    case number(Double)
    case string(String)
    case array([GraphWireNode])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v.isFinite ? v : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        }
    }
}

// MARK: - Lexer

enum GraphToken: Hashable, Sendable {
    case number(Double)
    case identifier(String)
    case op(String)
    case end
}

struct GraphPositionedToken: Hashable, Sendable {
    var token: GraphToken
    var position: Int
}

enum GraphExpressionLexer {
    private static let symbols = ["===", "!==", "**", "<=", ">=", "==", "!=", "&&", "||",
                                  "+", "-", "*", "/", "^", "%", "(", ")", ",", "?", ":", "<", ">", "!", "."]

    static func tokens(_ source: String) throws(GraphExpressionError) -> [GraphPositionedToken] {
        // Typographic forms students and models paste in.
        let normalized = source
            .replacingOccurrences(of: "·", with: "*").replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "²", with: "^2")
            .replacingOccurrences(of: "³", with: "^3")
        let chars = Array(normalized)
        var out: [GraphPositionedToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isASCII, c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                let start = i
                while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "." { i += 1 }
                // Exponent only when digits follow ("2e3", "1e-4"); "2e" alone is 2·e.
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                        i = j
                        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
                    }
                }
                let text = String(chars[start..<i])
                guard let value = Double(text) else {
                    throw GraphExpressionError(message: "“\(text)” isn't a number.", position: start)
                }
                out.append(GraphPositionedToken(token: .number(value), position: start))
                continue
            }
            if c.isASCII, c.isLetter || c == "_" {
                let start = i
                while i < chars.count, chars[i].isASCII, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
                out.append(GraphPositionedToken(token: .identifier(String(chars[start..<i])), position: start))
                continue
            }
            if let symbol = symbols.first(where: { matches($0, chars, at: i) }) {
                // JavaScript's strict equality means the same thing for numbers.
                let canonical = symbol == "===" ? "==" : symbol == "!==" ? "!=" : symbol == "**" ? "^" : symbol
                out.append(GraphPositionedToken(token: .op(canonical), position: i))
                i += symbol.count
                continue
            }
            throw GraphExpressionError(message: "“\(c)” can't be used in a graph expression.", position: i)
        }
        out.append(GraphPositionedToken(token: .end, position: chars.count))
        return out
    }

    private static func matches(_ symbol: String, _ chars: [Character], at i: Int) -> Bool {
        let s = Array(symbol)
        guard i + s.count <= chars.count else { return false }
        return Array(chars[i..<(i + s.count)]) == s
    }
}

// MARK: - Parser

/// Recursive descent, lowest precedence first:
/// ternary → `||` → `&&` → comparison → `+ -` → `* / %` (and implicit `2x`) → unary → `^`.
struct GraphExpressionParser {
    let tokens: [GraphPositionedToken]
    let params: [String]
    private var index = 0
    private var depth = 0

    init(tokens: [GraphPositionedToken], params: [String]) {
        self.tokens = tokens
        self.params = params
    }

    private static let constants: [String: Double] = [
        "pi": .pi, "PI": .pi, "e": M_E, "E": M_E,
    ]
    private static let mathConstants: [String: Double] = [
        "PI": .pi, "E": M_E, "LN2": M_LN2, "LN10": M_LN10, "LOG2E": M_LOG2E, "LOG10E": M_LOG10E,
        "SQRT2": 2.0.squareRoot(), "SQRT1_2": 0.5.squareRoot(),
    ]

    private var current: GraphPositionedToken { tokens[index] }

    mutating func parseAll() throws(GraphExpressionError) -> GraphExpr {
        if case .end = current.token {
            throw GraphExpressionError(message: "Type an expression in x, like 2*x + 1.", position: 0)
        }
        let expr = try parseTernary()
        guard case .end = current.token else { throw unexpected() }
        return expr
    }

    private mutating func advance() { if index < tokens.count - 1 { index += 1 } }

    private func isOp(_ s: String) -> Bool {
        if case .op(let o) = current.token { return o == s }
        return false
    }

    private mutating func expect(_ s: String) throws(GraphExpressionError) {
        guard isOp(s) else {
            throw GraphExpressionError(message: "Expected “\(s)” here.", position: current.position)
        }
        advance()
    }

    private func unexpected() -> GraphExpressionError {
        switch current.token {
        case .end: GraphExpressionError(message: "The expression stops too early.", position: current.position)
        case .op(let o) where o == ")": GraphExpressionError(message: "There's an extra “)”.", position: current.position)
        case .op(let o): GraphExpressionError(message: "“\(o)” isn't expected here.", position: current.position)
        case .number(let n): GraphExpressionError(message: "“\(GraphFormat.number(n))” isn't expected here.", position: current.position)
        case .identifier(let s): GraphExpressionError(message: "“\(s)” isn't expected here.", position: current.position)
        }
    }

    private mutating func nested<T>(_ body: (inout Self) throws(GraphExpressionError) -> T) throws(GraphExpressionError) -> T {
        depth += 1
        defer { depth -= 1 }
        guard depth <= GraphExpr.maxDepth else {
            throw GraphExpressionError(message: "That expression is nested too deeply.", position: current.position)
        }
        return try body(&self)
    }

    private mutating func parseTernary() throws(GraphExpressionError) -> GraphExpr {
        try nested { p throws(GraphExpressionError) in
            let condition = try p.parseOr()
            guard p.isOp("?") else { return condition }
            p.advance()
            let then = try p.parseTernary()
            try p.expect(":")
            let otherwise = try p.parseTernary()
            return .conditional(condition, then, otherwise)
        }
    }

    private mutating func parseOr() throws(GraphExpressionError) -> GraphExpr {
        var lhs = try parseAnd()
        while isOp("||") { advance(); lhs = .binary(.or, lhs, try parseAnd()) }
        return lhs
    }

    private mutating func parseAnd() throws(GraphExpressionError) -> GraphExpr {
        var lhs = try parseComparison()
        while isOp("&&") { advance(); lhs = .binary(.and, lhs, try parseComparison()) }
        return lhs
    }

    private mutating func parseComparison() throws(GraphExpressionError) -> GraphExpr {
        var lhs = try parseAdditive()
        while case .op(let o) = current.token, let op = GraphBinaryOp(rawValue: o),
              [.less, .greater, .lessEqual, .greaterEqual, .equal, .notEqual].contains(op) {
            advance()
            lhs = .binary(op, lhs, try parseAdditive())
        }
        return lhs
    }

    private mutating func parseAdditive() throws(GraphExpressionError) -> GraphExpr {
        var lhs = try parseMultiplicative()
        while true {
            if isOp("+") { advance(); lhs = .binary(.add, lhs, try parseMultiplicative()) }
            else if isOp("-") { advance(); lhs = .binary(.subtract, lhs, try parseMultiplicative()) }
            else { return lhs }
        }
    }

    private mutating func parseMultiplicative() throws(GraphExpressionError) -> GraphExpr {
        var lhs = try parseUnary()
        while true {
            if isOp("*") { advance(); lhs = .binary(.multiply, lhs, try parseUnary()) }
            else if isOp("/") { advance(); lhs = .binary(.divide, lhs, try parseUnary()) }
            else if isOp("%") { advance(); lhs = .binary(.modulo, lhs, try parseUnary()) }
            else if startsPrimary { lhs = .binary(.multiply, lhs, try parseUnary()) } // 2x, 3(x+1), (x+1)(x-1)
            else { return lhs }
        }
    }

    private var startsPrimary: Bool {
        switch current.token {
        case .number, .identifier: true
        case .op(let o): o == "("
        case .end: false
        }
    }

    private mutating func parseUnary() throws(GraphExpressionError) -> GraphExpr {
        try nested { p throws(GraphExpressionError) in
            if p.isOp("-") { p.advance(); return .negate(try p.parseUnary()) }
            if p.isOp("+") { p.advance(); return try p.parseUnary() }
            if p.isOp("!") { p.advance(); return .not(try p.parseUnary()) }
            return try p.parsePower()
        }
    }

    /// `^` binds tighter than unary minus on its left (−x² = −(x²)) and is right-associative.
    private mutating func parsePower() throws(GraphExpressionError) -> GraphExpr {
        let base = try parsePrimary()
        guard isOp("^") else { return base }
        advance()
        return .binary(.power, base, try parseUnary())
    }

    private mutating func parsePrimary() throws(GraphExpressionError) -> GraphExpr {
        let token = current
        switch token.token {
        case .number(let v):
            advance()
            return .number(v)
        case .op("("):
            advance()
            let inner = try parseTernary()
            guard isOp(")") else {
                throw GraphExpressionError(message: "A “(” is missing its “)”.", position: current.position)
            }
            advance()
            return inner
        case .identifier(let name):
            advance()
            if name == "Math" {
                try expect(".")
                guard case .identifier(let member) = current.token else { throw unexpected() }
                let position = current.position
                advance()
                if let value = Self.mathConstants[member] { return .number(value) }
                guard let function = GraphMathFunction(rawValue: member), member != "ln", member != "sec", member != "csc", member != "cot" else {
                    throw GraphExpressionError(message: "Math.\(member) isn't available in graphs.", position: position)
                }
                return try parseCall(function, name: "Math.\(member)", position: position)
            }
            if isOp(".") {
                throw GraphExpressionError(message: "“\(name).” isn't allowed — only Math.… functions.", position: token.position)
            }
            if let i = params.firstIndex(of: name) { return .param(i) }
            if name == "x" || name == "t" { return .variable }
            if let value = Self.constants[name] { return .number(value) }
            if let function = GraphMathFunction(rawValue: name) {
                return try parseCall(function, name: name, position: token.position)
            }
            if isOp("(") {
                throw GraphExpressionError(message: "“\(name)(…)” isn't a math function I know.", position: token.position)
            }
            let suggestion = Self.isSliderName(name) ? name : nil
            let hint = suggestion != nil ? " Add a slider for it?" : ""
            throw GraphExpressionError(message: "“\(name)” isn't defined.\(hint)", position: token.position, unknownIdentifier: suggestion)
        default:
            throw unexpected()
        }
    }

    private mutating func parseCall(_ function: GraphMathFunction, name: String, position: Int) throws(GraphExpressionError) -> GraphExpr {
        guard isOp("(") else {
            throw GraphExpressionError(message: "Use parentheses: \(name)(x).", position: position)
        }
        advance()
        var args: [GraphExpr] = []
        if !isOp(")") {
            args.append(try parseTernary())
            while isOp(",") { advance(); args.append(try parseTernary()) }
        }
        guard isOp(")") else {
            throw GraphExpressionError(message: "A “(” is missing its “)”.", position: current.position)
        }
        advance()
        guard function.arity.contains(args.count) else {
            let count = function.arity.lowerBound == function.arity.upperBound ? "\(function.arity.lowerBound)" : "\(function.arity.lowerBound)+"
            throw GraphExpressionError(message: "\(name) takes \(count) input\(count == "1" ? "" : "s").", position: position)
        }
        return .call(function, args)
    }

    /// Plausible slider names: short identifiers that aren't reserved words.
    static func isSliderName(_ name: String) -> Bool {
        let reserved: Set<String> = ["x", "t", "Math", "pi", "PI", "e", "E"]
        return name.count <= 12 && !reserved.contains(name) && GraphMathFunction(rawValue: name) == nil
            && name.first.map { $0.isLetter } == true
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
