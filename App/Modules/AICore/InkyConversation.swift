import Foundation

/// Short-term memory for follow-ups on the same page ("now explain why", "undo that").
/// Keeps the last few turns per page in memory; turns older than `maxAge` are dropped so a
/// new study session starts fresh. Not persisted.
@MainActor
final class InkyConversation {
    var maxTurns = 4
    var maxAge: TimeInterval = 30 * 60

    private var turnsByPage: [UUID: [InkyTurn]] = [:]

    init() {}

    /// Turns to send with the next request on this page, oldest first.
    func history(for pageID: UUID, now: Date = .now) -> [InkyTurn] {
        let fresh = (turnsByPage[pageID] ?? []).filter { now.timeIntervalSince($0.date) <= maxAge }
        turnsByPage[pageID] = fresh
        return fresh
    }

    /// Records a finished turn. `createdAnnotationIDs` are the page annotations it added.
    func record(_ turn: InkyTurn, pageID: UUID) {
        var turns = turnsByPage[pageID] ?? []
        turns.append(turn)
        if turns.count > maxTurns { turns.removeFirst(turns.count - maxTurns) }
        turnsByPage[pageID] = turns
    }

    func reset(pageID: UUID) {
        turnsByPage[pageID] = nil
    }

    func resetAll() {
        turnsByPage.removeAll()
    }
}
