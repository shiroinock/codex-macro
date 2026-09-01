import Foundation

/// A single session placed into the unified 10x10 grid.
struct UnifiedPlacement: Equatable {
    let session: AgentSession
    /// Row label. For Codex this is the resolved `CatalogSession.projectKey`
    /// (`"project:<id>"` or `"projectless"`), preserved verbatim so
    /// `StateStore` keys and daemon logs are unchanged from the pre-M0
    /// behavior.
    let projectKey: String
    let row: Int
    let column: Int

    var keyIndex: Int { row * 10 + column }
}

struct UnifiedLayoutResult: Equatable {
    let projectRows: [String: Int]
    let placements: [UnifiedPlacement]
    let warnings: [String]
}

/// Computes the source-agnostic 10x10 grid placement described in the
/// implementation plan: rows are keyed by normalized cwd, merged via
/// union-find whenever sessions share a row-grouping hint (Codex project id,
/// herdr workspace id, ...); columns are ordered within each row.
///
/// This is a pure function: given the same `sessions`, it always produces
/// the same result.
///
/// `rowRank`/`columnRank` are treated as *literal, absolute* slot indices
/// (0..<10) rather than mere sort priorities: a group/session with an
/// explicit rank claims that exact row/column, and only sessions without a
/// usable rank (nil, out of range, or colliding with an already-claimed
/// slot) get packed into the remaining free slots by recency. This matters
/// for Codex parity: `CodexCatalog.layout()` reserves row numbers for
/// sidebar projects that currently have zero active sessions (so the
/// physical row a project occupies stays stable as sessions come and go).
/// `CodexSourceProvider` hands over the exact resolved row/column indices
/// `CodexCatalog.layout()` already computed, so replaying them here as
/// literal slots reproduces byte-for-byte the same placements the pre-M0
/// `Daemon.syncCatalog()` produced.
enum UnifiedLayout {
    static let maxRows = 10
    static let maxColumns = 10

    /// A session's row/column from the *previous* `compute()` call, fed back
    /// in so placement is sticky across syncs.
    struct PreviousSlot: Equatable {
        let row: Int
        let column: Int
    }

