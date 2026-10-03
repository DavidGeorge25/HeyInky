import Foundation

/// Ready-made graphs for biology and physics classes. Each is a plain `GraphSpec`, so a preset
/// card persists and edits exactly like one Inky inserted. Expressions use the same JavaScript
/// Math style the model writes.
struct GraphPreset: Identifiable, Hashable, Sendable {
    enum Subject: String, Hashable, Sendable, CaseIterable {
        case biology = "Biology", physics = "Physics"
    }

    var id: String
    var subject: Subject
    var spec: GraphSpec
    var xAxis: String
    var yAxis: String
    var title: String { spec.title ?? id }
}

enum GraphPresets {
    static let all: [GraphPreset] = [
        exponentialGrowth, logisticGrowth, michaelisMenten, doseResponse, lineweaverBurk, projectile, harmonic,
    ]

    static func preset(id: String) -> GraphPreset? { all.first { $0.id == id } }

    /// Axis labels for a spec: the model's `xLabel`/`yLabel` when given, else the preset's
    /// (recognized by title), else x/y.
    static func axisLabels(for spec: GraphSpec) -> (x: String, y: String) {
        let preset = spec.title.flatMap { title in all.first(where: { titleKey($0.title) == titleKey(title) }) }
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        return (nonEmpty(spec.xLabel) ?? preset?.xAxis ?? "x", nonEmpty(spec.yLabel) ?? preset?.yAxis ?? "y")
    }

