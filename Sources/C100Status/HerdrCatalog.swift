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
        if let explicitPath {
            return fileManager.isExecutableFile(atPath: explicitPath) ? explicitPath : nil
        }
        if let envPath = environment["HERDR_BIN"], fileManager.isExecutableFile(atPath: envPath) {
            return envPath
        }
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/herdr" }
        return (searchPath + pathCandidates).first { fileManager.isExecutableFile(atPath: $0) }
    }
}

/// Drains one end of a `Pipe` on a background thread while its writer
/// (a child process's stdout/stderr) may still be running.
///
/// Both `HerdrProcessRunner` and `OsascriptRunner` used to wait for the
/// child to exit (via `isRunning` polling) *before* calling
/// `readDataToEndOfFile()`. That deadlocks whenever the child's combined
/// stdout+stderr exceeds the pipe's buffer: macOS shrinks a newly-created
/// pipe's buffer to as little as 512 bytes when the system-wide pipe count
/// is high, so a child emitting a few KB (e.g. `herdr workspace list`'s
/// ~1.3KB JSON) blocks forever in `write(2)` with nobody reading the other
/// end, and the wall-clock timeout fires even though the child would have
/// finished instantly. `PipeDrainer` starts reading immediately after
/// `process.run()`, in parallel with the `isRunning` deadline poll, so the
/// child's writes are always drained and it can actually finish.
///
/// `finish()` blocks until the read end sees EOF -- i.e. until every writer
/// of the pipe's write end has closed it, which happens either when the
/// child exits normally or after the caller calls `terminate()` on the
/// timeout path. Callers must call `finish()` (directly or via `start()`
/// having already run) before closing the pipe's read-end fd themselves,
/// otherwise the drain thread's `readDataToEndOfFile()` would spin against
/// a closed fd.
final class PipeDrainer: @unchecked Sendable {
    private let pipe: Pipe
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var buffer = Data()

    init(pipe: Pipe) {
        self.pipe = pipe
    }

    /// Begins draining on a background queue. Call once, immediately after
    /// the owning process has been started.
    func start() {
        group.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = handle.readDataToEndOfFile()
            if let self {
                self.lock.lock()
                self.buffer = data
                self.lock.unlock()
            }
            self?.group.leave()
        }
    }

    /// Blocks until the read end has hit EOF and returns everything read.
    /// Safe to call more than once; subsequent calls return the same data.
    func finish() -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return buffer
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
        defer {
            // `Process` closes its own copies of the pipes' write ends once
            // the child has been spawned, but the read ends belong to us and
            // are never closed by Foundation. Left open, every call here
            // (fired every 2s by the background sync loop) leaked two PIPE
            // fds -- this is what exhausted the daemon's fd table after
            // ~20 minutes. `close()` is safe to call even along the timeout
            // path where the handles were never read from.
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        // Drain stdout/stderr concurrently with the child's execution (see
        // `PipeDrainer`'s doc comment) -- otherwise a child whose combined
        // output exceeds the pipe buffer deadlocks against our own
        // isRunning-polling deadline below.
        let stdoutDrainer = PipeDrainer(pipe: stdout)
        let stderrDrainer = PipeDrainer(pipe: stderr)
        try process.run()
        stdoutDrainer.start()
        stderrDrainer.start()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            // terminate() + waitUntilExit() closes the child's write ends,
            // which is what lets the drain threads' readDataToEndOfFile()
            // see EOF and return -- must happen before the `defer` above
            // closes our read-end fds.
            _ = stdoutDrainer.finish()
            _ = stderrDrainer.finish()
            throw RunError.timedOut(command: arguments.joined(separator: " "), seconds: timeout)
        }
        process.waitUntilExit()
        let data = stdoutDrainer.finish()
        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: stderrDrainer.finish(), as: UTF8.self)
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

/// `pane list` response. Superset of `agent list` (adds `tab_id`, which
/// `agent list` doesn't expose), so `HerdrCatalog.fetchOnce` uses this in
/// place of `agent list` to get the pane->tab mapping needed for column
/// ordering without an extra process call.
struct HerdrPaneListResponse: Decodable {
    struct ResultPayload: Decodable {
        let panes: [HerdrPaneEntry]
    }

