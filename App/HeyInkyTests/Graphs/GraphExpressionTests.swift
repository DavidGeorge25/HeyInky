import Foundation
import Testing
@testable import HeyInky

@Suite("Graph expression parser")
struct GraphExpressionTests {
    func value(_ source: String, x: Double = 0, params: [String: Double] = [:]) throws -> Double {
        let names = Array(params.keys).sorted()
        let expr = try GraphExpr.parse(source, params: names)
        return expr.evaluate(x: x, params: names.map { params[$0]! })
    }

    func error(_ source: String, params: [String] = []) -> GraphExpressionError? {
        do { _ = try GraphExpr.parse(source, params: params); return nil } catch { return error }
    }

    // MARK: Accepts the model's JavaScript Math style

    @Test func acceptsModelStyleExpressions() throws {
        #expect(try value("a*Math.sin(b*x)", x: .pi / 2, params: ["a": 2, "b": 1]) == 2)
        #expect(try value("Math.exp(-k*x)", x: 1, params: ["k": 0]) == 1)
        #expect(try value("Math.pow(x, 2) + Math.sqrt(x)", x: 4) == 18)
        #expect(try value("Math.log(Math.E)") == 1)
        #expect(try value("Math.PI") == .pi)
        #expect(try value("Math.max(1, x, 3)", x: 5) == 5)
        #expect(try value("Math.atan2(1, 1)") == .pi / 4)
        #expect(try value("x ** 2", x: 3) == 9)
        #expect(try value("Math.abs(x) === 2 ? 1 : 0", x: -2) == 1)
    }

    @Test func studentFriendlySyntax() throws {
        #expect(try value("2x", x: 3) == 6)
        #expect(try value("3(x+1)", x: 1) == 6)
        #expect(try value("(x+1)(x-1)", x: 3) == 8)
        #expect(try value("x^2", x: 3) == 9)
        #expect(abs(try value("sin(x)^2 + cos(x)^2", x: 0.7) - 1) < 1e-15)
        #expect(try value("ln(e)") == 1)
        #expect(try value("2pi") == 2 * .pi)
        #expect(try value("2·x − 1", x: 2) == 3)
        #expect(try value("x²", x: 4) == 16)
        #expect(try value("π") == .pi)
        #expect(try value("t*2", x: 5) == 10, "t is the independent variable when no param is called t")
        #expect(try value("t*2", x: 5, params: ["t": 1]) == 2, "a param named t wins")
    }

    @Test func precedenceAndAssociativity() throws {
        #expect(try value("-x^2", x: 3) == -9)
        #expect(try value("2^3^2") == 512)
        #expect(try value("2^-1") == 0.5)
        #expect(try value("1 - 2 - 3") == -4)
        #expect(try value("12 / 2 / 3") == 2)
        #expect(try value("2 + 3 * 4") == 14)
        #expect(try value("x < 0 ? -1 : x < 1 ? 0 : 1", x: 0.5) == 0)
        #expect(try value("x > 1 && x < 3", x: 2) == 1)
        #expect(try value("!(x > 1) || x == 5", x: 5) == 1)
        #expect(try value("7 % 3") == 1)
    }

    @Test func numbers() throws {
        #expect(try value("1e-3") == 0.001)
        #expect(try value("2.5E2") == 250)
        #expect(try value(".5") == 0.5)
        #expect(try value("2e") == 2 * M_E, "2e without digits is 2·e")
    }

    @Test func realOddRootsOfNegatives() throws {
        #expect(abs(try value("x^(1/3)", x: -8) - -2) < 1e-12)
        #expect(abs(try value("Math.pow(x, 2/3)", x: -8) - 4) < 1e-12)
        #expect(try value("Math.sqrt(x)", x: -1).isNaN)
        #expect(try value("Math.round(-2.5)") == -2, "JavaScript rounding: halves go up")
    }

