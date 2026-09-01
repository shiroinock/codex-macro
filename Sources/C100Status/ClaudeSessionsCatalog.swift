import Darwin
import Foundation

/// The three Claude profile directories hook payloads and `sessions/*.json`
/// files live under (`c100-status`'s own confirmed environment facts --
/// see the implementation plan). `--claude-config-dirs` (main.swift) can add
/// further directories on top of this default set.
enum ClaudeConfigDirs {
    static func defaults(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [
            homeDirectory + "/.claude",
            homeDirectory + "/.claude-config/max",
            homeDirectory + "/.claude-config/enterprise",
        ]
    }

    /// Merges the default three directories with any `--claude-config-dirs`
    /// additions, de-duplicating (a directory passed on the command line that
    /// happens to already be a default is not scanned twice).
    static func resolved(additional: [String], homeDirectory: String = NSHomeDirectory()) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for dir in defaults(homeDirectory: homeDirectory) + additional {
            let normalized = URL(fileURLWithPath: dir).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}

/// Decoded shape of `<configDir>/sessions/<pid>.json`, as confirmed against
/// a real file from a live Claude Code process (see M3 investigation notes).
/// Only the fields this catalog actually needs are declared; the real file
/// carries additional fields (version, peerFeatures, messagingSocketPath,
/// ...) that are irrelevant here and simply ignored by `Decodable`.
struct ClaudeSessionFileEntry: Decodable, Equatable {
    let pid: Int
    let sessionID: String
    let cwd: String

    enum CodingKeys: String, CodingKey {
        case pid
        case sessionID = "sessionId"
        case cwd
    }
}

/// `SessionSourceProvider` for Claude Code launched directly in a terminal
/// (M3). Unlike Codex (catalog-authoritative) or herdr (polled in the
/// background), this is a **hook-authoritative complement**: `Daemon`
/// registers/updates sessions from hooks as they arrive, and this catalog's
/// `snapshot()` exists only to (a) seed already-running sessions the daemon
/// missed (e.g. it was restarted mid-session) and (b) let `Daemon` detect
/// when a hook-registered session's process has died or its session file
/// disappeared without a `SessionEnd` hook ever arriving (crash, kill -9,
/// etc.) -- see `Daemon.syncCatalog`'s claude-terminal GC step, which is
/// driven by comparing consecutive `snapshot()` results the same way
/// `HerdrCatalog` already drives its own pane-closed GC.
///
/// The scan itself is synchronous (unlike `HerdrCatalog`'s dedicated
/// refresh thread): `sessions/*.json` under each config dir is a handful of
/// small files, not a subprocess round trip, so doing it inline on the
/// daemon's 2s sync cadence is cheap enough not to need a background thread.
/// `maxFilesPerScan` still caps the file-I/O budget per sync in case a
/// config dir accumulates an unexpectedly large number of stale entries.
final class ClaudeSessionsCatalog: SessionSourceProvider {
    let kind: SessionSourceKind = .claudeTerminal

    /// Safety cap on `sessions/<pid>.json` file size: these are small,
    /// hand-sized status blobs (hundreds of bytes in practice); anything
    /// larger is refused rather than read in full, mirroring the defensive
    /// posture `StatusLogger`/`StateStore` already take for files this
    /// process doesn't fully control the contents of.
    static let maxFileBytes = 64 * 1024
    /// Upper bound on `sessions/<pid>.json` files read per `snapshot()`
    /// call across all config dirs combined.
    static let maxFilesPerScan = 500

    private let configDirs: [String]
    private let isProcessAlive: (Int32) -> Bool
    private let fileManager: FileManager
    private let log: (StatusLogger.Level, String) -> Void

    init(
        configDirs: [String],
        isProcessAlive: @escaping (Int32) -> Bool = ClaudeSessionsCatalog.defaultIsProcessAlive,
        fileManager: FileManager = .default,
        log: @escaping (StatusLogger.Level, String) -> Void = { _, _ in }
    ) {
        self.configDirs = configDirs
        self.isProcessAlive = isProcessAlive
        self.fileManager = fileManager
        self.log = log
    }

    func snapshot() throws -> [AgentSession] {
        var sessions: [AgentSession] = []
        var filesRead = 0
        for configDir in configDirs {
            let sessionsDir = configDir + "/sessions"
            guard let names = try? fileManager.contentsOfDirectory(atPath: sessionsDir) else { continue }
            for name in names.sorted() {
                guard filesRead < Self.maxFilesPerScan else {
                    log(.warning, "claude sessions scan dir=\(sessionsDir) action=truncated limit=\(Self.maxFilesPerScan)")
                    break
                }
                guard let filenamePID = Self.parsePID(fromFilename: name) else { continue }
                filesRead += 1
                let path = sessionsDir + "/" + name
                guard isProcessAlive(Int32(filenamePID)) else { continue }
                guard let entry = Self.readSessionFile(path: path, maxBytes: Self.maxFileBytes) else { continue }
                guard entry.pid == filenamePID else {
                    // Filename is the authoritative pid (a stale/reused
                    // file whose contents don't match its own name is
                    // suspicious enough to skip rather than trust).
                    log(.warning, "claude sessions file=\(path) action=skipped reason=pid_mismatch")
                    continue
                }
                let normalizedCWD = URL(fileURLWithPath: entry.cwd).standardizedFileURL.path
                sessions.append(
                    AgentSession(
                        sourceKind: .claudeTerminal,
                        sessionID: entry.sessionID,
                        cwd: normalizedCWD,
                        rowHints: .none,
                        recency: Date().timeIntervalSince1970,
                        rowRank: nil,
                        columnRank: nil,
                        seedStatus: nil,
                        navigation: .ghosttyTab(sessionID: entry.sessionID, cwd: normalizedCWD, pid: Int32(filenamePID))
                    )
                )
            }
        }
        return sessions
    }

