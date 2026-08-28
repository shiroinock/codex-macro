import Foundation
import SQLite3

struct CatalogSession: Equatable {
    let sessionID: String
    let cwd: String
    let projectID: String?
    let recency: Double
    let createdAt: Double

    var projectKey: String {
        projectID.map { "project:\($0)" } ?? CodexCatalog.projectlessKey
    }
}

struct CatalogPlacement: Equatable {
    let session: CatalogSession
    let row: Int
    let column: Int

    var keyIndex: Int { row * 10 + column }
}

struct CatalogLayout: Equatable {
    let projectRows: [String: Int]
    let placements: [CatalogPlacement]
}

struct CodexSidebarOrdering {
    let projectIDs: [String]
    let threadIDsByProject: [String: [String]]
    let pinnedThreadIDs: [String]
    let projectAssignments: [String: String]

    static let empty = Self(
        projectIDs: [],
        threadIDsByProject: [:],
        pinnedThreadIDs: [],
        projectAssignments: [:]
    )
}

private struct ForkCatalogSession {
    let sessionID: String
    let cwd: String
    let projectID: String?
    let recency: Double
    let createdAt: Double
    let rolloutPath: String
}

enum CodexCatalog {
    static let projectlessKey = "projectless"

    static func sessions(homeDirectory: String = NSHomeDirectory()) throws -> [CatalogSession] {
        try layout(homeDirectory: homeDirectory).placements.map(\.session)
    }