    @Test func reportsParamsAndVariableUse() throws {
        let e = try GraphExpr.parse("a*x + b", params: ["a", "b", "c"])
        #expect(e.paramIndexes == [0, 1])
        #expect(e.usesVariable)
        #expect(try !GraphExpr.parse("Vmax/2", params: ["Vmax"]).usesVariable)
    }

    // MARK: Rejects anything that isn't math

    @Test(arguments: [
        "fetch('https://example.com')", "window", "window.location", "alert(1)", "document.cookie",
        "x.constructor", "constructor", "this", "globalThis", "eval('1')", "Function('return 1')()",
        "Math.random()", "Math.constructor", "x; alert(1)", "x = 1", "[1,2]", "{}", "`x`", "\"x\"",
        "x => x", "new Date()", "import('x')", "process.exit()", "__proto__", "Math['sin'](x)",
    ])
    func rejectsNonMath(_ source: String) {
        #expect(error(source) != nil, "\(source) must be rejected")
    }

    @Test func calmErrorMessages() {
        #expect(error("sin(x")?.message == "A “(” is missing its “)”.")
        #expect(error("x)")?.message == "There's an extra “)”.")
        #expect(error("")?.message.contains("Type an expression") == true)
        #expect(error("sin x")?.message == "Use parentheses: sin(x).")
        #expect(error("pow(x)")?.message == "pow takes 2 inputs.")
        #expect(error("foo(x)")?.message.contains("isn't a math function") == true)
        #expect(error("x +")?.message == "The expression stops too early.")
        #expect(error("x $ 2")?.message.contains("can't be used") == true)
        #expect(error("Math.random()")?.message == "Math.random isn't available in graphs.")
    }

    @Test func unknownNamesSuggestASlider() {
        let e = error("k*x")
        #expect(e?.unknownIdentifier == "k")
        #expect(e?.message.contains("Add a slider") == true)
        #expect(error("fetch")?.unknownIdentifier == "fetch", "still rejected; only offered as a slider name")
        #expect(error("x.y")?.unknownIdentifier == nil)
    }

    @Test func limitsSizeAndNesting() {
        #expect(error(String(repeating: "x+", count: 300) + "x")?.message.contains("too long") == true)
        let deep = String(repeating: "(", count: 100) + "x" + String(repeating: ")", count: 100)
        #expect(error(deep)?.message.contains("nested too deeply") == true)
        #expect(error(String(repeating: "-", count: 100) + "x")?.message.contains("nested too deeply") == true)
    }

    @Test func wireFormatIsDataOnly() throws {
        let e = try GraphExpr.parse("a*Math.sin(x) + 1", params: ["a"])
        let json = String(decoding: try JSONEncoder().encode(e.wire), as: UTF8.self)
        #expect(json == #"["b","+",["b","*",["p",0],["f","sin",[["x"]]]],["n",1]]"#)
    }
}

@Suite("Graph number formatting")
struct GraphFormatTests {
    @Test func formatsCompactly() {
        #expect(GraphFormat.number(2) == "2")
        #expect(GraphFormat.number(-0.5) == "−0.5")
        #expect(GraphFormat.number(3.14159) == "3.142")
        #expect(GraphFormat.number(1e-7) == "1e-7")
        #expect(GraphFormat.number(123456) == "1.235e5")
        #expect(GraphFormat.number(1e-15) == "0")
        #expect(GraphFormat.linear(slope: 1, intercept: 0) == "x")
        #expect(GraphFormat.linear(slope: 2, intercept: -3) == "2x − 3")
        #expect(GraphFormat.linear(slope: -1, intercept: 0.5) == "−x + 0.5")
    }

    @Test func parsesTypedNumbers() {
        #expect(GraphFormat.parse("-2.5") == -2.5)
        #expect(GraphFormat.parse("2*pi") == 2 * .pi)
        #expect(GraphFormat.parse("1/3") == 1.0 / 3)
        #expect(GraphFormat.parse("x") == nil)
        #expect(GraphFormat.parse("1/0") == nil)
        #expect(GraphFormat.parse("abc") == nil)
    }
}
