import Foundation

/// Resolves the `herdr` CLI binary path, shared by `HerdrCatalog` (2s
/// polling) and `NavigationRouter` (focus dispatch) so both agree on which
/// binary is in play.
enum HerdrBinaryResolver {
    static let pathCandidates = [
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
        NSHomeDirectory() + "/.cargo/bin/herdr",
    ]

    /// `--herdr-bin` (explicit) wins, then `HERDR_BIN` env, then the PATH
    /// candidates above. Returns `nil` (herdr support silently disabled)
    /// when none resolve to an executable file.
    static func resolve(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let explicitPath, fileManager.isExecutableFile(atPath: explicitPath) {
            return explicitPath
        }
        if let envPath = environment["HERDR_BIN"], fileManager.isExecutableFile(atPath: envPath) {
            return envPath
        }
        return pathCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

/// Runs a `herdr` subcommand with a hard wall-clock timeout (herdr talks to
/// a local unix socket, so a hang means the socket/daemon is wedged -- this
/// must never block the daemon's 10ms HID poll loop or its background
/// refresh thread indefinitely).
enum HerdrProcessRunner {
    enum RunError: Error, CustomStringConvertible {
        case timedOut(command: String, seconds: TimeInterval)
        case nonZeroExit(command: String, status: Int32, stderr: String)

        var description: String {
            switch self {
            case let .timedOut(command, seconds):
                "herdr \(command) timed out after \(seconds)s"
            case let .nonZeroExit(command, status, stderr):
                "herdr \(command) exited \(status): \(stderr)"
            }
        }
    }

    static func run(
        binary: String,
        arguments: [String],
        timeout: TimeInterval,
        socketPath: String? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if environment["HERDR_SOCKET_PATH"] == nil {
            environment["HERDR_SOCKET_PATH"] = socketPath ?? NSHomeDirectory() + "/.config/herdr/herdr.sock"
        }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw RunError.timedOut(command: arguments.joined(separator: " "), seconds: timeout)
        }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorText = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw RunError.nonZeroExit(
                command: arguments.joined(separator: " "),
                status: process.terminationStatus,
                stderr: errorText
            )
        }
        return data
    }
}

// MARK: - Wire types

struct HerdrAgentListResponse: Decodable {
    struct ResultPayload: Decodable {
        let agents: [HerdrAgentEntry]
    }

    let result: ResultPayload
}

struct HerdrAgentEntry: Decodable {
    struct Session: Decodable {
        let value: String
    }

    let agent: String
    let agentSession: Session
    let agentStatus: String
    let cwd: String?
    let paneID: String
    let workspaceID: String

    enum CodingKeys: String, CodingKey {
        case agent
        case agentSession = "agent_session"
        case agentStatus = "agent_status"
        case cwd
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
    }
}

struct HerdrWorkspaceListResponse: Decodable {
    struct ResultPayload: Decodable {
        let workspaces: [HerdrWorkspaceEntry]
    }

    let result: ResultPayload
}

struct HerdrWorkspaceEntry: Decodable {
    let workspaceID: String
    let number: Int
    let label: String

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
    }
}

/// A thread-safe last-known-good snapshot holder. Decoupled from process
/// execution / parsing so it (and the 15s stale-grace behavior) can be unit
/// tested without spawning `herdr` or a background thread.
final class HerdrSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [HerdrCatalog.SessionEntry] = []
    private var lastSuccessAt: Date = .distantPast

    func recordSuccess(_ entries: [HerdrCatalog.SessionEntry], at date: Date = Date()) {
        lock.lock()
        self.entries = entries
        lastSuccessAt = date
        lock.unlock()
    }

    /// Returns the last successfully fetched entries as long as that fetch
    /// happened within `staleGrace` seconds; beyond that, an empty list (the
    /// herdr provider goes dark rather than showing stale panes forever).
    func currentEntries(now: Date = Date(), staleGrace: TimeInterval) -> [HerdrCatalog.SessionEntry] {
        lock.lock()
        let entries = self.entries
        let successAt = lastSuccessAt
        lock.unlock()
        guard now.timeIntervalSince(successAt) <= staleGrace else { return [] }
        return entries
    }
}

/// herdr-backed `SessionSourceProvider` (M2): polls `herdr agent list` /
/// `herdr workspace list` on a dedicated background thread every 2 seconds
/// and exposes the result via a lock-protected snapshot so `snapshot()` --
/// called from the daemon's main loop -- never blocks on a process spawn.
final class HerdrCatalog: SessionSourceProvider, @unchecked Sendable {
    let kind: SessionSourceKind = .claudeHerdr

    struct SessionEntry: Equatable {
        let sessionID: String
        let cwd: String
        let workspaceID: String
        let workspaceNumber: Int
        let paneID: String
        let paneNumber: Int?
        let seedStatus: AgentStatus
    }

    private let binaryPath: String?
    private let refreshInterval: TimeInterval
    private let staleGrace: TimeInterval
    private let processTimeout: TimeInterval
    private let store = HerdrSnapshotStore()
    private let log: (StatusLogger.Level, String) -> Void

    /// - Parameters:
    ///   - herdrBinaryPath: explicit `--herdr-bin` override, if any.
    ///   - environment: injectable for tests.
    init(
        herdrBinaryPath: String?,
        refreshInterval: TimeInterval = 2,
        staleGrace: TimeInterval = 15,
        processTimeout: TimeInterval = 2,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping (StatusLogger.Level, String) -> Void = { _, _ in }
    ) {
        self.refreshInterval = refreshInterval
        self.staleGrace = staleGrace
        self.processTimeout = processTimeout
        self.log = log
        binaryPath = HerdrBinaryResolver.resolve(explicitPath: herdrBinaryPath, environment: environment)
        if let binaryPath {
            log(.info, "herdr binary=\(binaryPath) polling=enabled interval_s=\(refreshInterval)")
            startBackgroundRefresh()
        } else {
            log(.info, "herdr binary not found; herdr source disabled (checked --herdr-bin, HERDR_BIN, and PATH candidates)")
        }
    }