    /// Case- and dash-insensitive ("Michaelis-Menten" matches "Michaelis–Menten").
    private static func titleKey(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func param(_ name: String, _ min: Double, _ max: Double, _ value: Double, _ step: Double) -> GraphSpec.Param {
        GraphSpec.Param(name: name, min: min, max: max, value: value, step: step)
    }

    static let exponentialGrowth = GraphPreset(
        id: "exponential", subject: .biology,
        spec: GraphSpec(
            title: "Exponential growth", xMin: -2, xMax: 20, yMin: -15, yMax: 200,
            functions: [.init(expression: "N0*Math.exp(r*x)", label: "N(t)", color: nil)],
            params: [param("N0", 1, 50, 10, 1), param("r", -0.5, 0.5, 0.15, 0.01)],
            asymptotes: [], points: [], labels: []
        ),
        xAxis: "t", yAxis: "N"
    )

    static let logisticGrowth = GraphPreset(
        id: "logistic", subject: .biology,
        spec: GraphSpec(
            title: "Logistic growth", xMin: -2, xMax: 30, yMin: -10, yMax: 130,
            functions: [.init(expression: "K/(1+((K-N0)/N0)*Math.exp(-r*x))", label: "N(t)", color: nil)],
            params: [param("K", 10, 200, 100, 1), param("N0", 1, 50, 5, 1), param("r", 0.05, 2, 0.5, 0.05)],
            asymptotes: [], points: [], labels: []
        ),
        xAxis: "t", yAxis: "N"
    )

    static let michaelisMenten = GraphPreset(
        id: "michaelis-menten", subject: .biology,
        spec: GraphSpec(
            title: "Michaelis–Menten", xMin: -1, xMax: 30, yMin: -1, yMax: 13,
            functions: [
                .init(expression: "Vmax*x/(Km+x)", label: "v₀", color: nil),
                .init(expression: "Vmax/2", label: "½Vmax", color: "gray"),
            ],
            params: [param("Vmax", 1, 12, 10, 0.5), param("Km", 0.1, 10, 2, 0.1)],
            asymptotes: [], points: [], labels: []
        ),
        xAxis: "[S]", yAxis: "v₀"
    )

    static let doseResponse = GraphPreset(
        id: "dose-response", subject: .biology,
        spec: GraphSpec(
            title: "Dose–response", xMin: -10, xMax: -2, yMin: -10, yMax: 120,
            functions: [.init(expression: "Bottom + (Top-Bottom)/(1+Math.pow(10,(logEC50-x)*n))", label: "response", color: nil)],
            params: [param("Top", 50, 115, 100, 1), param("Bottom", -10, 40, 0, 1), param("logEC50", -9, -3, -6, 0.1), param("n", 0.3, 4, 1, 0.1)],
            asymptotes: [], points: [], labels: []
        ),
        xAxis: "log[dose]", yAxis: "response (%)"
    )

    static let lineweaverBurk = GraphPreset(
        id: "lineweaver-burk", subject: .biology,
        spec: GraphSpec(
            title: "Lineweaver–Burk", xMin: -1, xMax: 2, yMin: -0.1, yMax: 0.6,
            functions: [.init(expression: "(Km/Vmax)*x + 1/Vmax", label: "1/v₀", color: nil)],
            params: [param("Vmax", 2, 20, 10, 0.5), param("Km", 0.5, 10, 2, 0.1)],
            asymptotes: [], points: [], labels: [.init(x: -0.95, y: 0.55, text: "slope = Km/Vmax")]
        ),
        xAxis: "1/[S]", yAxis: "1/v₀"
    )

    static let projectile = GraphPreset(
        id: "projectile", subject: .physics,
        spec: GraphSpec(
            title: "Projectile motion", xMin: -1, xMax: 40, yMin: -1, yMax: 15,
            functions: [.init(
                expression: "x*Math.tan(theta*Math.PI/180) - g*x*x/(2*v0*v0*Math.pow(Math.cos(theta*Math.PI/180),2))",
                label: "path", color: nil
            )],
            params: [param("v0", 1, 30, 15, 0.5), param("theta", 5, 85, 45, 1), param("g", 1, 25, 9.81, 0.01)],
            asymptotes: [], points: [], labels: []
        ),
        xAxis: "x (m)", yAxis: "y (m)"
    )

    static let harmonic = GraphPreset(
        id: "harmonic", subject: .physics,
        spec: GraphSpec(
            title: "Simple harmonic motion", xMin: 0, xMax: 12.6, yMin: -5, yMax: 5,
            functions: [
                .init(expression: "A*Math.cos(w*x + phi)", label: "x(t)", color: nil),
                .init(expression: "-A*w*Math.sin(w*x + phi)", label: "v(t)", color: nil),
            ],
            params: [param("A", 0.1, 4, 2, 0.1), param("w", 0.1, 3, 1, 0.1), param("phi", -3.14, 3.14, 0, 0.01)],
            asymptotes: [], points: [], labels: []
        ),
        xAxis: "t (s)", yAxis: "x"
    )
}

/// Curve colors: Inky's indigo first, then calm companions. Model-provided colors are accepted
/// only as hex or from a small named set (they reach the web view as data, never as CSS text).
enum GraphPalette {
    static let light = ["#5B5BD6", "#12A594", "#E5762E", "#D6409F", "#30A46C", "#0090FF"]
    static let dark = ["#9B9EF8", "#3DD6BF", "#FF9B5C", "#F37ACD", "#5BD08F", "#5AB5FF"]
    static let named: [String: (light: String, dark: String)] = [
        "indigo": ("#5B5BD6", "#9B9EF8"), "purple": ("#8E4EC6", "#C89DF2"), "blue": ("#0090FF", "#5AB5FF"),
        "teal": ("#12A594", "#3DD6BF"), "green": ("#30A46C", "#5BD08F"), "orange": ("#E5762E", "#FF9B5C"),
        "red": ("#E5484D", "#FF7A7F"), "pink": ("#D6409F", "#F37ACD"), "gray": ("#8B8D98", "#9EA0AA"),
        "grey": ("#8B8D98", "#9EA0AA"), "black": ("#1C1C24", "#EDEDF0"),
    ]

    static func color(for requested: String?, index: Int, dark: Bool) -> String {
        if let requested = requested?.trimmingCharacters(in: .whitespaces).lowercased() {
            if let named = named[requested] { return dark ? named.dark : named.light }
            if isHex(requested) { return expandHex(requested) }
        }
        let palette = dark ? self.dark : light
        return palette[index % palette.count]
    }

    static func isHex(_ s: String) -> Bool {
        guard s.hasPrefix("#"), s.count == 4 || s.count == 7 else { return false }
        return s.dropFirst().allSatisfy(\.isHexDigit)
    }

    static func expandHex(_ s: String) -> String {
        guard s.count == 4 else { return s.uppercased() }
        return "#" + s.dropFirst().map { "\($0)\($0)" }.joined().uppercased()
    }
}
