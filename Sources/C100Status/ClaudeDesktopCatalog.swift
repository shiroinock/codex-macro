import AppKit
import Darwin
import Foundation

/// `SessionSourceProvider` for Claude Code sessions running inside the
/// Claude Desktop app (M4, enterprise priority 3).
///
/// Like `ClaudeSessionsCatalog` (M3), this is a **hook-authoritative
/// complement**, not the source of truth for status: `Daemon` registers and
/// updates a Desktop session's status from `c100-status hook --source
/// claude` events (Desktop's Claude Code runs with `CLAUDE_CODE_ENTRYPOINT
/// =claude-desktop`, no `CLAUDE_CONFIG_DIR` override, so it shares `~/.claude`
/// with a plain-terminal `claude` -- see `HookEnvironment` in `main.swift`).
/// `snapshot()` exists purely to (a) seed already-open Desktop sessions the
/// daemon missed (e.g. it was restarted mid-session) and (b) let `Daemon`
/// detect a Desktop session that's gone away (archived, aged out, or the app
/// quit) without a `SessionEnd` hook ever arriving, the same GC role
/// `ClaudeSessionsCatalog` plays for `sessions/<pid>.json`.
///
/// Investigated environment fact (confirmed against a real, running Claude
/// Desktop install -- see the implementation plan): Desktop writes one
/// `local_<uuid>.json` file per session under
/// `~/Library/Application Support/Claude/claude-code-sessions/<accountId>/
/// <workspaceId>/local_<uuid>.json`. The file's own `sessionId` field carries
/// that `local_` prefix; `cliSessionId` is the *other* id -- the one that
/// matches the Claude Code hook `session_id` and the `<configDir>/projects/
/// <flattened-cwd>/<cliSessionId>.jsonl` transcript filename -- so it, not
/// `sessionId`, is what this catalog reports as `AgentSession.sessionID`.
final class ClaudeDesktopCatalog: SessionSourceProvider {
    let kind: SessionSourceKind = .claudeDesktop

    /// Desktop's `local_*.json` files run a few hundred KB in practice (they
    /// carry MCP tool config, permission history, etc. alongside the handful
    /// of fields this catalog actually reads); cap well above that observed
    /// size while still refusing to read something unbounded.
    static let maxFileBytes = 4 * 1024 * 1024
    static let maxFilesPerScan = 500
    /// Default liveness window: a session survives into the snapshot if it's
    /// not archived and either its own `lastActivityAt` or its transcript's
    /// mtime falls within this window of "now".
    static let defaultStaleAfter: TimeInterval = 6 * 60 * 60

    static let desktopBundleIdentifier = "com.anthropic.claudefordesktop"

    private let desktopSessionsDir: String
    /// Fixed per the investigated environment facts: Desktop's Claude Code
    /// never sets `CLAUDE_CONFIG_DIR`, so its transcripts always live under
    /// the plain `~/.claude`, regardless of `--claude-config-dirs`.
    private let claudeConfigDir: String
    private let staleAfter: TimeInterval
    private let fileManager: FileManager
    private let isDesktopRunning: () -> Bool
    /// Lets a session the daemon has already hook-registered as
    /// `claude-desktop` outlive this catalog's own file-timestamp-based
    /// liveness window -- hooks are authoritative once they've fired, this
    /// scan's timestamps are only a fallback for sessions the daemon hasn't
    /// heard from directly (yet, or ever, if it was restarted).
    private let isHookRegistered: (String) -> Bool
    private let now: () -> Date
    private let log: (StatusLogger.Level, String) -> Void

    init(
        desktopSessionsDir: String,
        homeDirectory: String = NSHomeDirectory(),
        staleAfter: TimeInterval = ClaudeDesktopCatalog.defaultStaleAfter,
        fileManager: FileManager = .default,
        isDesktopRunning: @escaping () -> Bool = ClaudeDesktopCatalog.defaultIsDesktopRunning,
        isHookRegistered: @escaping (String) -> Bool = { _ in false },
        now: @escaping () -> Date = Date.init,
        log: @escaping (StatusLogger.Level, String) -> Void = { _, _ in }
    ) {
        self.desktopSessionsDir = desktopSessionsDir
        claudeConfigDir = homeDirectory + "/.claude"
        self.staleAfter = staleAfter
        self.fileManager = fileManager
        self.isDesktopRunning = isDesktopRunning
        self.isHookRegistered = isHookRegistered
        self.now = now
        self.log = log
    }

    /// Default sessions directory Desktop itself writes to.
    static func defaultSessionsDir(homeDirectory: String = NSHomeDirectory()) -> String {
        homeDirectory + "/Library/Application Support/Claude/claude-code-sessions"
    }

