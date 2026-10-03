import SwiftUI

/// Interactive molecule card for `insertMoleculeCard`.
///
/// RDKit (bundled WASM, see `MoleculeEngine`) depicts the SMILES and matches the curated
/// SMARTS library; the card draws that natively. Highlights come only from RDKit matches —
/// the model's `highlightGroups` / `starGroups` choose *which* groups to show, never which
/// atoms. Tap a group for its name and a one-liner, star it, toggle labels, or edit the
/// structure in Ketcher; groups recompute after every edit.
///
/// The Inky layer wraps this in `InkyCardContainer` and sizes it to the card frame.
struct MoleculeCardView: View {
    let action: InsertMoleculeCardAction

    @Environment(\.moleculeCardContext) private var context
    /// Edits made here when the shell hasn't wired `MoleculeCardContext.commit`.
    @State private var localAction: InsertMoleculeCardAction?
    @State private var phase: Phase = .loading

    enum Phase: Equatable {
        case loading
        case ready(MoleculeAnalysis)
        case failed(String)
    }

    private var current: InsertMoleculeCardAction { localAction ?? action }

    var body: some View {
        MoleculeCardContent(action: current, phase: phase, scale: context.scale, pageSize: context.pageSize, onChange: commit)
            .task(id: TaskKey(current)) { await load(current) }
            .onChange(of: action) { _, _ in localAction = nil }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inky.card.molecule")
    }

    private struct TaskKey: Equatable {
        var smiles: String, highlights: [String], stars: [String]
        init(_ a: InsertMoleculeCardAction) { smiles = a.smiles; highlights = a.highlightGroups; stars = a.starGroups }
    }