    let result: ResultPayload
}

struct HerdrPaneEntry: Decodable {
    struct Session: Decodable {
        let value: String
    }

    /// `nil` for a plain shell pane with no recognized agent.
    let agent: String?
    let agentSession: Session?
    let agentStatus: String?
    let cwd: String?
    let paneID: String
    let tabID: String
    let workspaceID: String

    enum CodingKeys: String, CodingKey {
        case agent
        case agentSession = "agent_session"
        case agentStatus = "agent_status"
        case cwd
        case paneID = "pane_id"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
    }
}

/// `tab list` response: gives each tab's on-screen display `number` (the
/// basis for column ordering across tabs) and `pane_count` (used to decide
/// whether a `pane layout` call is worth making for that tab).
struct HerdrTabListResponse: Decodable {
    struct ResultPayload: Decodable {
        let tabs: [HerdrTabEntry]
    }

    let result: ResultPayload
}

struct HerdrTabEntry: Decodable {
    let tabID: String
    let number: Int
    let workspaceID: String
    let paneCount: Int

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case number
        case workspaceID = "workspace_id"
        case paneCount = "pane_count"
    }
}

/// `pane layout --pane <id>` response: rects for every pane in that pane's
/// tab (so one call per multi-pane tab is enough to place all its panes).
struct HerdrPaneLayoutResponse: Decodable {
    struct ResultPayload: Decodable {
        let layout: Layout
    }

    struct Layout: Decodable {
        let tabID: String
        let panes: [LayoutPane]

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case panes
        }
    }

    struct LayoutPane: Decodable {
        let paneID: String
        let rect: Rect

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case rect
        }
    }

    struct Rect: Decodable {
        let x: Int
        let y: Int
    }

    let result: ResultPayload
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