    func snapshot() throws -> [AgentSession] {
        // No point scanning (or, more importantly, no point keeping stale
        // entries alive) if Claude Desktop isn't even running: nothing could
        // be navigated to, and a quit app can't fire `SessionEnd` for
        // whatever it had open, so the daemon would otherwise hold those
        // sessions' keys lit forever.
        guard isDesktopRunning() else { return [] }

        var sessions: [AgentSession] = []
        var filesRead = 0
        let currentTime = now()
        guard let accountDirs = try? fileManager.contentsOfDirectory(atPath: desktopSessionsDir) else { return [] }

        scan: for accountDir in accountDirs.sorted() {
            let accountPath = desktopSessionsDir + "/" + accountDir
            guard isDirectory(accountPath) else { continue }
            guard let workspaceDirs = try? fileManager.contentsOfDirectory(atPath: accountPath) else { continue }
            for workspaceDir in workspaceDirs.sorted() {
                let workspacePath = accountPath + "/" + workspaceDir
                guard isDirectory(workspacePath) else { continue }
                guard let names = try? fileManager.contentsOfDirectory(atPath: workspacePath) else { continue }
                for name in names.sorted() {
                    // `scheduled-tasks.json` and anything else in the
                    // workspace directory that isn't a per-session file is
                    // deliberately out of scope.
                    guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
                    guard filesRead < Self.maxFilesPerScan else {
                        log(.warning, "claude desktop scan dir=\(desktopSessionsDir) action=truncated limit=\(Self.maxFilesPerScan)")
                        break scan
                    }
                    filesRead += 1
                    let path = workspacePath + "/" + name
                    guard let entry = Self.readSessionFile(path: path, maxBytes: Self.maxFileBytes) else { continue }
                    guard !entry.cliSessionID.isEmpty else {
                        log(.warning, "claude desktop file=\(path) action=skipped reason=missing_cli_session_id")
                        continue
                    }
                    guard !entry.isArchived else { continue }

                    let normalizedCWD = URL(fileURLWithPath: entry.cwd).standardizedFileURL.path
                    let hookRegistered = isHookRegistered(entry.cliSessionID)
                    let recentByActivity = Self.isRecent(
                        epochMilliseconds: entry.lastActivityAt,
                        now: currentTime,
                        within: staleAfter
                    )
                    let recentByTranscript = Self.isTranscriptRecent(
                        configDir: claudeConfigDir,
                        cwd: normalizedCWD,
                        sessionID: entry.cliSessionID,
                        now: currentTime,
                        within: staleAfter,
                        fileManager: fileManager
                    )
                    guard hookRegistered || recentByActivity || recentByTranscript else { continue }

                    sessions.append(
                        AgentSession(
                            sourceKind: .claudeDesktop,
                            sessionID: entry.cliSessionID,
                            cwd: normalizedCWD,
                            rowHints: .none,
                            recency: (entry.lastActivityAt ?? 0) / 1_000,
                            rowRank: nil,
                            columnRank: nil,
                            seedStatus: nil,
                            navigation: .claudeDesktop
                        )
                    )
                }
            }
        }
        return sessions
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isRecent(epochMilliseconds: Double?, now: Date, within staleAfter: TimeInterval) -> Bool {
        guard let epochMilliseconds else { return false }
        let activityDate = Date(timeIntervalSince1970: epochMilliseconds / 1_000)
        return now.timeIntervalSince(activityDate) <= staleAfter
    }

    /// Unlike `ClaudeSessionsCatalog.isTranscriptStale` (which treats a
    /// missing transcript as "not stale" so a brand-new hook-registered
    /// session isn't GC'd before its transcript exists), this returns
    /// `false` for a missing transcript -- here it's one of two *positive*
    /// liveness signals feeding an `||`, not the sole GC trigger, so
    /// "unknown" must not count as "recent".
    static func isTranscriptRecent(
        configDir: String,
        cwd: String,
        sessionID: String,
        now: Date,
        within staleAfter: TimeInterval,
        fileManager: FileManager = .default
    ) -> Bool {
        let path = ClaudeSessionsCatalog.transcriptPath(configDir: configDir, cwd: cwd, sessionID: sessionID)
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return false
        }
        return now.timeIntervalSince(modifiedAt) <= staleAfter
    }

    static func defaultIsDesktopRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleIdentifier).isEmpty
    }

    /// Opens with `O_NOFOLLOW` (refuse symlinks) and enforces `maxBytes`
    /// before decoding, mirroring `ClaudeSessionsCatalog.readSessionFile`'s
    /// safe-open pattern: these files live in a directory Claude Desktop
    /// itself controls, but this process should never trust their size or
    /// type unconditionally.
    static func readSessionFile(path: String, maxBytes: Int) -> ClaudeDesktopSessionFileEntry? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_size >= 0,
              metadata.st_size <= maxBytes else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return nil }
        return try? JSONDecoder().decode(ClaudeDesktopSessionFileEntry.self, from: data)
    }
}

/// Decoded shape of `<desktopSessionsDir>/<accountId>/<workspaceId>/
/// local_<uuid>.json`, confirmed against a real file written by a live
/// Claude Desktop install (see M4 investigation notes). The real file also
/// carries `model`, `permissionMode`, `enabledMcpTools`,
/// `remoteMcpServersConfig`, `scheduledTaskId`, `spawnSeed`, and several
/// other fields this catalog has no use for; `Decodable` simply ignores them.
struct ClaudeDesktopSessionFileEntry: Decodable, Equatable {
    /// `local_<uuid>` -- Desktop's own id for the session file, distinct
    /// from `cliSessionID` below. Kept only for diagnostics; navigation and
    /// dedup key off `cliSessionID`.
    let sessionID: String
    /// Matches the Claude Code hook `session_id` and the
    /// `<configDir>/projects/<flattened-cwd>/<cliSessionId>.jsonl` transcript
    /// filename -- this, not `sessionID`, is `AgentSession.sessionID`.
    let cliSessionID: String
    let cwd: String
    let isArchived: Bool
    /// Epoch milliseconds; `nil` if Desktop ever omits it (not observed in
    /// practice, but decoded as optional rather than trusted unconditionally).
    let lastActivityAt: Double?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cliSessionID = "cliSessionId"
        case cwd
        case isArchived
        case lastActivityAt
        case title
    }
}