    /// Computes the grid placement. `previousPlacements` (session id -> its
    /// slot from the prior sync) makes placement sticky: when two sessions
    /// contend for the same absolute row/column, whichever one already held
    /// that exact slot wins, rather than whichever has the more recent
    /// (and, for some sources, ever-changing -- e.g. herdr's recency is
    /// always "now") `recency` value. Without this, a conflict whose
    /// "winner by recency" flips from sync to sync (or whose loser's fallback
    /// slot shifts because a competing session's presence flickers) makes the
    /// LEDs for the loser repaint every sync even though nothing meaningful
    /// changed -- see the M0.1 flicker fix.
    static func compute(
        sessions: [AgentSession],
        previousPlacements: [String: PreviousSlot] = [:]
    ) -> UnifiedLayoutResult {
        guard !sessions.isEmpty else {
            return UnifiedLayoutResult(projectRows: [:], placements: [], warnings: [])
        }

        var unionFind = UnionFind()
        for session in sessions {
            unionFind.addNode(session.cwd)
        }
        var cwdsByCodexProject: [String: [String]] = [:]
        var cwdsByHerdrWorkspace: [String: [String]] = [:]
        for session in sessions {
            if let projectID = session.rowHints.codexProjectID {
                cwdsByCodexProject[projectID, default: []].append(session.cwd)
            }
            if let workspaceID = session.rowHints.herdrWorkspaceID {
                cwdsByHerdrWorkspace[workspaceID, default: []].append(session.cwd)
            }
        }
        for group in cwdsByCodexProject.values { unionFind.unionAll(group) }
        for group in cwdsByHerdrWorkspace.values { unionFind.unionAll(group) }

        var groupIDByCWD: [String: String] = [:]
        for session in sessions where groupIDByCWD[session.cwd] == nil {
            groupIDByCWD[session.cwd] = unionFind.find(session.cwd)
        }

        var sessionsByGroup: [String: [AgentSession]] = [:]
        for session in sessions {
            let groupID = groupIDByCWD[session.cwd] ?? session.cwd
            sessionsByGroup[groupID, default: []].append(session)
        }

        struct RowGroup {
            let label: String
            let rank: Int?
            let previousRow: Int?
            let recency: Double
            let sessions: [AgentSession]
        }

        let rowGroups: [RowGroup] = sessionsByGroup.values.map { groupSessions in
            let label = rowLabel(for: groupSessions)
            let allRanks = groupSessions.compactMap(\.rowRank)
            // Prefer a rank that's an actual claim on a real grid slot
            // (0..<maxRows). Some sources (e.g. herdr) encode a row-ordering
            // *hint* as a deliberately out-of-range/negative number so it
            // never outright claims a slot on its own (see
            // `HerdrCatalog.rowRank`) -- but a plain `.min()` across every
            // session merged into this row (by shared cwd) would let that
            // hint clobber another session's real, in-range claim the moment
            // the two happen to land in the same row group, silently
            // demoting an already-placed project row to "unranked" and
            // making it bounce around with the pending pack. Only fall back
            // to an out-of-range hint when nothing in the group actually
            // claims a real slot.
            let validRanks = allRanks.filter { $0 >= 0 && $0 < maxRows }
            let rank = validRanks.min() ?? allRanks.min()
            let previousRow = stickyPreviousSlot(
                for: groupSessions.map(\.sessionID),
                in: previousPlacements,
                pick: \.row
            )
            return RowGroup(
                label: label,
                rank: rank,
                previousRow: previousRow,
                recency: groupSessions.map(\.recency).max() ?? -.infinity,
                sessions: groupSessions
            )
        }

        let (rowAssignments, rowWarnings) = assignSlots(
            rowGroups,
            capacity: maxRows,
            explicitSlot: { $0.rank },
            previousSlot: { $0.previousRow },
            stableKey: { $0.label },
            isBetter: { lhs, rhs in
                if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
                return lhs.label < rhs.label
            },
            label: { $0.label },
            slotNoun: "row"
        )

        var warnings = rowWarnings
        var projectRows: [String: Int] = [:]
        var placements: [UnifiedPlacement] = []
        for (row, group) in rowAssignments {
            projectRows[group.label] = row
            let (columnAssignments, columnWarnings) = assignSlots(
                group.sessions,
                capacity: maxColumns,
                explicitSlot: { $0.columnRank },
                previousSlot: { previousPlacements[$0.sessionID]?.column },
                stableKey: { $0.sessionID },
                isBetter: { lhs, rhs in
                    if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
                    return lhs.sessionID < rhs.sessionID
                },
                label: { $0.sessionID },
                slotNoun: "column"
            )
            warnings.append(contentsOf: columnWarnings.map { "row \"\(group.label)\": \($0)" })
            for (column, session) in columnAssignments {
                placements.append(UnifiedPlacement(session: session, projectKey: group.label, row: row, column: column))
            }
        }

        return UnifiedLayoutResult(projectRows: projectRows, placements: placements, warnings: warnings)
    }

