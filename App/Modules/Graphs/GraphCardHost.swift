import SwiftUI

/// What a graph card may ask of the page that hosts it. The Inky layer provides one per card
/// through the environment (see INTERFACE_REQUESTS.md for the shell side). Without a host the
/// card is fully interactive but nothing is persisted, and resize/flatten are hidden.
struct GraphCardHost: Sendable {
    /// Page size in page points (cards scale their fonts with page zoom).
    var pageSize: CGSize
    /// Persist the edited action (spec: sliders, expressions, ranges, view, points; near: size).
    var update: @MainActor @Sendable (InsertGraphCardAction) -> Void
    /// Replace the card with this image on the page, at the card's frame. Nil hides "Flatten".
    var flatten: (@MainActor @Sendable (UIImage) -> Void)?

    init(
        pageSize: CGSize,
        update: @escaping @MainActor @Sendable (InsertGraphCardAction) -> Void,
        flatten: (@MainActor @Sendable (UIImage) -> Void)? = nil
    ) {
        self.pageSize = pageSize
        self.update = update
        self.flatten = flatten
    }
}

extension EnvironmentValues {
    @Entry var graphCardHost: GraphCardHost? = nil
}
