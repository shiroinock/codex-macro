import Foundation
import SQLite3

enum ProjectGroupingTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c100-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CodexPaths(home: root.path, catalogDatabase: root.path + "/catalog.db", sidebarState: root.path + "/sidebar.json")
        let sidebar: [String: Any] = [
            "project-order": ["home", "nou", "shell", "nested", "multi"],
            "local-projects": [
                "nou": ["rootPaths": ["/repo/nou"]], "shell": ["rootPaths": ["/repo/shell"]],
                "nested": ["rootPaths": ["/repo/nou/nested"]], "multi": ["rootPaths": ["/repo/a", "/repo/b"]]
            ],
            "thread-project-assignments": [
                "assigned-home": ["projectKind": "local", "projectId": "home"],
                "assigned-nou": ["projectKind": "local", "projectId": "nou"]
            ],
            "projectless-thread-ids": ["opted-out"],
            "thread-workspace-root-hints": ["worktree": "/repo/nou"]
        ]
        try JSONSerialization.data(withJSONObject: sidebar).write(to: URL(fileURLWithPath: paths.sidebarState))
        var db: OpaquePointer?
        guard sqlite3_open(paths.catalogDatabase, &db) == SQLITE_OK else { throw CLIError.runtime("project fixture open failed") }
        let sql = """
        CREATE TABLE local_thread_catalog(thread_id TEXT,cwd TEXT,project_id TEXT,source_recency_at REAL,source_created_at REAL,host_id TEXT,missing_candidate INTEGER);
        INSERT INTO local_thread_catalog VALUES
        ('assigned-home','/repo/nou','outdated-project',9,1,'local',0),
        ('assigned-nou','/repo/nou',NULL,8,1,'local',0),
        ('legacy-shell','/repo/shell/src',NULL,7,1,'local',0),
        ('nested','/repo/nou/nested/src',NULL,6,1,'local',0),
        ('multi','/repo/b',NULL,5,1,'local',0),
        ('worktree','/worktrees/123/nou',NULL,4,1,'local',0),
        ('opted-out','/repo/nou','nou',3,1,'local',0),
        ('prefix-only','/repo/nou-other',NULL,2,1,'local',0);
        """
        let result = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db)
        guard result == SQLITE_OK else { throw CLIError.runtime("project fixture query failed") }
        let sessions = try CodexSourceProvider(paths: paths).snapshot()
        let layout = UnifiedLayout.compute(sessions: sessions, maxRows: 9)
        let rows = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.session.sessionID, $0.row) })
        let expected = ["assigned-home": 0, "assigned-nou": 1, "legacy-shell": 2, "nested": 3, "multi": 4, "worktree": 1, "opted-out": 5, "prefix-only": 5]
        guard rows == expected, layout.warnings.isEmpty else {
            throw CLIError.runtime("project grouping regression: \(rows), warnings=\(layout.warnings)")
        }
        let previous = Dictionary(uniqueKeysWithValues: layout.placements.map {
            ($0.session.sessionID, UnifiedLayout.PreviousSlot(row: $0.row, column: $0.column))
        })
        let bottom = UnifiedLayout.compute(sessions: sessions, previousPlacements: previous, maxRows: 9, reserveLastRowForProjectless: true)
        guard bottom.projectRows[CodexCatalog.projectlessKey] == 8,
              bottom.placements.filter({ $0.projectKey != CodexCatalog.projectlessKey }).allSatisfy({ $0.row < 8 }) else {
            throw CLIError.runtime("projectless must occupy the last task row regardless of previous placement")
        }
        // Even an explicit/sticky named-project claim cannot take the reserved row.
        let collision = sessions.map { session in
            AgentSession(sourceKind: session.sourceKind, sessionID: session.sessionID, cwd: session.cwd,
                         rowHints: session.rowHints, recency: session.recency,
                         rowRank: session.rowHints.codexProjectID == "project:home" ? 8 : session.rowRank,
                         columnRank: session.columnRank, seedStatus: nil, navigation: session.navigation)
        }
        let reserved = UnifiedLayout.compute(sessions: collision, previousPlacements: ["assigned-home": .init(row: 8, column: 0)], maxRows: 9, reserveLastRowForProjectless: true)
        guard reserved.projectRows[CodexCatalog.projectlessKey] == 8, reserved.projectRows["project:home"] != 8,
              reserved.placements.count == sessions.count else { throw CLIError.runtime("reserved row collision regression") }
        var ambiguous = CodexSidebarOrdering.empty
        ambiguous.projectRoots = ["a": ["/shared"], "b": ["/shared"]]
        guard ambiguous.resolvedProjectID(sessionID: "x", cwd: "/shared", catalogProjectID: nil) == nil else {
            throw CLIError.runtime("ambiguous project roots must not select an arbitrary project")
        }
        print("project grouping self-test passed: shared cwd isolation, legacy roots, explicit precedence, projectless opt-out, nested/multiple roots, worktree hints")
    }
}
