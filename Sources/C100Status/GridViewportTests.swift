import Foundation

enum GridViewportTests {
    static func run() throws {
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw CLIError.runtime("Viewport self-test: " + message) }
        }
        let sessions = (0..<12).flatMap { row in
            (0..<14).map { column in
                CatalogSession(sessionID: "p\(row)-t\(column)", cwd: "/repo/\(row)", projectID: "p\(row)", recency: Double(100 - column), createdAt: 1)
            }
        }
        let sidebar = CodexSidebarOrdering(projectIDs: (0..<12).map { "p\($0)" }, threadIDsByProject: [:], pinnedThreadIDs: [], projectAssignments: [:])
        let full = CodexCatalog.orderedLayout(sessions, sidebar: sidebar, unbounded: true)
        try check(full.placements.count == 168, "catalog must not discard rows or columns")
        let agents = full.placements.map { placement in
            AgentSession(sourceKind: .codex, sessionID: placement.session.sessionID, cwd: placement.session.cwd,
                         rowHints: RowGroupingHints(codexProjectID: placement.session.projectKey, herdrWorkspaceID: nil),
                         recency: placement.session.recency, rowRank: placement.row, columnRank: placement.column,
                         seedStatus: nil, navigation: .codexThread(sessionID: placement.session.sessionID))
        }
        let logical = UnifiedLayout.compute(sessions: agents, maxRows: 12, columnCapacity: 14)
        try check(logical.placements.count == 168 && logical.warnings.isEmpty, "unified layout must retain full catalog")
        var state = GridState()
        state.sessions = Dictionary(uniqueKeysWithValues: logical.placements.map {
            ($0.session.sessionID, SessionSlot(projectKey: $0.projectKey, source: .codex, row: $0.row, column: $0.column, status: .idle))
        })
        state.projectRows[SessionSourceKind.codex.rawValue] = full.projectRows
        var viewport = GridViewport()
        let slots = Array(state.sessions.values)
        try check(slots.compactMap { viewport.key(for: $0) }.count == 80, "8x10 visible grid")
        for _ in 0..<10 { viewport.move("right", projects: full.projectRows, slots: slots) }
        try check(viewport.leftColumn == 4, "right boundary clamp")
        try check(viewport.key(for: state.sessions["p2-t13"]!) == 29, "14th task visible at correct key")
        try check(viewport.key(for: state.sessions["p1-t4"]!) == 10 && viewport.key(for: state.sessions["p1-t0"]!) == nil, "all project rows share the horizontal offset")
        try check(viewport.key(for: state.sessions["p2-t0"]!) == nil, "offscreen task cannot own a physical key")
        _ = try state.update(sessionID: "p11-t13", projectKey: "project:p11", source: .codex, status: .done)
        for _ in 0..<20 { viewport.move("down", projects: full.projectRows, slots: slots) }
        try check(viewport.topRow == 4, "bottom boundary")
        for _ in 0..<10 { viewport.move("right", projects: full.projectRows, slots: slots) }
        try check(viewport.key(for: state.sessions["p11-t13"]!) == 79 && state.sessions["p11-t13"]?.status == .done, "hidden status retained and exposed after scroll")
        let visible = state.sessions.compactMap { id, slot in viewport.key(for: slot).map { ($0, id) } }
        try check(Set(visible.map { $0.0 }).count == visible.count && visible.allSatisfy { $0.0 < 80 }, "no duplicate keys or utility overlap")
        for _ in 0..<20 { viewport.move("up", projects: full.projectRows, slots: slots) }
        try check(viewport.topRow == 0 && viewport.leftColumn == 4, "horizontal position survives vertical navigation")
        let short = slots.filter { $0.row < 2 && $0.column < 3 }
        viewport.normalize(projects: ["project:p0": 0, "project:p1": 1], slots: short)
        try check(viewport.topRow == 0 && viewport.leftColumn == 0, "removed projects clear stale offsets")
        let colors = viewport.utilityColors(projects: ["project:p0": 0, "project:p1": 1], slots: short)
        try check(colors[88]?.value == 18 && colors[98]?.value == 18 && (80..<88).allSatisfy { colors[$0] == nil }, "disabled arrows are dim")
        var repeatKeys = ArrowKeyRepeat()
        repeatKeys.updateHeld([98, 0, 90], now: 0)
        try check(repeatKeys.due(now: 0.34).isEmpty, "short press does not repeat")
        try check(repeatKeys.due(now: 0.35) == [98], "only arrow repeats after initial delay")
        try check(repeatKeys.due(now: 0.42).isEmpty, "repeat interval")
        try check(repeatKeys.due(now: 0.44) == [98], "held arrow repeats without new reports")
        try check(repeatKeys.due(now: 5) == [98] && repeatKeys.due(now: 5).isEmpty, "slow poll does not burst")
        repeatKeys.updateHeld([], now: 5.01)
        try check(repeatKeys.due(now: 6).isEmpty, "release stops repeat")
        repeatKeys.updateHeld([98], now: 7)
        repeatKeys.updateHeld([], now: 7.1)
        repeatKeys.updateHeld([98, 99], now: 7.2)
        try check(repeatKeys.due(now: 7.4).isEmpty, "release and repress restart delay")
        try check(repeatKeys.due(now: 7.6) == [98, 99], "independent held arrows")
        repeatKeys.updateHeld([99], now: 7.61)
        try check(repeatKeys.due(now: 7.7) == [99], "releasing one arrow preserves the other")
        print("viewport self-test passed: 12 projects x 14 tasks, navigation mapping, hidden statuses, boundaries, utility isolation, held arrow repeat")
    }
}