    private func load(_ action: InsertMoleculeCardAction) async {
        if case .ready(let old) = phase, old.input != action.smiles.trimmingCharacters(in: .whitespacesAndNewlines) { phase = .loading }
        do {
            let analysis = try await MoleculeEngine.shared.analyze(smiles: action.smiles, highlightGroups: action.highlightGroups, starGroups: action.starGroups)
            guard !Task.isCancelled else { return }
            phase = analysis.ok ? .ready(analysis) : .failed(analysis.error ?? "This structure couldn't be read.")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func commit(_ updated: InsertMoleculeCardAction) {
        if let commit = context.commit {
            commit(updated)
        }
        localAction = updated
    }
}

/// The card's content for a given phase. Separate from `MoleculeCardView` so previews and
/// snapshot tests can render it synchronously with a precomputed analysis.
struct MoleculeCardContent: View {
    let action: InsertMoleculeCardAction
    let phase: MoleculeCardView.Phase
    var scale: CGFloat = 1
    var pageSize: CGSize?
    var onChange: (InsertMoleculeCardAction) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedKey: String?
    @State private var showLabels = true
    @State private var showStereo = true
    @State private var editing = false
    @State private var showInfo = false
    @GestureState private var resize: CGSize = .zero

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                Color(white: 0.11)
            }
            switch phase {
            case .loading:
                loading
            case .failed(let message):
                failure(message)
            case .ready(let analysis):
                ready(analysis)
            }
        }
        .fullScreenCover(isPresented: $editing) {
            KetcherEditorView(smiles: action.smiles) { newSmiles in
                editing = false
                guard let newSmiles, newSmiles != action.smiles else { return }
                var updated = action
                updated.smiles = newSmiles
                selectedKey = nil
                onChange(updated)
            }
        }
    }

    // MARK: Phases

    private var loading: some View {
        VStack(spacing: 8 * scale) {
            ProgressView().controlSize(.small)
            Text(action.smiles)
                .font(.system(size: 11 * scale, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16 * scale)
        .accessibilityIdentifier("inky.molecule.loading")
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 8 * scale) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 22 * scale, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text("Inky couldn't draw this structure")
                .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
            Text(action.smiles)
                .font(.system(size: 11 * scale, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text(message)
                .font(.system(size: 10 * scale, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                editing = true
            } label: {
                Label("Fix in editor", systemImage: "pencil")
                    .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .accessibilityIdentifier("inky.molecule.fix")
        }
        .padding(16 * scale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.molecule.error")
    }

    private func ready(_ analysis: MoleculeAnalysis) -> some View {
        let groups = MoleculeGroups(analysis: analysis, highlightGroups: action.highlightGroups, starGroups: action.starGroups)
        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                GeometryReader { geo in
                    MoleculeCanvas(analysis: analysis, groups: groups, selectedKey: selectedKey, showLabels: showLabels, showStereo: showStereo, scale: scale)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            tap(at: value.location, size: geo.size, analysis: analysis, groups: groups)
                        })
                        .accessibilityElement()
                        .accessibilityLabel(Self.accessibilitySummary(analysis: analysis, groups: groups))
                        .accessibilityIdentifier("inky.molecule.canvas")
                }
                summary(analysis)
                if let key = selectedKey, let group = groups.group(key) {
                    GroupInfoBubble(group: group, isHighlighted: groups.highlighted.contains(key), isStarred: groups.starred.contains(key), scale: scale,
                                    toggleStar: { toggle(key, star: true, groups: groups) },
                                    toggleHighlight: { toggle(key, star: false, groups: groups) },
                                    close: { selectedKey = nil })
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(8 * scale)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: selectedKey)
            bar(analysis, groups: groups)
        }
    }

    // MARK: Pieces

    private func summary(_ analysis: MoleculeAnalysis) -> some View {
        let name = analysis.molecules.count == 1 ? MoleculeNames.lookup(analysis.molecules[0].inchiKey) : nil
        return Button {
            showInfo = true
        } label: {
            HStack(spacing: 5 * scale) {
                if analysis.isReaction {
                    Text("Reaction")
                } else if let mol = analysis.molecules.first {
                    Text(Self.formulaText(mol.formula, charge: mol.charge))
                    if let name, name.common != action.caption {
                        Text("·").foregroundStyle(.tertiary)
                        Text(name.common)
                    }
                }
                Image(systemName: "info.circle").imageScale(.small).foregroundStyle(.tertiary)
            }
            .font(.system(size: 10.5 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 6 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inky.molecule.info")
        .popover(isPresented: $showInfo) {
            MoleculeInfoView(analysis: analysis)
        }
    }

    private func bar(_ analysis: MoleculeAnalysis, groups: MoleculeGroups) -> some View {
        let chips = HStack(spacing: 5 * scale) {
            if groups.all.isEmpty {
                Text("No functional groups")
                    .font(.system(size: 11 * scale, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            ForEach(groups.all) { group in
                GroupChip(group: group, isOn: groups.highlighted.contains(group.key), isStarred: groups.starred.contains(group.key),
                          isSelected: selectedKey == group.key, scale: scale) {
                    selectedKey = selectedKey == group.key ? nil : group.key
                }
            }
        }
        .padding(.horizontal, 8 * scale)
        return HStack(spacing: 4 * scale) {
            // A plain row when the chips fit (also what snapshot tests can render), else scroll.
            ViewThatFits(in: .horizontal) {
                chips
                ScrollView(.horizontal, showsIndicators: false) { chips }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inky.molecule.groups")

            barButton(showLabels ? "tag.fill" : "tag", label: showLabels ? "Hide labels" : "Show labels", id: "inky.molecule.labels") {
                showLabels.toggle()
            }
            if analysis.molecules.contains(where: { !$0.stereocenters.isEmpty || !$0.stereobonds.isEmpty }) {
                barButton("r.circle\(showStereo ? ".fill" : "")", label: showStereo ? "Hide R/S labels" : "Show R/S labels", id: "inky.molecule.stereo") {
                    showStereo.toggle()
                }
            }
            barButton("pencil", label: "Edit structure", id: "inky.molecule.edit") { editing = true }
                .padding(.trailing, 4 * scale)
            if pageSize != nil {
                resizeGrip
            }
        }
        .frame(height: 34 * scale)
        .background(alignment: .top) { Divider().opacity(0.5) }
    }

    private func barButton(_ systemImage: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13 * scale, weight: .medium))
                .frame(width: 28 * scale, height: 28 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Bottom-right grip: drag to resize the card (committed as a new `near` rect).
    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .rotationEffect(.degrees(90))
            .font(.system(size: 10 * scale, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 24 * scale, height: 30 * scale)
            .contentShape(Rectangle())
            .offset(resize)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .updating($resize) { value, state, _ in state = value.translation }
                    .onEnded { value in commitResize(value.translation) }
            )
            .accessibilityLabel("Resize card")
            .accessibilityIdentifier("inky.molecule.resize")
    }

    // MARK: Actions

    private func tap(at point: CGPoint, size: CGSize, analysis: MoleculeAnalysis, groups: MoleculeGroups) {
        let layout = MoleculeLayout(analysis: analysis, in: MoleculeCanvas.drawingRect(in: size, scale: scale), maxBondLength: 46 * scale)
        selectedKey = Self.groupKey(at: point, layout: layout, analysis: analysis, groups: groups, preferring: selectedKey)
    }

    /// The group under a tap: the smallest instance containing the hit atom/bond, preferring
    /// highlighted groups; tapping the same spot again cycles through overlapping groups.
    static func groupKey(at point: CGPoint, layout: MoleculeLayout, analysis: MoleculeAnalysis, groups: MoleculeGroups, preferring current: String?) -> String? {
        guard let hit = layout.hitTest(point, analysis: analysis) else { return nil }
        var candidates: [(key: String, size: Int, on: Bool)] = []
        for group in groups.all {
            for instance in group.instances {
                let contains: Bool = switch hit {
                case .atom(let m, let atom): instance.molecule == m && instance.atoms.contains(atom)
                case .bond(let m, let bond): instance.molecule == m && instance.bonds.contains(bond)
                }
                if contains { candidates.append((group.key, instance.atoms.count, groups.highlighted.contains(group.key))) }
            }
        }
        let ordered = candidates.sorted { a, b in a.on != b.on ? a.on : a.size < b.size }.map(\.key)
        var unique: [String] = []
        for key in ordered where !unique.contains(key) { unique.append(key) }
        guard !unique.isEmpty else { return nil }
        if let current, let i = unique.firstIndex(of: current) { return unique[(i + 1) % unique.count] == current ? nil : unique[(i + 1) % unique.count] }
        return unique.first
    }

    private func toggle(_ key: String, star: Bool, groups: MoleculeGroups) {
        var updated = action
        if star {
            var keys = groups.starred
            if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
            updated.starGroups = groups.starPatterns(for: keys)
        } else {
            var keys = groups.highlighted
            if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
            updated.highlightGroups = groups.highlightPatterns(for: keys)
        }
        onChange(updated)
    }

    private func commitResize(_ translation: CGSize) {
        guard let pageSize, pageSize.width > 0, pageSize.height > 0 else { return }
        let card = InkyAnnotationGeometry.cardRect(near: action.near, pageSize: pageSize)
        var updated = action
        // The card is drawn at page zoom `scale`, so view points / scale = page points.
        updated.near = NormRect(
            x: card.x, y: card.y,
            width: min(max(card.width + translation.width / scale / pageSize.width, InkyAnnotationGeometry.minCardSize.width / pageSize.width), 0.98),
            height: min(max(card.height + translation.height / scale / pageSize.height, InkyAnnotationGeometry.minCardSize.height / pageSize.height), 0.98)
        )
        onChange(updated)
    }

    // MARK: Text helpers

    /// "C9H8O4" → C₉H₈O₄, with the net charge as a superscript (C₂H₃O₂⁻).
    static func formulaText(_ formula: String, charge: Int = 0) -> String {
        let sub = Array("₀₁₂₃₄₅₆₇₈₉"), sup = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
        let body = String(formula.map { $0.wholeNumberValue.map { sub[$0] } ?? $0 })
        guard charge != 0 else { return body }
        let magnitude = abs(charge) > 1 ? String(String(abs(charge)).map { sup[$0.wholeNumberValue!] }) : ""
        return body + magnitude + (charge > 0 ? "⁺" : "⁻")
    }

    static func accessibilitySummary(analysis: MoleculeAnalysis, groups: MoleculeGroups) -> String {
        let names = groups.all.filter { groups.highlighted.contains($0.key) }.map(\.name)
        let formula = analysis.molecules.map(\.formula).joined(separator: " and ")
        return names.isEmpty ? "Molecule \(formula)" : "Molecule \(formula). Highlighted: \(names.joined(separator: ", "))"
    }
}

/// One group in the bar: a color dot + name, filled when highlighted.
private struct GroupChip: View {
    let group: DisplayGroup
    let isOn: Bool
    let isStarred: Bool
    let isSelected: Bool
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4 * scale) {
                if isStarred {
                    Image(systemName: "star.fill").font(.system(size: 8 * scale)).foregroundStyle(MoleculeCanvas.starColor)
                } else {
                    Circle().fill(group.tint.fill.color).frame(width: 7 * scale, height: 7 * scale)
                }
                Text(group.shortName)
                if group.instances.count > 1 {
                    Text("×\(group.instances.count)").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(isOn ? group.tint.ink.color : .secondary)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 4 * scale)
            .background(Capsule().fill(group.tint.fill.color.opacity(isOn ? 0.32 : 0.0)))
            .overlay(Capsule().strokeBorder(isSelected ? group.tint.ink.color : group.tint.fill.color.opacity(isOn ? 0 : 0.9), lineWidth: (isSelected ? 1.2 : 0.8) * scale))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.name)\(isOn ? ", highlighted" : "")\(isStarred ? ", starred" : "")")
        .accessibilityIdentifier("inky.molecule.group.\(group.key)")
    }
}

/// Name + one-line description of the tapped group, with star / show-hide.
private struct GroupInfoBubble: View {
    let group: DisplayGroup
    let isHighlighted: Bool
    let isStarred: Bool
    let scale: CGFloat
    let toggleStar: () -> Void
    let toggleHighlight: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8 * scale) {
            Circle().fill(group.tint.fill.color).frame(width: 9 * scale, height: 9 * scale)
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(group.name)
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(group.tint.ink.color)
                Text(group.description)
                    .font(.system(size: 11 * scale, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            Spacer(minLength: 4 * scale)
            Button(action: toggleStar) {
                Image(systemName: isStarred ? "star.fill" : "star")
                    .foregroundStyle(isStarred ? MoleculeCanvas.starColor : Theme.accent)
                    .frame(width: 28 * scale, height: 28 * scale)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isStarred ? "Unstar \(group.name)" : "Star \(group.name)")
            .accessibilityIdentifier("inky.molecule.star")
            Button(action: toggleHighlight) {
                Image(systemName: isHighlighted ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28 * scale, height: 28 * scale)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isHighlighted ? "Hide highlight" : "Show highlight")
            .accessibilityIdentifier("inky.molecule.toggleHighlight")
        }
        .font(.system(size: 13 * scale, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 7 * scale)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: Theme.shadowColor, radius: 8 * scale, y: 3 * scale)
        )
        .overlay(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .onTapGesture {} // keep taps on the bubble from reaching the canvas
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inky.molecule.groupInfo")
    }
}
