import Foundation
import SQLite3

enum CodexApprovalsReviewer: String {
    case user
    case autoReview = "auto_review"
    case guardianSubagent = "guardian_subagent"
}

enum CodexPermissionDisplayRoute: Equatable {
    case user(reason: String)
    case automatic(reviewer: String?)
}

enum CodexApprovalRouting {
    private static let rolloutTailLimit: UInt64 = 4 * 1024 * 1024

    static func displayRoute(
        for hook: HookInput,
        homeDirectory: String = NSHomeDirectory()
    ) -> CodexPermissionDisplayRoute {
        if hook.directlyRequestsUserPermission {
            return .user(reason: "request_permissions")
        }

        let reviewer = approvalsReviewer(
            sessionID: hook.sessionID,
            homeDirectory: homeDirectory
        )
        if reviewer == .user {
            return .user(reason: "reviewer_user")
        }

        // PermissionRequest runs before Codex chooses between automatic review and
        // a user-facing request. Unknown routing must therefore stay in the working
        // state; showing approval here would recreate the false orange signal.
        return .automatic(reviewer: reviewer?.rawValue)
    }

    static func latestApprovalsReviewer(in lines: [String]) -> CodexApprovalsReviewer? {
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = root["type"] as? String,
                  let payload = root["payload"] as? [String: Any] else { continue }

            let rawReviewer: String?
            switch type {
            case "turn_context":
                rawReviewer = payload["approvals_reviewer"] as? String
            case "event_msg":
                guard payload["type"] as? String == "thread_settings_applied",
                      let settings = payload["thread_settings"] as? [String: Any] else { continue }
                rawReviewer = settings["approvals_reviewer"] as? String
            default:
                continue
            }
            if let rawReviewer, let reviewer = CodexApprovalsReviewer(rawValue: rawReviewer) {
                return reviewer
            }
        }
        return nil
    }

    private static func approvalsReviewer(
        sessionID: String,
        homeDirectory: String
    ) -> CodexApprovalsReviewer? {
        let databasePath = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".codex/state_5.sqlite")
            .path
        guard let rolloutPath = rolloutPath(
            sessionID: sessionID,
            databasePath: databasePath
        ), let lines = rolloutTailLines(atPath: rolloutPath) else { return nil }
        return latestApprovalsReviewer(in: lines)
    }

    private static func rolloutPath(sessionID: String, databasePath: String) -> String? {
        guard FileManager.default.fileExists(atPath: databasePath) else { return nil }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databasePath,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        return sessionID.withCString { sessionText in
            guard sqlite3_bind_text(statement, 1, sessionText, -1, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let pathText = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: pathText)
        }
    }

    private static func rolloutTailLines(atPath path: String) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let fileSize = try handle.seekToEnd()
            let offset = fileSize > rolloutTailLimit ? fileSize - rolloutTailLimit : 0
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd() else { return nil }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        } catch {
            return nil
        }
    }
}