/// herdr-backed `SessionSourceProvider` (M2): polls `herdr pane list` /
/// `herdr workspace list` / `herdr tab list` (plus `herdr pane layout` for
/// any multi-pane tab) on a dedicated background thread every 2 seconds and
/// exposes the result via a lock-protected snapshot so `snapshot()` --
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
        /// 0-based ordinal among this workspace's Claude sessions, packed by
        /// on-screen order (tab number, then pane rect y/x, then pane number
        /// as a last-resort tiebreak) -- see `columnRanks(for:)`. `nil` only
        /// if the pane couldn't be placed at all (shouldn't happen in
        /// practice since `parsePaneNumber` covers the final fallback).
        let columnRank: Int?
        let seedStatus: AgentStatus
    }

    private let enabledLock = NSLock()
    private var pollingEnabled: Bool
    func setEnabled(_ enabled: Bool) { enabledLock.lock(); pollingEnabled = enabled; enabledLock.unlock() }
    private var isEnabled: Bool { enabledLock.lock(); defer { enabledLock.unlock() }; return pollingEnabled }
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
        enabled: Bool = true,
        refreshInterval: TimeInterval = 2,
        staleGrace: TimeInterval = 15,
        processTimeout: TimeInterval = 2,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping (StatusLogger.Level, String) -> Void = { _, _ in }
    ) {
        self.pollingEnabled = enabled
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
        guard isEnabled, binaryPath != nil else { return [] }
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
                columnRank: entry.columnRank,
                seedStatus: entry.seedStatus,
                navigation: .herdrPane(paneID: entry.paneID)
            )
        }
    }

    /// Absolute row slot for a herdr workspace: herdr's `workspace list`
    /// `number` is the UI's own 1..N display position (renumbered on
    /// reorder), so `number - 1` is exactly the 0-based row a user sees that
    /// workspace occupy in the terminal. Returning it as a literal slot (see
    /// `UnifiedLayout.assignSlots`'s `0..<capacity` in-range check) means a
    /// workspace's row is reserved the moment it exists, even before it has
    /// any Claude session -- mirroring `CodexCatalog.orderedLayout`, which
    /// reserves sidebar-project rows the same way. A workspace whose number
    /// falls outside `0..<capacity` (more workspaces than grid rows) simply
    /// has no in-range claim, so `assignSlots` falls back to packing it into
    /// whatever free row remains -- the same fallback Codex relies on via
    /// `namedRowLimit`.
    static func rowRank(forWorkspaceNumber number: Int) -> Int {
        number - 1
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

    /// The subset of a claude pane's fields needed to decide its on-screen
    /// column order within its workspace. `rectX`/`rectY` are only known for
    /// panes whose tab's `pane layout` call succeeded (or wasn't needed
    /// because the tab has a single pane); `tabNumber` is `nil` only if the
    /// pane's `tab_id` had no matching `tab list` entry.
    struct PaneOrderingInfo: Equatable {
        let paneID: String
        let workspaceID: String
        let tabNumber: Int?
        let rectX: Int?
        let rectY: Int?
        let paneNumber: Int?
    }

    /// Sort key implementing the spec order: tab display number ascending,
    /// then pane rect y ascending (top before bottom), then rect x
    /// ascending (left before right), then -- for ties or missing data --
    /// pane number ascending, then pane id as a final deterministic
    /// tiebreak. Any missing component sorts last within its own tier via
    /// `Int.max`, so a pane with no layout/tab data still participates
    /// (falling all the way back to pane-number order) rather than being
    /// dropped.
    private static func paneOrderingKey(_ pane: PaneOrderingInfo) -> (Int, Int, Int, Int, String) {
        (
            pane.tabNumber ?? Int.max,
            pane.rectY ?? Int.max,
            pane.rectX ?? Int.max,
            pane.paneNumber ?? Int.max,
            pane.paneID
        )
    }

    /// Packs each workspace's claude panes into a dense `0..<n` column
    /// ordinal, ordered by `paneOrderingKey`. Grouping by `workspaceID`
    /// before packing is what closes gaps from closed panes (herdr never
    /// renumbers panes) without letting one workspace's pane count affect
    /// another's column assignment.
    static func columnRanks(for panes: [PaneOrderingInfo]) -> [String: Int] {
        var result: [String: Int] = [:]
        let grouped = Dictionary(grouping: panes, by: \.workspaceID)
        for group in grouped.values {
            let ordered = group.sorted { paneOrderingKey($0) < paneOrderingKey($1) }
            for (index, pane) in ordered.enumerated() {
                result[pane.paneID] = index
            }
        }
        return result
    }

    /// Pure function combining one `pane list` + `workspace list` + `tab
    /// list` response set (plus whatever `pane layout` rects were
    /// successfully fetched) into session entries. Only `agent == "claude"`
    /// panes are kept; panes whose workspace id has no matching
    /// workspace-list entry are dropped (can't determine row order for
    /// them). `layoutByPaneID` maps pane id -> rect `(x, y)` and is expected
    /// to be a partial map: any tab whose `pane layout` call failed or
    /// wasn't attempted simply has no entries for its panes, which
    /// `paneOrderingKey` gracefully falls back from.
    static func buildSessionEntries(
        panes: [HerdrPaneEntry],
        workspaces: [HerdrWorkspaceEntry],
        tabs: [HerdrTabEntry],
        layoutByPaneID: [String: (x: Int, y: Int)] = [:]
    ) -> [SessionEntry] {
        let workspaceByID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceID, $0) })
        let tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabID, $0) })
        let claudePanes = panes.filter { $0.agent == "claude" }

        let orderingInfos = claudePanes.map { pane in
            PaneOrderingInfo(
                paneID: pane.paneID,
                workspaceID: pane.workspaceID,
                tabNumber: tabByID[pane.tabID]?.number,
                rectX: layoutByPaneID[pane.paneID]?.x,
                rectY: layoutByPaneID[pane.paneID]?.y,
                paneNumber: parsePaneNumber(pane.paneID)
            )
        }
        let columnRanks = Self.columnRanks(for: orderingInfos)

        return claudePanes.compactMap { pane -> SessionEntry? in
            guard let session = pane.agentSession else { return nil }
            guard let workspace = workspaceByID[pane.workspaceID] else { return nil }
            return SessionEntry(
                sessionID: session.value,
                cwd: pane.cwd ?? "",
                workspaceID: pane.workspaceID,
                workspaceNumber: workspace.number,
                paneID: pane.paneID,
                paneNumber: parsePaneNumber(pane.paneID),
                columnRank: columnRanks[pane.paneID],
                seedStatus: seedStatus(forHerdrStatus: pane.agentStatus ?? "unknown")
            )
        }
    }

    /// One synchronous `workspace list` + `pane list` + `tab list` round
    /// trip, plus one `pane layout` call per multi-pane tab that contains a
    /// claude pane (single-pane tabs need no rect: their order is already
    /// fully determined by tab number). Used both by the background refresh
    /// loop and by `c100-status catalog` (a one-shot CLI display, where
    /// spinning up the polling thread would be pointless).
    ///
    /// A `pane layout` failure for one tab is logged and skipped rather than
    /// failing the whole fetch: `buildSessionEntries` falls back to pane-
    /// number order for just that tab's panes via the `Int.max` fallback in
    /// `paneOrderingKey`.
    static func fetchOnce(
        binary: String,
        timeout: TimeInterval = 2,
        log: (StatusLogger.Level, String) -> Void = { _, _ in }
    ) throws -> [SessionEntry] {
        let workspaceData = try HerdrProcessRunner.run(binary: binary, arguments: ["workspace", "list"], timeout: timeout)
        let paneData = try HerdrProcessRunner.run(binary: binary, arguments: ["pane", "list"], timeout: timeout)
        let tabData = try HerdrProcessRunner.run(binary: binary, arguments: ["tab", "list"], timeout: timeout)
        let workspaces = try JSONDecoder().decode(HerdrWorkspaceListResponse.self, from: workspaceData).result.workspaces
        let panes = try JSONDecoder().decode(HerdrPaneListResponse.self, from: paneData).result.panes
        let tabs = try JSONDecoder().decode(HerdrTabListResponse.self, from: tabData).result.tabs

        let tabByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.tabID, $0) })
        let claudePanes = panes.filter { $0.agent == "claude" }
        // One representative pane per multi-pane tab is enough: `pane
        // layout --pane <id>` returns rects for every pane in that pane's
        // tab, not just the one asked about.
        var representativePaneIDByTab: [String: String] = [:]
        for pane in claudePanes {
            guard let tab = tabByID[pane.tabID], tab.paneCount >= 2 else { continue }
            if representativePaneIDByTab[pane.tabID] == nil {
                representativePaneIDByTab[pane.tabID] = pane.paneID
            }
        }

        var layoutByPaneID: [String: (x: Int, y: Int)] = [:]
        for (tabID, representativePaneID) in representativePaneIDByTab {
            do {
                let layoutData = try HerdrProcessRunner.run(
                    binary: binary,
                    arguments: ["pane", "layout", "--pane", representativePaneID],
                    timeout: timeout
                )
                let layout = try JSONDecoder().decode(HerdrPaneLayoutResponse.self, from: layoutData).result.layout
                for layoutPane in layout.panes {
                    layoutByPaneID[layoutPane.paneID] = (x: layoutPane.rect.x, y: layoutPane.rect.y)
                }
            } catch {
                log(.warning, "herdr pane layout failed tab=\(tabID) pane=\(representativePaneID) error=\(error) -- falling back to pane-number order for that tab")
            }
        }

        return buildSessionEntries(panes: panes, workspaces: workspaces, tabs: tabs, layoutByPaneID: layoutByPaneID)
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
        guard isEnabled, let binaryPath else { return }
        do {
            let entries = try Self.fetchOnce(binary: binaryPath, timeout: processTimeout, log: log)
            store.recordSuccess(entries)
        } catch {
            log(.warning, "herdr sync failed error=\(error)")
        }
    }
}
