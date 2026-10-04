import Foundation

/// Checks that need the app's engines, run on each action before it reaches the page (wired into
/// `ValidatingInkyModelClient` at launch): every structure of a chemistry figure must parse in
/// RDKit with the atom-map numbers its arrows use, and a diagram must render cleanly — readable
/// text, no overlapping labels. Problems go back to the model for its one retry; on the last
/// attempt a diagram with only cosmetic issues is let through rather than dropped.
enum InkyDeepChecker {
    static func install() {
        InkyClientFactory.deepCheck = { action, request, isFinalAttempt in
            await check(action, request: request, isFinalAttempt: isFinalAttempt)
        }
    }

    @MainActor
    static func check(_ action: InkyAction, request: InkyRequest, isFinalAttempt: Bool) async -> InkyResponseValidator.Outcome {
        switch action {
        case .insertChemScheme(let a):
            guard let analysis = try? await MoleculeEngine.shared.scheme(steps: a.steps.map(\.smiles)) else {
                return .valid(action)  // engine unavailable: let the view report it
            }
            for (i, step) in analysis.steps.enumerated() where !step.ok {
                return .invalid("insertChemScheme step \(i) \"\(step.input)\": \(step.error ?? "RDKit couldn't parse it") — check valences, charges in brackets and ring closures")
            }
            for arrow in a.arrows where arrow.step < analysis.steps.count {
                let maps = analysis.steps[arrow.step].maps
                let refs = [arrow.from, arrow.to].flatMap { $0.split(whereSeparator: { $0 == "-" || $0 == "=" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) } }
                if let missing = refs.first(where: { maps[$0] == nil }) {
                    return .invalid("insertChemScheme arrow uses atom map \(missing), which RDKit can't find in step \(arrow.step)")
                }
            }
            return .valid(action)
        case .insertDiagram(let a):
            guard let report = try? await DiagramEngine.shared.prepare(svg: a.svg) else { return .valid(action) }
            if report.svg.isEmpty || report.width < 5 {
                return .invalid("insertDiagram: \(report.problems.first ?? "the SVG drew nothing")")
            }
            let pageSize = CGSize(width: 816, height: 816 / max(0.2, request.pageAspectRatio))
            let problems = DiagramEngine.displayProblems(for: report, pageSize: pageSize)
            if !problems.isEmpty && !isFinalAttempt {
                return .invalid("insertDiagram: " + problems.joined(separator: "; "))
            }
            return .valid(action)
        default:
            return .valid(action)
        }
    }
}
