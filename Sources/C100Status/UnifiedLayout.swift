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

    static func compute(sessions: [AgentSession]) -> UnifiedLayoutResult {
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
            let recency: Double
            let sessions: [AgentSession]
        }

        let rowGroups: [RowGroup] = sessionsByGroup.values.map { groupSessions in
            RowGroup(
                label: rowLabel(for: groupSessions),
                rank: groupSessions.compactMap(\.rowRank).min(),
                recency: groupSessions.map(\.recency).max() ?? -.infinity,
                sessions: groupSessions
            )
        }

        let (rowAssignments, rowWarnings) = assignSlots(
            rowGroups,
            capacity: maxRows,
            explicitSlot: { $0.rank },
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
    /// exact slot. Items without one -- or whose claim lost to a prior,
    /// higher-priority item -- are packed into the remaining free slots in
    /// `isBetter` order. Items that still don't fit are dropped, each
    /// producing a warning.
    private static func assignSlots<T>(
        _ items: [T],
        capacity: Int,
        explicitSlot: (T) -> Int?,
        isBetter: (T, T) -> Bool,
        label: (T) -> String,
        slotNoun: String
    ) -> (assigned: [(slot: Int, item: T)], warnings: [String]) {
        // Explicit-slot items are considered first, ordered by their slot
        // value (ties broken by isBetter) so claims are resolved
        // deterministically; slot-less items follow, ordered by isBetter.
        let claimOrder = items.sorted { lhs, rhs in
            switch (explicitSlot(lhs), explicitSlot(rhs)) {
            case let (l?, r?):
                return l == r ? isBetter(lhs, rhs) : l < r
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
                    warnings.append("rank conflict for \(slotNoun) \"\(label(item))\", reassigned by recency")
                }
                pending.append(item)
            }
        }

        var freeSlots = (0..<capacity).filter { !claimedSlots.contains($0) }
        for item in pending {
            guard !freeSlots.isEmpty else {
                warnings.append("dropped \(slotNoun) \"\(label(item))\" beyond the \(capacity)-\(slotNoun) grid limit")
                continue
            }
            assigned.append((freeSlots.removeFirst(), item))
        }

        assigned.sort { $0.slot < $1.slot }
        return (assigned, warnings)
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