    /// `kill(pid, 0)`: sends no signal, just checks whether the process
    /// exists and is reachable. `ESRCH` (no such process) means stale;
    /// `EPERM` still means the process exists (owned by someone else /
    /// privilege-separated) so counts as alive.
    static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// `sessions/<pid>.json` only -- anything else (`.key` files, directories,
    /// non-numeric names) is ignored.
    static func parsePID(fromFilename name: String) -> Int? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = name.dropLast(".json".count)
        guard !stem.isEmpty, stem.allSatisfy(\.isNumber) else { return nil }
        return Int(stem)
    }

    /// Opens with `O_NOFOLLOW` (refuse symlinks) and enforces `maxBytes`
    /// before decoding, mirroring `StatusLogger`'s safe-open pattern:
    /// these files live in a directory Claude Code itself controls, but
    /// this process should never trust their size or type unconditionally.
    static func readSessionFile(path: String, maxBytes: Int) -> ClaudeSessionFileEntry? {
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
        return try? JSONDecoder().decode(ClaudeSessionFileEntry.self, from: data)
    }

    // MARK: - Cross-source stale GC (used by `Daemon` for every Claude
    // session it has ever hook-registered, regardless of source: herdr,
    // terminal, or desktop).

    /// Claude Code flattens an absolute cwd into a project directory name by
    /// replacing every `/` with `-` (confirmed against real
    /// `<configDir>/projects/` directory names, e.g.
    /// `/Users/dev/repo` -> `-Users-dev-repo`).
    static func flattenedProjectDirectoryName(cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    static func transcriptPath(configDir: String, cwd: String, sessionID: String) -> String {
        configDir + "/projects/" + flattenedProjectDirectoryName(cwd: cwd) + "/" + sessionID + ".jsonl"
    }

    /// A session is considered stale once its transcript file's mtime is
    /// older than `staleAfter`. A *missing* transcript is never treated as
    /// stale here -- that just means the transcript hasn't been written yet
    /// (a brand new session) or this daemon doesn't know the right
    /// `configDir`/`cwd` pair for it, neither of which should cause a
    /// spurious removal.
    static func isTranscriptStale(
        configDir: String,
        cwd: String,
        sessionID: String,
        now: Date = Date(),
        staleAfter: TimeInterval,
        fileManager: FileManager = .default
    ) -> Bool {
        let path = transcriptPath(configDir: configDir, cwd: cwd, sessionID: sessionID)
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return false
        }
        return now.timeIntervalSince(modifiedAt) > staleAfter
    }

    /// M6: directory Claude Code writes a subagent's own transcript into
    /// while it runs, one `agent-*.jsonl` file per subagent invocation.
    static func subagentsDirectoryPath(configDir: String, cwd: String, sessionID: String) -> String {
        configDir + "/projects/" + flattenedProjectDirectoryName(cwd: cwd) + "/" + sessionID + "/subagents"
    }

    /// Whether every `agent-*.jsonl` under `sessionID`'s subagents directory
    /// has gone untouched for longer than `staleAfter` -- used by
    /// `Daemon.applyActiveSubagentStaleSweep` as a take-over-if-lost check
    /// for `SubagentStart`/`SubagentStop` bookkeeping, well ahead of that
    /// tracking's own 2h TTL.
    ///
    /// Returns `nil` (rather than `false`) whenever the directory is
    /// missing/unreadable or contains no matching files -- deliberately
    /// indistinguishable states, both meaning "nothing on disk to check
    /// against", mirroring `isTranscriptStale`'s "missing means unknown, not
    /// stale" rule so an unreadable directory never gets treated as a false
    /// staleness signal. Only when at least one `agent-*.jsonl` is found,
    /// and every one of them has an mtime older than `staleAfter`, does this
    /// return `true`.
    static func isSubagentActivityStale(
        configDir: String,
        cwd: String,
        sessionID: String,
        now: Date = Date(),
        staleAfter: TimeInterval,
        fileManager: FileManager = .default
    ) -> Bool? {
        let directory = subagentsDirectoryPath(configDir: configDir, cwd: cwd, sessionID: sessionID)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return nil }
        let agentFiles = entries.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
        guard !agentFiles.isEmpty else { return nil }
        for file in agentFiles {
            guard let attributes = try? fileManager.attributesOfItem(atPath: directory + "/" + file),
                  let modifiedAt = attributes[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(modifiedAt) <= staleAfter { return false }
        }
        return true
    }

    /// Freshness of one specific subagent's transcript
    /// (`agent-<agentID>.jsonl`). `nil` when the file doesn't exist -- which
    /// includes tracker fallback keys that never correspond to a file, and
    /// a just-started subagent that hasn't written its transcript yet, so
    /// callers must pair this with a start-time grace window rather than
    /// treating `nil` as proof of death.
    static func isSubagentTranscriptFresh(
        configDir: String,
        cwd: String,
        sessionID: String,
        agentID: String,
        now: Date = Date(),
        staleAfter: TimeInterval,
        fileManager: FileManager = .default
    ) -> Bool? {
        let path = subagentsDirectoryPath(configDir: configDir, cwd: cwd, sessionID: sessionID)
            + "/agent-\(agentID).jsonl"
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(modifiedAt) <= staleAfter
    }
}