    /// Assigns each item an absolute slot in `0..<capacity`. Items with a
    /// usable `explicitSlot` (in range and not already claimed) keep that
    /// exact slot; when two items claim the *same* slot, the one that
    /// already held it last sync (`previousSlot(item) == slot`) wins, and
    /// only if neither/both did does a stable key (`stableKey`, e.g. session
    /// id) break the tie -- never the (potentially volatile, e.g. always
    /// "now" for some sources) `isBetter`/recency ordering, so a repeating
    /// conflict resolves the same way every sync instead of flapping.
    ///
    /// Items without a usable explicit slot -- or whose claim lost the tie
    /// above -- are packed into the remaining free slots: first, in a sticky
    /// reclaim pass (stable-key order) that lets each such item keep the
    /// slot it held last sync if that slot is still free, then the rest in
    /// `isBetter` order. Items that still don't fit are dropped, each
    /// producing a warning.
    private static func assignSlots<T>(
        _ items: [T],
        capacity: Int,
        explicitSlot: (T) -> Int?,
        previousSlot: (T) -> Int?,
        stableKey: (T) -> String,
        isBetter: (T, T) -> Bool,
        label: (T) -> String,
        slotNoun: String
    ) -> (assigned: [(slot: Int, item: T)], warnings: [String]) {
        func isSticky(_ item: T, forSlot slot: Int) -> Bool {
            previousSlot(item) == slot
        }

        // Explicit-slot items are considered first, ordered by their slot
        // value; same-slot ties are broken by stickiness then stable key so
        // claims are resolved the same way every time. Slot-less items
        // follow, ordered by isBetter (used only to order the packing pass
        // below, not to decide conflict winners).
        let claimOrder = items.sorted { lhs, rhs in
            switch (explicitSlot(lhs), explicitSlot(rhs)) {
            case let (l?, r?):
                guard l == r else { return l < r }
                let lhsSticky = isSticky(lhs, forSlot: l)
                let rhsSticky = isSticky(rhs, forSlot: r)
                if lhsSticky != rhsSticky { return lhsSticky }
                return stableKey(lhs) < stableKey(rhs)
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return isBetter(lhs, rhs)
            }
        }

        var warnings: [String] = []
        var claimedSlots = Set<Int>()
        var assigned: [(slot: Int, item: T)] = []
        var pending: [T] = []
        for item in claimOrder {
            if let slot = explicitSlot(item), slot >= 0, slot < capacity, !claimedSlots.contains(slot) {
                claimedSlots.insert(slot)
                assigned.append((slot, item))
            } else {
                if let slot = explicitSlot(item), slot >= 0, slot < capacity {
                    // In-range but already claimed by a higher-priority item.
                    warnings.append("rank conflict for \(slotNoun) \"\(label(item))\", reassigned")
                }
                pending.append(item)
            }
        }

        var freeSlots = Set(0..<capacity).subtracting(claimedSlots)

        // Sticky reclaim pass: an item without a winning explicit claim
        // still keeps the slot it held last sync, as long as that slot is
        // still free. Processed in stable-key order so the (rare) case of
        // two pending items remembering the same previous slot resolves
        // deterministically rather than by array-iteration happenstance.
        var reclaimed = Set<Int>() // indices into `pending`
        var stickyAssigned: [(slot: Int, item: T)] = []
        for (index, item) in pending.enumerated().sorted(by: { stableKey($0.element) < stableKey($1.element) }) {
            if let slot = previousSlot(item), freeSlots.contains(slot) {
                stickyAssigned.append((slot, item))
                freeSlots.remove(slot)
                reclaimed.insert(index)
            }
        }

        var orderedFreeSlots = freeSlots.sorted()
        for (index, item) in pending.enumerated() where !reclaimed.contains(index) {
            guard !orderedFreeSlots.isEmpty else {
                warnings.append("dropped \(slotNoun) \"\(label(item))\" beyond the \(capacity)-\(slotNoun) grid limit")
                continue
            }
            assigned.append((orderedFreeSlots.removeFirst(), item))
        }
        assigned.append(contentsOf: stickyAssigned)

        assigned.sort { $0.slot < $1.slot }
        return (assigned, warnings)
    }

    /// Picks the previous slot value (via `pick`) shared by the most
    /// sessions in a merged row group, breaking ties by the smallest value
    /// -- used so a group merged from sessions that don't all agree on their
    /// last-known row (e.g. one just joined the group) still gets a single,
    /// deterministic sticky candidate.
    private static func stickyPreviousSlot(
        for sessionIDs: [String],
        in previousPlacements: [String: PreviousSlot],
        pick: (PreviousSlot) -> Int
    ) -> Int? {
        let values = sessionIDs.compactMap { previousPlacements[$0].map(pick) }
        guard !values.isEmpty else { return nil }
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
        let maxCount = counts.values.max() ?? 0
        return counts.filter { $0.value == maxCount }.keys.min()
    }

    private static func rowLabel(for sessions: [AgentSession]) -> String {
        if let codexProjectID = sessions.compactMap(\.rowHints.codexProjectID).first {
            return codexProjectID
        }
        if let herdrWorkspaceID = sessions.compactMap(\.rowHints.herdrWorkspaceID).first {
            return herdrWorkspaceID
        }
        return sessions[0].cwd
    }
}

private struct UnionFind {
    private var parent: [String: String] = [:]

    mutating func addNode(_ node: String) {
        if parent[node] == nil {
            parent[node] = node
        }
    }

    mutating func find(_ node: String) -> String {
        addNode(node)
        var root = node
        while let next = parent[root], next != root {
            root = next
        }
        var walker = node
        while let next = parent[walker], next != root {
            parent[walker] = root
            walker = next
        }
        return root
    }

    mutating func union(_ a: String, _ b: String) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }
        parent[rootB] = rootA
    }

    mutating func unionAll(_ nodes: [String]) {
        guard let first = nodes.first else { return }
        for node in nodes.dropFirst() {
            union(first, node)
        }
    }
}