    /// Enumerated so `snapshot()` (called from the main loop) never spawns a
    /// process: it only reads the lock-protected result of the background
    /// thread's most recent successful fetch.
    func snapshot() throws -> [AgentSession] {
        guard binaryPath != nil else { return [] }
        let entries = store.currentEntries(staleGrace: staleGrace)
        let recency = Date().timeIntervalSince1970
        return entries.map { entry in
            AgentSession(
                sourceKind: .claudeHerdr,
                sessionID: entry.sessionID,
                cwd: URL(fileURLWithPath: entry.cwd.isEmpty ? "/" : entry.cwd).standardizedFileURL.path,
                rowHints: RowGroupingHints(codexProjectID: nil, herdrWorkspaceID: entry.workspaceID),
                recency: recency,
                rowRank: Self.rowRank(forWorkspaceNumber: entry.workspaceNumber),
                columnRank: entry.paneNumber.map { $0 - 1 },
                seedStatus: entry.seedStatus,
                navigation: .herdrPane(paneID: entry.paneID)
            )
        }
    }

    /// Negative-encoded absolute row rank: `UnifiedLayout.assignSlots`
    /// treats an explicit rank as a literal slot only when it falls in
    /// `0..<capacity`; a negative value can therefore never collide with (or
    /// steal) one of Codex's already-resolved absolute row slots (which are
    /// always `>= 0`). It still participates in the slot-assignment sort
    /// ahead of every unranked (`nil`) row, and ahead of any other explicit
    /// non-negative rank, so herdr rows are packed into the lowest *free*
    /// rows first, in ascending workspace-`number` order -- realizing row
    /// ordering rule (1) from the design ("herdr rows first, by workspace
    /// number") without requiring changes to `UnifiedLayout`'s core
    /// absolute-slot algorithm or touching the Codex-only golden test.
    static func rowRank(forWorkspaceNumber number: Int) -> Int {
        -1_000_000 + number
    }

    static func seedStatus(forHerdrStatus agentStatus: String) -> AgentStatus {
        switch agentStatus {
        case "working": .working
        case "blocked": .approval
        case "done": .done
        case "idle", "unknown": .idle
        default: .idle
        }
    }

    /// Extracts the trailing pane number from a `"<workspace>:p<N>"` pane id
    /// (e.g. `"w9:p1"` -> `1`). Returns `nil` on any unexpected format so a
    /// caller can fall back to recency-based column ordering.
    static func parsePaneNumber(_ paneID: String) -> Int? {
        guard let paneComponent = paneID.split(separator: ":").last,
              paneComponent.hasPrefix("p") else { return nil }
        return Int(paneComponent.dropFirst())
    }

    /// Pure function combining one `agent list` + `workspace list` response
    /// pair into session entries. Only `agent == "claude"` entries are kept;
    /// agents whose workspace id has no matching workspace-list entry are
    /// dropped (can't determine row order for them).
    static func buildSessionEntries(
        agents: [HerdrAgentEntry],
        workspaces: [HerdrWorkspaceEntry]
    ) -> [SessionEntry] {
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceID, $0) })
        return agents.compactMap { agent -> SessionEntry? in
            guard agent.agent == "claude" else { return nil }
            guard let workspace = workspaceByID[agent.workspaceID] else { return nil }
            return SessionEntry(
                sessionID: agent.agentSession.value,
                cwd: agent.cwd ?? "",
                workspaceID: agent.workspaceID,
                workspaceNumber: workspace.number,
                paneID: agent.paneID,
                paneNumber: parsePaneNumber(agent.paneID),
                seedStatus: seedStatus(forHerdrStatus: agent.agentStatus)
            )
        }
    }

    /// One synchronous `agent list` + `workspace list` round trip. Used both
    /// by the background refresh loop and by `c100-status catalog` (a
    /// one-shot CLI display, where spinning up the polling thread would be
    /// pointless).
    static func fetchOnce(binary: String, timeout: TimeInterval = 2) throws -> [SessionEntry] {
        let agentData = try HerdrProcessRunner.run(binary: binary, arguments: ["agent", "list"], timeout: timeout)
        let workspaceData = try HerdrProcessRunner.run(binary: binary, arguments: ["workspace", "list"], timeout: timeout)
        let agents = try JSONDecoder().decode(HerdrAgentListResponse.self, from: agentData).result.agents
        let workspaces = try JSONDecoder().decode(HerdrWorkspaceListResponse.self, from: workspaceData).result.workspaces
        return buildSessionEntries(agents: agents, workspaces: workspaces)
    }

    private func startBackgroundRefresh() {
        let thread = Thread { [weak self] in
            while let self {
                self.refreshOnce()
                Thread.sleep(forTimeInterval: self.refreshInterval)
            }
        }
        thread.name = "herdr-catalog-refresh"
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func refreshOnce() {
        guard let binaryPath else { return }
        do {
            let entries = try Self.fetchOnce(binary: binaryPath, timeout: processTimeout)
            store.recordSuccess(entries)
        } catch {
            log(.warning, "herdr sync failed error=\(error)")
        }
    }
}