    static func layout(homeDirectory: String = NSHomeDirectory()) throws -> CatalogLayout {
        let sidebar = sidebarOrdering(homeDirectory: homeDirectory)
        let databasePath = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".codex/sqlite/codex-dev.db")
            .path
        var result = try catalogSessions(
            databasePath: databasePath,
            sidebar: sidebar
        )
        let existingSessionIDs = Set(result.map(\.sessionID))
        result.append(contentsOf: forkSessions(
            homeDirectory: homeDirectory,
            catalogSessions: result,
            sidebar: sidebar
        ).filter { !existingSessionIDs.contains($0.sessionID) })
        return orderedLayout(result, sidebar: sidebar)
    }

    static func projectKey(sessionID: String, homeDirectory: String = NSHomeDirectory()) -> String {
        sidebarOrdering(homeDirectory: homeDirectory).projectAssignments[sessionID]
            .map { "project:\($0)" }
            ?? projectlessKey
    }

    static func orderedLayout(
        _ sessions: [CatalogSession],
        sidebar: CodexSidebarOrdering
    ) -> CatalogLayout {
        let sessionsByProject = Dictionary(grouping: sessions, by: \.projectKey)
        let hasProjectless = sessionsByProject[projectlessKey]?.isEmpty == false

        var orderedProjectKeys = sidebar.projectIDs.map { "project:\($0)" }
        for key in sessions.filter({ $0.projectID != nil }).map(\.projectKey)
            where !orderedProjectKeys.contains(key) {
            orderedProjectKeys.append(key)
        }

        let namedRowLimit = hasProjectless ? 9 : 10
        orderedProjectKeys = Array(orderedProjectKeys.prefix(namedRowLimit))
        var projectRows = Dictionary(
            uniqueKeysWithValues: orderedProjectKeys.enumerated().map { ($0.element, $0.offset) }
        )
        if hasProjectless {
            projectRows[projectlessKey] = orderedProjectKeys.count
        }

        let pinnedRanks = Dictionary(
            uniqueKeysWithValues: sidebar.pinnedThreadIDs.enumerated().map { ($0.element, $0.offset) }
        )
        var placements: [CatalogPlacement] = []
        for (projectKey, row) in projectRows.sorted(by: { $0.value < $1.value }) {
            let projectID = projectKey.hasPrefix("project:")
                ? String(projectKey.dropFirst("project:".count))
                : nil
            let explicitOrder = projectID.flatMap { sidebar.threadIDsByProject[$0] } ?? []
            let explicitRanks = Dictionary(
                uniqueKeysWithValues: explicitOrder.enumerated().map { ($0.element, $0.offset) }
            )
            let orderedSessions = (sessionsByProject[projectKey] ?? []).sorted { lhs, rhs in
                let lhsPinned = pinnedRanks[lhs.sessionID]
                let rhsPinned = pinnedRanks[rhs.sessionID]
                if lhsPinned != nil || rhsPinned != nil {
                    if lhsPinned == nil { return false }
                    if rhsPinned == nil { return true }
                    return lhsPinned! < rhsPinned!
                }
                let lhsExplicit = explicitRanks[lhs.sessionID]
                let rhsExplicit = explicitRanks[rhs.sessionID]
                if lhsExplicit != nil || rhsExplicit != nil {
                    if lhsExplicit == nil { return false }
                    if rhsExplicit == nil { return true }
                    return lhsExplicit! < rhsExplicit!
                }
                if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
                return lhs.sessionID < rhs.sessionID
            }
            for (column, session) in orderedSessions.prefix(10).enumerated() {
                placements.append(CatalogPlacement(session: session, row: row, column: column))
            }
        }
        return CatalogLayout(projectRows: projectRows, placements: placements)
    }

    static func fittingGrid(_ sessions: [CatalogSession]) -> [CatalogSession] {
        orderedLayout(sessions, sidebar: .empty).placements.map(\.session)
    }

    static func resolvedForkProjectID(
        explicitProjectID: String?,
        forkedFromID: String?,
        parentByChild: [String: String],
        projectBySession: [String: String]
    ) -> String? {
        if let explicitProjectID, !explicitProjectID.isEmpty {
            return explicitProjectID
        }
        var current = forkedFromID
        var visited = Set<String>()
        while let sessionID = current, visited.insert(sessionID).inserted {
            if let projectID = projectBySession[sessionID], !projectID.isEmpty {
                return projectID
            }
            current = parentByChild[sessionID]
        }
        return nil
    }

    static func forkedFromID(sessionMetaLine: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: sessionMetaLine) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any],
              let forkedFromID = payload["forked_from_id"] as? String,
              !forkedFromID.isEmpty else { return nil }
        return forkedFromID
    }

    private static func catalogSessions(
        databasePath: String,
        sidebar: CodexSidebarOrdering
    ) throws -> [CatalogSession] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {
            defer { if database != nil { sqlite3_close(database) } }
            throw CLIError.runtime("Could not open Codex task catalog read-only at \(databasePath)")
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT thread_id, cwd, NULLIF(project_id, ''), source_recency_at, source_created_at
            FROM local_thread_catalog
            WHERE host_id = 'local'
              AND missing_candidate = 0
              AND cwd IS NOT NULL
              AND cwd != ''
            ORDER BY source_recency_at DESC, thread_id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CLIError.runtime("Could not prepare Codex task catalog query")
        }
        defer { sqlite3_finalize(statement) }

        var result: [CatalogSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionText = sqlite3_column_text(statement, 0),
                  let cwdText = sqlite3_column_text(statement, 1) else { continue }
            let sessionID = String(cString: sessionText)
            let catalogProjectID = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            result.append(CatalogSession(
                sessionID: sessionID,
                cwd: String(cString: cwdText),
                projectID: catalogProjectID ?? sidebar.projectAssignments[sessionID],
                recency: sqlite3_column_double(statement, 3),
                createdAt: sqlite3_column_double(statement, 4)
            ))
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw CLIError.runtime("Could not read Codex task catalog: \(String(cString: sqlite3_errmsg(database)))")
        }
        return result
    }

    private static func forkSessions(
        homeDirectory: String,
        catalogSessions: [CatalogSession],
        sidebar: CodexSidebarOrdering
    ) -> [CatalogSession] {
        let databasePath = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".codex/state_5.sqlite")
            .path
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }

        var projectBySession = sidebar.projectAssignments
        for session in catalogSessions {
            if let projectID = session.projectID {
                projectBySession[session.sessionID] = projectID
            }
        }
        appendStateProjects(database: database, to: &projectBySession)
        let parentByChild = stateParentRelationships(database: database)
        let candidates = stateForkSessions(database: database)

        return candidates.map { candidate in
            let forkedFromID = firstLine(atPath: candidate.rolloutPath).flatMap(forkedFromID)
            let projectID = resolvedForkProjectID(
                explicitProjectID: candidate.projectID ?? sidebar.projectAssignments[candidate.sessionID],
                forkedFromID: forkedFromID,
                parentByChild: parentByChild,
                projectBySession: projectBySession
            )
            return CatalogSession(
                sessionID: candidate.sessionID,
                cwd: candidate.cwd,
                projectID: projectID,
                recency: candidate.recency,
                createdAt: candidate.createdAt
            )
        }
    }

    private static func appendStateProjects(
        database: OpaquePointer,
        to projectBySession: inout [String: String]
    ) {
        let sql = "SELECT id, project_id FROM threads WHERE project_id IS NOT NULL AND project_id != ''"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionText = sqlite3_column_text(statement, 0),
                  let projectText = sqlite3_column_text(statement, 1) else { continue }
            projectBySession[String(cString: sessionText)] = String(cString: projectText)
        }
    }

    private static func stateParentRelationships(database: OpaquePointer) -> [String: String] {
        let sql = "SELECT child_thread_id, parent_thread_id FROM thread_spawn_edges"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let childText = sqlite3_column_text(statement, 0),
                  let parentText = sqlite3_column_text(statement, 1) else { continue }
            result[String(cString: childText)] = String(cString: parentText)
        }
        return result
    }

    private static func stateForkSessions(database: OpaquePointer) -> [ForkCatalogSession] {
        let sql = """
            SELECT id, cwd, NULLIF(project_id, ''), recency_at, created_at, rollout_path
            FROM threads
            WHERE thread_source = 'agent_forked_thread'
              AND cwd != ''
            ORDER BY recency_at DESC, id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [ForkCatalogSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionText = sqlite3_column_text(statement, 0),
                  let cwdText = sqlite3_column_text(statement, 1),
                  let rolloutText = sqlite3_column_text(statement, 5) else { continue }
            result.append(ForkCatalogSession(
                sessionID: String(cString: sessionText),
                cwd: String(cString: cwdText),
                projectID: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                recency: sqlite3_column_double(statement, 3),
                createdAt: sqlite3_column_double(statement, 4),
                rolloutPath: String(cString: rolloutText)
            ))
        }
        return result
    }

    private static func firstLine(atPath path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var result = Data()
        while true {
            let chunk: Data
            do {
                guard let nextChunk = try handle.read(upToCount: 16 * 1024), !nextChunk.isEmpty else {
                    return result.isEmpty ? nil : result
                }
                chunk = nextChunk
            } catch {
                return nil
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                result.append(chunk[..<newline])
                return result
            }
            result.append(chunk)
            if result.count > 2 * 1024 * 1024 { return nil }
        }
    }

    private static func sidebarOrdering(homeDirectory: String) -> CodexSidebarOrdering {
        let stateURL = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }

        let projectIDs = root["project-order"] as? [String] ?? []
        let pinnedThreadIDs = root["pinned-thread-ids"] as? [String] ?? []

        var projectAssignments: [String: String] = [:]
        if let assignments = root["thread-project-assignments"] as? [String: Any] {
            for (sessionID, rawAssignment) in assignments {
                guard let assignment = rawAssignment as? [String: Any],
                      assignment["projectKind"] as? String == "local",
                      let projectID = assignment["projectId"] as? String,
                      !projectID.isEmpty else { continue }
                projectAssignments[sessionID] = projectID
            }
        }

        var threadIDsByProject: [String: [String]] = [:]
        if let orders = root["sidebar-project-thread-orders"] as? [String: Any] {
            for (projectID, rawOrder) in orders {
                guard let order = rawOrder as? [String: Any],
                      let threadIDs = order["threadIds"] as? [String] else { continue }
                threadIDsByProject[projectID] = threadIDs
            }
        }

        return CodexSidebarOrdering(
            projectIDs: projectIDs,
            threadIDsByProject: threadIDsByProject,
            pinnedThreadIDs: pinnedThreadIDs,
            projectAssignments: projectAssignments
        )
    }
}
