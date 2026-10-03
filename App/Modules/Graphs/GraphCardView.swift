import SwiftUI

/// STUB — owned by the Graphs module agent (see README.md in this folder).
/// Replace the body with the JSXGraph-rendered interactive graph (WKWebView, bundled JS).
/// Keep the type name and initializer: the Inky layer creates it as
/// `GraphCardView(action:)` inside `InkyCardContainer`, sized to the card's frame.
struct GraphCardView: View {
    let action: InsertGraphCardAction

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.6))
            ForEach(Array(action.spec.functions.enumerated()), id: \.offset) { _, function in
                Text(function.expression)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Text("Interactive graph coming soon")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding()
        .accessibilityIdentifier("inky.card.graph")
    }
}
