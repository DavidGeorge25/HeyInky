import SwiftUI

/// Colors for one appearance. Shared by the web board and the native renderer.
struct GraphTheme: Hashable, Sendable, Encodable {
    var dark: Bool
    var background: String
    var grid: String
    var axis: String
    var text: String
    var muted: String
    var accent: String

    static let light = GraphTheme(
        dark: false, background: "#FFFFFF", grid: "rgba(28,28,36,0.07)", axis: "rgba(28,28,36,0.55)",
        text: "rgba(28,28,36,0.62)", muted: "rgba(28,28,36,0.45)", accent: "#5B5BD6"
    )
    static let dark = GraphTheme(
        dark: true, background: "#1C1C21", grid: "rgba(237,237,240,0.08)", axis: "rgba(237,237,240,0.6)",
        text: "rgba(237,237,240,0.72)", muted: "rgba(237,237,240,0.5)", accent: "#9B9EF8"
    )

    static func `for`(_ scheme: ColorScheme) -> GraphTheme { scheme == .dark ? dark : light }

    /// Parses the CSS colors used above (#RRGGBB or rgba(r,g,b,a)).
    static func color(_ css: String) -> Color {
        let s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) {
            return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        if s.hasPrefix("rgba("), s.hasSuffix(")") {
            let parts = s.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 4 {
                return Color(.sRGB, red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, opacity: parts[3])
            }
        }
        return .gray
    }
}

/// Everything needed to draw a graph: the web board renders it from JSON, the native
/// renderer (flatten/export, snapshots, loading placeholder) from the same values.
struct GraphScene: Hashable, Sendable, Encodable {
    struct View: Hashable, Sendable, Encodable { var xMin, xMax, yMin, yMax: Double }

    struct Function: Hashable, Sendable, Encodable {
        var index: Int
        var tree: GraphWireNode?
        var color: String
        var label: String
    }

    struct Asymptote: Hashable, Sendable, Encodable {
        var kind: GraphAsymptoteLine.Kind
        var value: Double
        var slope: Double
        var label: String
        var color: String?
    }

    struct Feature: Hashable, Sendable, Encodable {
        var kind: GraphFeature.Kind
        var x: Double
        var y: Double
        var function: Int
        var label: String
    }

    struct Axes: Hashable, Sendable, Encodable { var x: String; var y: String }

    struct Options: Hashable, Sendable, Encodable {
        var asymptotes = true
        var features = true
    }

    /// Subset sent while sliders move (no board rebuild).
    struct Patch: Hashable, Sendable, Encodable {
        var params: [Double]
        var asymptotes: [Asymptote]
        var features: [Feature]
        var options: Options
    }

    var view: View
    var params: [Double]
    var functions: [Function]
    var asymptotes: [Asymptote]
    var features: [Feature]
    var points: [GraphSpec.Point]
    var labels: [GraphSpec.Label]
    var axes: Axes
    var theme: GraphTheme
    /// Points per page point (fonts and strokes scale with page zoom).
    var scale: Double
    var options: Options

    var patch: Patch { Patch(params: params, asymptotes: asymptotes, features: features, options: options) }

    init(document: GraphDocument, theme: GraphTheme, scale: Double = 1, options: Options = Options(), analysis: GraphAnalysis.Result? = nil) {
        let spec = document.spec
        view = View(xMin: spec.xMin, xMax: spec.xMax, yMin: spec.yMin, yMax: spec.yMax)
        params = document.paramValues
        functions = spec.functions.indices.map { i in
            Function(
                index: i,
                tree: document.expression(at: i)?.wire,
                color: GraphPalette.color(for: spec.functions[i].color, index: i, dark: theme.dark),
                label: document.functionName(at: i)
            )
        }
        let result = analysis ?? document.analysis()
        let colors = functions.map(\.color)
        asymptotes = result.asymptotes.map { a in
            Asymptote(kind: a.kind, value: a.value, slope: a.slope, label: a.label,
                      color: a.function.flatMap { colors.indices.contains($0) ? colors[$0] : nil })
        }
        features = result.features.map { Feature(kind: $0.kind, x: $0.x, y: $0.y, function: $0.function, label: $0.label) }
        points = spec.points
        labels = spec.labels
        let axisLabels = document.axisLabels
        axes = Axes(x: axisLabels.x, y: axisLabels.y)
        self.theme = theme
        self.scale = scale
        self.options = options
    }

    func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
