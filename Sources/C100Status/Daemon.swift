import AppKit
import Darwin
import Foundation

nonisolated(unsafe) private var daemonStopRequested: sig_atomic_t = 0

private func requestDaemonStop(_: Int32) {
    daemonStopRequested = 1
}

final class StatusDaemon {
    private var keyboardLayout: KeyboardLayout
    private let layoutStore: LayoutStore
    private var actionError: String?
    private let socketPath: String
    private let locationID: Int?
    private let dryRun: Bool
    private let codexPaths: CodexPaths
    private let configuredServices: [SessionSourceKind]?
    private var enabledSources: Set<SessionSourceKind> {
        if let configuredServices { return Set(configuredServices) }
        let legacy = keyboardLayout.enabledSources
        return legacy.isEmpty ? [defaultLayer] : legacy
    }
    private let defaultLayer: SessionSourceKind
    private let claudeDesktopConfigDir: String
    private let logger: StatusLogger
    private let stateStore = StateStore()
    private var viewports: [SessionSourceKind: GridViewport] = [:]
    private var virtualProjects: [SessionSourceKind: [String: Int]] = [:]
    private var brightnessPercent = 100
    private var connection: C100Connection?
    private var pressedKeyIndexes: Set<Int> = []
    private var arrowKeyRepeat = ArrowKeyRepeat()
    private var nextCatalogSync = Date.distantPast
    private var catalogProjectBySession: [String: String] = [:]
    private var catalogSessionIDs: Set<String> = []
    /// Sticky feedback for `UnifiedLayout.compute`, kept *per layer* (M5):
    /// each `SessionSourceKind` gets its own independent `compute()` call
    /// (9-row cap, no cross-layer row merging), so its sticky-placement
    /// feedback must also be kept independent -- otherwise switching layers
    /// would mix one layer's previous-slot history into another's and
    /// placements would churn on every switch. Within a layer this is the
    /// same mechanism as pre-M5: the previous sync's placements, so a
    /// repeating rank conflict resolves the same way (and a session that
    /// lost one keeps its fallback slot) every time instead of churning when
    /// a source's `recency` value moves or the session set briefly flickers
    /// -- see `UnifiedLayout.compute`'s doc comment.
    private var previousUnifiedPlacements: [SessionSourceKind: [String: UnifiedLayout.PreviousSlot]] = [:]
    /// M5: which of the 4 `SessionSourceKind` layers is currently displayed
    /// on keys 0-79. Loaded from `layerStore` at startup (defaults to
    /// `.claudeHerdr`) and persisted every time it changes so a daemon
    /// restart resumes on the same layer.
    private var hardwareActionProcess: pid_t?
    private var activeLayer: SessionSourceKind = LayerSelectionStore.defaultLayer
    private let layerStore = LayerSelectionStore()
    /// Colors last written to the 4 layer keys (90-93), so the ~600ms blink
    /// timer only issues a single-key HID write when a key's color actually
    /// changed instead of re-sending all 4 every tick.
    private var lastPaintedLayerColors: [Int: HSVColor] = [:]
    /// The `colorsByIndex` map (assigned keys only, keys 0-93) that this
    /// connection last actually painted onto the board, so `reconcileLEDs`
    /// can send an incremental `C100Connection.update` instead of a
    /// full-frame `apply` that blacks out the whole grid for ~50ms first.
    /// `nil` means the board's real state is unknown (never painted since
    /// this connection was established, or a paint might have partially
    /// failed) and the next `reconcileLEDs` must fall back to a full frame.
    /// Every place that can leave the board in a state this daemon didn't
    /// just write -- a fresh/reconnected `connection`, `.clear`, or an HID
    /// write failure that discards `connection` -- resets this to `nil`.
    private var lastPaintedFrame: [Int: HSVColor]?
    /// Toggled every ~600ms by the main loop; flips which of (attention
    /// status color / layer base color) a blinking layer key currently
    /// shows -- see `LayerKeyColorLogic.color`.
    private var layerBlinkPhaseOn = false
    private var nextLayerBlinkToggle = Date.distantPast
    private let layerBlinkInterval: TimeInterval = 0.6
    /// Last sync's `UnifiedLayout` warning strings, so `syncCatalog` only
    /// logs a `catalog layout warning=` line when the set of active
    /// conflicts actually changes, not every 2s sync a still-unresolved one
    /// persists.
    private var previousCatalogWarnings: Set<String> = []
    private var deferredHooks = DeferredHookBuffer()
    private let deferredHookMaxAge: TimeInterval = 6
    private var pendingApprovals = PendingApprovalBuffer()
    private let approvalDisplayDelay: TimeInterval = 0.5
    private let turnMonitor = CodexTurnMonitor()
    private lazy var navigator = CodexNavigator { [weak self] level, message in
        self?.logger.log(level, message)
    }
    private lazy var navigationRouter = NavigationRouter(codexNavigator: navigator, herdrBinaryPath: HerdrBinaryResolver.resolve(explicitPath: herdrBinaryPath)) { [weak self] level, message in
        self?.logger.log(level, message)
    }
    private let herdrBinaryPath: String?
    private let herdrRowGrouping: HerdrRowGrouping
    private lazy var herdrCatalog = HerdrCatalog(herdrBinaryPath: herdrBinaryPath, enabled: enabledSources.contains(.claudeHerdr), grouping: herdrRowGrouping) { [weak self] level, message in
        self?.logger.log(level, message)
    }
    private let claudeConfigDirs: [String]
    private lazy var claudeSessionsCatalog = ClaudeSessionsCatalog(
        configDirs: claudeConfigDirs,
        log: { [weak self] level, message in self?.logger.log(level, message) }
    )
    private let claudeDesktopDir: String
    private lazy var claudeDesktopCatalog = ClaudeDesktopCatalog(
        desktopSessionsDir: claudeDesktopDir,
        configDir: claudeDesktopConfigDir,
        isHookRegistered: { [weak self] sessionID in self?.claudeSessions[sessionID]?.sourceKind == .claudeDesktop },
        log: { [weak self] level, message in self?.logger.log(level, message) }
    )
    private lazy var providers: [SessionSourceProvider] = [
        CodexSourceProvider(paths: codexPaths, unbounded: true), herdrCatalog, claudeSessionsCatalog, claudeDesktopCatalog,
    ]
    /// Claude is hook-authoritative (M1): the daemon itself remembers every
    /// session a Claude hook has told it about -- cwd/source for
    /// `UnifiedLayout` grouping, and where a key-press on it should
    /// navigate. Entries are added on any non-`SessionEnd` Claude hook and
    /// removed on `SessionEnd` (see `handleClaudeHook`). `ClaudeSessionsCatalog`
    /// (M3) supplements this with an on-disk scan used purely for startup
    /// seeding and crash GC -- see `syncCatalog`'s claude-terminal GC step
    /// and `applyClaudeTranscriptStaleGC` below.
    private struct ClaudeSessionRecord {
        let sourceKind: SessionSourceKind
        let cwd: String
        let herdrWorkspaceID: String?
        let navigation: NavigationTarget
        /// `hook.configDir`, defaulted to `~/.claude` -- needed to locate
        /// this session's transcript jsonl for the cross-source stale GC.
        let configDir: String
        var lastSeen: Date
        /// The status the session's own hooks last mapped to (M6), *before*
        /// any `activeSubagents` override. `StateStore` always holds the
        /// *displayed* status (raw or overridden), so this is the only place
        /// the raw value survives while an override is in effect --
        /// `refreshSubagentOverride` reads it back once the session's last
        /// subagent stops. Defaults to `.idle`, matching `SessionStart`'s
        /// mapping, for a session first seen via a hook this field predates
        /// (shouldn't happen in practice: `SessionStart` is always first).
        var rawStatus: AgentStatus = .idle
    }
    private var claudeSessions: [String: ClaudeSessionRecord] = [:]
    /// M6: which Claude sessions currently have a subagent running --
    /// `ActiveSubagentTracker.isActive(sessionID:)` is the sole signal that
    /// a session's displayed status should be overridden to `.working`
    /// regardless of what its own hooks most recently reported -- see
    /// `refreshSubagentOverride`. Entries are removed on a matching
    /// `SubagentStop`, TTL sweep (`pruneActiveSubagents`), on-disk
    /// staleness sweep (`applyActiveSubagentStaleSweep`), or whenever the
    /// session itself is torn down (`SessionEnd`, any of the cross-source
    /// GCs, `ActiveSubagentTracker.clear`).
    private var activeSubagents = ActiveSubagentTracker()
    /// Take-over-if-lost safety net (M6 spec): even if a `SubagentStop`
    /// never arrives (crashed subagent process, dropped async hook, ...) an
    /// entry is force-cleared after this long so a stuck `SubagentStart`
    /// can't pin a session at `.working` forever.
    private let activeSubagentTTL: TimeInterval = 7_200
    /// Second take-over-if-lost check, applied only at `syncCatalog` time
    /// (too expensive to stat a directory on every hook call): if every
    /// `agent-*.jsonl` under the session's on-disk `subagents/` directory
    /// has gone untouched this long, the tracked subagents are presumed
    /// dead and cleared outright, well before the 2h TTL would catch up --
    /// see `applyActiveSubagentStaleSweep`.
    private let activeSubagentStaleAfter: TimeInterval = 1_800
    /// `SessionEnd` tombstones, so a Claude hook re-delivery or reordering
    /// (e.g. an async PostToolUse hook that lands after SessionEnd) doesn't
    /// resurrect an already-ended session. Pruned after `claudeSessionEndTombstoneTTL`.
    private var endedClaudeSessions = ClaudeSessionEndTombstoneBuffer()
    private let claudeSessionEndTombstoneTTL: TimeInterval = 60
    /// A hook-registered Claude session (any source) whose transcript jsonl
    /// hasn't been touched in this long is presumed abandoned (crashed
    /// process, killed terminal that never delivered `SessionEnd`, ...) and
    /// is GC'd -- see `applyClaudeTranscriptStaleGC`.
    private let claudeTranscriptStaleAfter: TimeInterval = 1_800
    /// herdr session IDs present in the *previous* sync's herdr snapshot, so
    /// a session that vanishes (pane closed/killed) can be told apart from
    /// one that was never there -- and torn down explicitly (M2) rather than
    /// silently falling back to a stale hook-registered placement.
    private var previousHerdrSessionIDs: Set<String> = []
    /// claude-terminal session IDs present in the *previous* sync's
    /// `ClaudeSessionsCatalog` scan (M3), mirroring `previousHerdrSessionIDs`:
    /// a hook-registered claude-terminal session whose `sessions/<pid>.json`
    /// disappears (process died/was killed without ever sending
    /// `SessionEnd`) is torn down the same way a closed herdr pane is.
    private var previousClaudeTerminalSessionIDs: Set<String> = []
    /// claude-desktop session IDs present in the *previous* sync's
    /// `ClaudeDesktopCatalog` scan (M4), mirroring
    /// `previousClaudeTerminalSessionIDs`: a hook-registered claude-desktop
    /// session that disappears from the scan (archived, aged out past the
    /// 6-hour liveness window with no hook keeping it alive, or Desktop
    /// itself quit) without ever sending `SessionEnd` is torn down the same
    /// way.
    private var previousClaudeDesktopSessionIDs: Set<String> = []
    /// Resolved navigation target for every session currently reported by
    /// herdr, so a key-press on a herdr session the daemon hasn't received
    /// any Claude hook for yet still navigates correctly.
    private var herdrNavigationBySession: [String: NavigationTarget] = [:]
    /// Bug fix (M5.1): resolved `NavigationTarget` for *every* session
    /// currently placed on any layer's grid, regardless of source --
    /// rebuilt each `syncCatalog` from that sync's `UnifiedLayout.compute`
    /// placements (`AgentSession.navigation`, which every provider already
    /// resolves correctly: `ClaudeSessionsCatalog` -> `.ghosttyTab`,
    /// `ClaudeDesktopCatalog` -> `.claudeDesktop`, herdr -> `.herdrPane`,
    /// Codex -> `.codexThread`). `handleKeyPress` falls back to this map
    /// when neither the hook-derived `claudeSessions` record nor
    /// `herdrNavigationBySession` has an entry, so a claude-terminal or
    /// claude-desktop session the daemon only ever learned about via a file
    /// scan (never received a hook for) still navigates to the *right* app
    /// instead of falling through to `.codexThread` and opening Codex
    /// Desktop by mistake.
    private var sessionNavigationBySession: [String: NavigationTarget] = [:]
    /// Consecutive-sync streak of a herdr-reported idle/done status per
    /// session, used for hook-miss recovery (see `applyHerdrStatusHeuristics`).
    private var herdrStatusStreaks: [String: (status: AgentStatus, count: Int, since: Date)] = [:]

    init(
        socketPath: String,
        logURL: URL,
        locationID: Int?,
        dryRun: Bool,
        herdrBinaryPath: String? = nil,
        herdrRowGrouping: HerdrRowGrouping = .workspace,
        claudeConfigDirs: [String]? = nil,
        claudeDesktopDir: String? = nil,
        claudeDesktopConfigDir: String? = nil,
        codexPaths: CodexPaths = CodexPaths(),
        defaultLayer: SessionSourceKind = .codex,
        enabledServices: [SessionSourceKind]? = nil,
        layoutPath: String = Configuration.defaultPath().replacingOccurrences(of: "config.json", with: "layout.json")
    ) throws {
        guard geteuid() != 0 else {
            throw CLIError.runtime(
                "Refusing to run the user daemon as root. Install the helper once with sudo, then run c100-status without sudo."
            )
        }
        self.layoutStore = LayoutStore(path: layoutPath)
        self.keyboardLayout = try self.layoutStore.load()
        self.socketPath = socketPath
        self.locationID = locationID
        self.dryRun = dryRun
        self.codexPaths = codexPaths
        self.defaultLayer = defaultLayer
        self.configuredServices = enabledServices
        self.claudeDesktopConfigDir = claudeDesktopConfigDir ?? NSHomeDirectory() + "/.claude"
        self.herdrBinaryPath = herdrBinaryPath
        self.herdrRowGrouping = herdrRowGrouping
        self.claudeConfigDirs = claudeConfigDirs ?? ClaudeConfigDirs.resolved(additional: [])
        self.claudeDesktopDir = claudeDesktopDir ?? ClaudeDesktopCatalog.defaultSessionsDir()
        logger = try StatusLogger(fileURL: logURL)
    }

    /// Every throwing exit from `runLoop()` -- including one that unwinds
    /// all the way out of `setupHardware()` before the log file even has a
    /// "daemon started" line -- otherwise leaves no trace anywhere: the
    /// LaunchAgent's stdout/stderr are `/dev/null` (see the plist), so the
    /// only way to know *why* the daemon exited is this file log. Log the
    /// error here (the outermost point that still has `logger` in scope)
    /// and rethrow unchanged so `main.swift`'s top-level catch keeps
    /// printing/exiting exactly as before.
    func run() throws {
        do {
            try runLoop()
        } catch {
            logger.log(.error, "daemon exiting error=\(error)")
            throw error
        }
    }

    private func runLoop() throws {
        defer { connection?.stopCompanion() }
        daemonStopRequested = 0
        Darwin.signal(SIGINT, requestDaemonStop)
        Darwin.signal(SIGTERM, requestDaemonStop)
        Darwin.signal(SIGPIPE, SIG_IGN)

        let instanceLock = try DaemonInstanceLock(socketPath: socketPath)
        _ = instanceLock
        logger.log(.info, "daemon initializing pid=\(getpid()) dry_run=\(dryRun) euid=\(geteuid())")
        if dryRun {
            logger.log(.info, "HID writes and input capture are disabled")
        } else {
            guard try setupHardware() else {
                logger.log(.info, "daemon stopping signal=received_during_hid_wait")
                return
            }
        }
        try stateStore.clear()
        try stateStore.discardLegacyEndedSessions()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: socketPath + ".display.json")),
           let value = try? JSONDecoder().decode(Int.self, from: data), (10...200).contains(value) { brightnessPercent = value }
        connection?.brightnessPercent = brightnessPercent
        activeLayer = layerStore.load(defaultLayer: defaultLayer)
        if !enabledSources.contains(activeLayer) { activeLayer = SessionSourceKind.allCases.first { enabledSources.contains($0) } ?? defaultLayer }
        logger.log(.info, "layer active=\(activeLayer.rawValue) source=restored_or_default")
        try applyAll(color: LEDColorName.off.color)
        // Bug fix (M5.1): force a fresh repack of every layer on this first
        // sync -- there is no placement history yet for any of them (a
        // fresh daemon start), so nothing is lost by ignoring
        // `previousUnifiedPlacements`, and this is what pulls a layer with a
        // single stray session (e.g. one left parked on row 4 by the old
        // pre-M5 unified-grid state) up to row 0 instead of restoring it
        // wherever `StateStore`'s on-disk state happened to remember it.
        syncCatalog(forceRepackSources: Set(SessionSourceKind.allCases))
        // Guarantee the layer bar (and whatever the first `syncCatalog` sync
        // placed) is on the keyboard even if that sync's `GridReconciliation`
        // happened to report no change (e.g. no sessions yet at all).
        try reconcileLEDs()
        nextLayerBlinkToggle = Date().addingTimeInterval(layerBlinkInterval)
        let server = try UnixSocketServer(path: socketPath)
        logger.log(
            .info,
            "daemon started pid=\(getpid()) uid=\(geteuid()) socket=\(socketPath) log=\(logger.fileURL.path)"
        )

        var previousLoopStartedAt = ProcessInfo.processInfo.systemUptime
        while daemonStopRequested == 0 {
            let loopStartedAt = ProcessInfo.processInfo.systemUptime
            let previousLoopDuration = loopStartedAt - previousLoopStartedAt
            if previousLoopDuration >= 0.750 {
                logger.log(
                    .warning,
                    "daemon loop delayed duration_ms=\(Int(previousLoopDuration * 1_000))"
                )
            }
            previousLoopStartedAt = loopStartedAt

            if !dryRun {
                try pollMatrix()
            }
            servicePendingApprovals()
            if Date() >= nextCatalogSync {
                syncCatalog()
            }
            if Date() >= nextLayerBlinkToggle {
                nextLayerBlinkToggle = Date().addingTimeInterval(layerBlinkInterval)
                updateLayerBlink()
            }
            guard let client = try server.accept(timeoutMilliseconds: 10) else { continue }
            autoreleasepool {
                defer { Darwin.close(client) }
                do {
                    let data = try UnixSocketServer.readRequest(from: client)
                    let request = try JSONDecoder().decode(DaemonRequest.self, from: data)
                    let response = handle(request)
                    try UnixSocketServer.write(response, to: client)
                } catch {
                    logger.log(.error, "request failed error=\(error)")
                    let response = DaemonResponse(ok: false, message: String(describing: error), status: nil)
                    try? UnixSocketServer.write(response, to: client)
                }
            }
        }
        logger.log(.info, "daemon stopping")
    }

    private func handle(_ request: DaemonRequest) -> DaemonResponse {
        do {
            switch request.kind {
            case .layout:
                if let layout = request.layout {
                    try layout.validate()
                    let bindings = CodexActionBindings(home: codexPaths.home)
                    try layoutStore.apply(layout, bindings: bindings, installCodex: enabledSources.contains(.codex))
                    try connection?.cancelKeyboardOutput()
                    hardwareActionProcess = nil
                    keyboardLayout = layout
                    herdrCatalog.setEnabled(enabledSources.contains(.claudeHerdr))
                    claudeSessions = claudeSessions.filter { enabledSources.contains($0.value.sourceKind) }
                    if !enabledSources.contains(.codex) { deferredHooks.removeAll(); pendingApprovals.removeAll() }
                    arrowKeyRepeat = ArrowKeyRepeat()
                    viewports.removeAll()
                    if !enabledSources.contains(activeLayer) {
                        activeLayer = SessionSourceKind.allCases.first { enabledSources.contains($0) } ?? defaultLayer
                        layerStore.save(activeLayer)
                    }
                    lastPaintedFrame = nil
                    lastPaintedLayerColors.removeAll()
                    syncCatalog(forceRepackSources: Set(SessionSourceKind.allCases))
                    try reconcileLEDs()
                }
                return DaemonResponse(ok: true, message: String(decoding: try keyboardLayout.json(), as: UTF8.self), status: nil)
            case .scroll:
                guard let direction = request.direction, ["up", "down", "left", "right"].contains(direction) else { throw CLIError.usage("Invalid scroll direction") }
                try scroll(direction)
                return DaemonResponse(ok: true, message: "viewport updated", status: nil)
            case .inspect:
                let visible = try visibleAssignments()
                let viewport = configuredViewport()
                let info: [String: Any] = ["connected": connection != nil, "backend": "companion", "layer": activeLayer.rawValue, "brightness": brightnessPercent,
                    "topRow": viewport.topRow, "leftColumn": viewport.leftColumn, "viewportRows": viewport.rowCount, "viewportColumns": viewport.columnCount,
                    "enabledSources": enabledSources.map(\.rawValue).sorted(), "actionError": actionError ?? "",
                    "actionTransport": connection?.supportsKeyboardOutput == true ? "keyboard-hid" : "accessibility",
                    "accessibilityTrusted": AXIsProcessTrusted(), "layoutPath": layoutStore.path,
                    "projectRows": virtualProjects[activeLayer] ?? [:],
                    "visible": visible.map { ["key": $0.key, "sessionID": $0.sessionID, "project": $0.slot.projectKey, "column": $0.slot.column, "status": $0.slot.status.rawValue] as [String: Any] }]
                let data = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
                return DaemonResponse(ok: true, message: String(decoding: data, as: UTF8.self), status: nil)
            case .layer:
                guard let layer = request.layer, enabledSources.contains(layer) else { throw CLIError.usage("Missing layer") }
                switchLayer(to: layer)
                return DaemonResponse(ok: true, message: "layer=\(activeLayer.rawValue)", status: nil)
            case .brightness:
                guard let value = request.brightness, (10...200).contains(value) else { throw CLIError.usage("Brightness must be 10...200 percent") }
                try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: socketPath + ".display.json"), options: .atomic)
                brightnessPercent = value
                connection?.brightnessPercent = value
                lastPaintedFrame = nil
                try reconcileLEDs()
                return DaemonResponse(ok: true, message: "brightness=\(value)", status: nil)
            case .ping:
                return DaemonResponse(ok: true, message: "daemon is running", status: nil)
            case .clear:
                try stateStore.clear()
                deferredHooks.removeAll()
                pendingApprovals.removeAll()
                activeSubagents.clearAll()
                try applyAll(color: LEDColorName.off.color)
                try reconcileLEDs()
                logger.log(.info, "state cleared keys=off")
                return DaemonResponse(ok: true, message: "state cleared", status: .idle)
            case .manual:
                guard let status = request.status else {
                    throw CLIError.runtime("manual request is missing status")
                }
                try applyAssigned(status: status)
                logger.log(.info, "manual status=\(status.rawValue)")
                return DaemonResponse(ok: true, message: "manual status applied", status: status)
            case .key:
                guard let index = request.keyIndex, let color = request.color else {
                    throw CLIError.runtime("key request is missing index or color")
                }
                try apply(color: color, at: index)
                logger.log(.info, "key index=\(index) hsv=\(color.hue),\(color.saturation),\(color.value)")
                return DaemonResponse(ok: true, message: "key color applied", status: nil)
            case .hook:
                guard let hook = request.hook else {
                    throw CLIError.runtime("hook request is missing hook data")
                }
                guard enabledSources.contains(hook.effectiveSource) else { return DaemonResponse(ok: true, message: "source disabled", status: nil) }
                return try handleHook(hook)
            }
        } catch {
            logger.log(.error, "operation failed error=\(error)")
            return DaemonResponse(ok: false, message: String(describing: error), status: nil)
        }
    }

    private func handleHook(_ hook: HookInput) throws -> DaemonResponse {
        guard hook.effectiveSource == .codex else {
            return try handleClaudeHook(hook)
        }
        let projectKey = resolvedProjectKey(for: hook)
        if hook.endsSession {
            pendingApprovals.cancel(sessionID: hook.sessionID)
        }
        if hook.endsSession, !catalogSessionIDs.contains(hook.sessionID) {
            deferredHooks.remove(sessionID: hook.sessionID)
            logger.log(
                .debug,
                "hook event=SessionEnd session=\(shortSession(hook.sessionID)) action=ignored_not_in_catalog\(hookDiagnosticContext(hook))"
            )
            return DaemonResponse(ok: true, message: "unknown session end ignored", status: nil)
        }

        guard var status = hook.status else {
            logger.log(.debug, "hook ignored event=\(hook.hookEventName) session=\(shortSession(hook.sessionID))")
            return DaemonResponse(ok: true, message: "hook ignored", status: nil)
        }
        guard catalogSessionIDs.contains(hook.sessionID) else {
            deferredHooks.record(hook, status: status)
            logger.log(
                .info,
                "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) status=\(status.rawValue) action=deferred_not_in_catalog\(hookDiagnosticContext(hook))"
            )
            return DaemonResponse(ok: true, message: "hook deferred pending Codex catalog", status: nil)
        }
        deferredHooks.remove(sessionID: hook.sessionID)
        if hook.requestsPermission {
            switch CodexApprovalRouting.displayRoute(for: hook, paths: codexPaths) {
            case let .user(reason):
                pendingApprovals.record(hook)
                logger.log(
                    .info,
                    "hook event=PermissionRequest session=\(shortSession(hook.sessionID)) status=approval action=debounced route=user reason=\(reason) delay_ms=\(Int(approvalDisplayDelay * 1_000))\(hookDiagnosticContext(hook))"
                )
                return DaemonResponse(ok: true, message: "user approval display deferred", status: nil)
            case let .automatic(reviewer):
                status = .working
                logger.log(
                    .info,
                    "hook event=PermissionRequest session=\(shortSession(hook.sessionID)) status=working action=keep_working route=automatic reviewer=\(reviewer ?? "unknown")\(hookDiagnosticContext(hook))"
                )
            }
        }
        let cancelledApproval = pendingApprovals.cancel(sessionID: hook.sessionID) != nil
        let mutation = try stateStore.update(
            sessionID: hook.sessionID,
            projectKey: projectKey,
            source: .codex,
            status: status
        )
        guard let slot = mutation.slot else {
            throw CLIError.runtime("Hook session was not assigned a C100 key")
        }
        logger.log(
            .info,
            "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=\(slot.status.rawValue) changed=\(mutation.changed)\(cancelledApproval ? " approval=resolved_before_display" : "")"
        )
        if mutation.changed {
            try applyLayerAwareUpdate(source: .codex, mutation: mutation, slot: slot)
        }
        return DaemonResponse(ok: true, message: "hook accepted on key \(slot.keyIndex)", status: slot.status)
    }

    /// Claude hook path (M1): hook-authoritative, so a session is registered
    /// on its first non-`SessionEnd` hook rather than waiting on a catalog
    /// scan (there is no catalog yet for Claude sources). Codex's approval
    /// rollout routing (`CodexApprovalRouting`) is intentionally never
    /// consulted here -- every Claude approval routes straight to the user
    /// with the same 0.5s debounce Codex uses.
    private func handleClaudeHook(_ hook: HookInput) throws -> DaemonResponse {
        pruneEndedClaudeSessions()
        pruneActiveSubagents()

        // M6: handled before the `isSubagent` check even though `isSubagent`
        // already carves these two events out -- keeping the branch here
        // too makes the control flow self-evident without having to recall
        // `HookInput.isSubagent`'s carve-out.
        if hook.isSubagentLifecycleEvent {
            return try handleSubagentLifecycle(hook)
        }

        if hook.isSubagent {
            logger.log(
                .debug,
                "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue) action=ignored_subagent\(hookDiagnosticContext(hook))"
            )
            return DaemonResponse(ok: true, message: "subagent hook ignored", status: nil)
        }

        if hook.endsSession {
            pendingApprovals.cancel(sessionID: hook.sessionID)
            claudeSessions.removeValue(forKey: hook.sessionID)
            activeSubagents.clear(sessionID: hook.sessionID)
            endedClaudeSessions.record(sessionID: hook.sessionID)
            let mutation = try stateStore.update(
                sessionID: hook.sessionID,
                projectKey: hook.projectKey,
                source: hook.effectiveSource,
                status: nil,
                remove: true
            )
            logger.log(
                .info,
                "hook event=SessionEnd session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue) action=session_removed\(hookDiagnosticContext(hook))"
            )
            if mutation.changed, hook.effectiveSource == activeLayer {
                try reconcileLEDs()
            }
            return DaemonResponse(ok: true, message: "session ended", status: nil)
        }

        if endedClaudeSessions.isTombstoned(sessionID: hook.sessionID, ttl: claudeSessionEndTombstoneTTL) {
            logger.log(
                .debug,
                "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue) action=ignored_tombstoned\(hookDiagnosticContext(hook))"
            )
            return DaemonResponse(ok: true, message: "tombstoned session ignored", status: nil)
        }

        let previousRawStatus = claudeSessions[hook.sessionID]?.rawStatus ?? .idle
        claudeSessions[hook.sessionID] = ClaudeSessionRecord(
            sourceKind: hook.effectiveSource,
            cwd: hook.projectKey,
            herdrWorkspaceID: hook.herdrWorkspaceID,
            navigation: claudeNavigationTarget(for: hook),
            configDir: hook.configDir ?? (hook.effectiveSource == .claudeDesktop ? claudeDesktopConfigDir : (claudeConfigDirs.first ?? NSHomeDirectory() + "/.claude")),
            lastSeen: Date(),
            rawStatus: previousRawStatus
        )

        guard let status = hook.status else {
            logger.log(
                .debug,
                "hook ignored event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue)"
            )
            return DaemonResponse(ok: true, message: "hook ignored", status: nil)
        }
        // Track the hook-mapped status separately from whatever ends up
        // displayed (M6): `refreshSubagentOverride` reads this back once
        // the session's last tracked subagent stops, so it must be kept
        // current even while an override is suppressing it from ever
        // reaching `StateStore` directly.
        claudeSessions[hook.sessionID]?.rawStatus = status

        let hasActiveSubagents = activeSubagents.isActive(sessionID: hook.sessionID)
        let displayStatus: AgentStatus = hasActiveSubagents ? .working : status

        let projectKey = hook.projectKey
        if displayStatus == .approval {
            // Ensure the session already has a key before its approval
            // color is (debounced-)displayed, in case this is the very
            // first hook seen for it.
            _ = try stateStore.assignIfNeeded(sessionID: hook.sessionID, projectKey: projectKey, source: hook.effectiveSource)
            pendingApprovals.record(hook)
            logger.log(
                .info,
                "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) status=approval action=debounced route=user source=\(hook.effectiveSource.rawValue) delay_ms=\(Int(approvalDisplayDelay * 1_000))\(hookDiagnosticContext(hook))"
            )
            return DaemonResponse(ok: true, message: "user approval display deferred", status: nil)
        }

        let cancelledApproval = pendingApprovals.cancel(sessionID: hook.sessionID) != nil
        let mutation = try stateStore.update(
            sessionID: hook.sessionID,
            projectKey: projectKey,
            source: hook.effectiveSource,
            status: displayStatus
        )
        guard let slot = mutation.slot else {
            throw CLIError.runtime("Hook session was not assigned a C100 key")
        }
        logger.log(
            .info,
            "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=\(slot.status.rawValue) changed=\(mutation.changed)\(cancelledApproval ? " approval=resolved_before_display" : "")\(hasActiveSubagents ? " raw_status=\(status.rawValue) action=subagent_override" : "")"
        )
        if mutation.changed {
            try applyLayerAwareUpdate(source: hook.effectiveSource, mutation: mutation, slot: slot)
        }
        return DaemonResponse(ok: true, message: "hook accepted on key \(slot.keyIndex)", status: slot.status)
    }

    /// M6: `SubagentStart`/`SubagentStop` bookkeeping. Neither event ever
    /// carries a status of its own (`HookInput.status` is `nil` for both --
    /// see `claudeStatus`); they only mutate `activeSubagents` and then let
    /// `refreshSubagentOverride` decide what the session's display status
    /// should be.
    private func handleSubagentLifecycle(_ hook: HookInput) throws -> DaemonResponse {
        let sessionID = hook.sessionID
        if endedClaudeSessions.isTombstoned(sessionID: sessionID, ttl: claudeSessionEndTombstoneTTL) {
            logger.log(
                .debug,
                "hook event=\(hook.hookEventName) session=\(shortSession(sessionID)) action=ignored_tombstoned\(hookDiagnosticContext(hook))"
            )
            return DaemonResponse(ok: true, message: "tombstoned session ignored", status: nil)
        }

        switch hook.hookEventName {
        case "SubagentStart":
            activeSubagents.start(sessionID: sessionID, agentID: hook.agentID)
        case "SubagentStop":
            activeSubagents.stop(sessionID: sessionID, agentID: hook.agentID)
        default:
            break
        }

        logger.log(
            .info,
            "hook event=\(hook.hookEventName) session=\(shortSession(sessionID)) active_subagents=\(activeSubagents.count(sessionID: sessionID))\(hookDiagnosticContext(hook))"
        )
        try refreshSubagentOverride(sessionID: sessionID)
        return DaemonResponse(ok: true, message: "subagent lifecycle recorded", status: nil)
    }

    /// Re-derives `sessionID`'s displayed status from its raw hook status
    /// plus whether it currently has any tracked subagent running, and
    /// pushes the result to `StateStore`/the LEDs if it changed. A no-op if
    /// the daemon has no hook-derived record for the session (nothing to
    /// override yet, or it's already been torn down) -- `activeSubagents`
    /// itself is left untouched in that case since a later hook may still
    /// register the session before its subagents finish.
    @discardableResult
    private func refreshSubagentOverride(sessionID: String) throws -> Bool {
        guard let record = claudeSessions[sessionID] else { return false }
        let hasActiveSubagents = activeSubagents.isActive(sessionID: sessionID)
        let displayStatus: AgentStatus = hasActiveSubagents ? .working : record.rawStatus
        let mutation = try stateStore.update(
            sessionID: sessionID,
            projectKey: record.cwd,
            source: record.sourceKind,
            status: displayStatus
        )
        guard mutation.changed, let slot = mutation.slot else { return false }
        logger.log(
            .info,
            "claude session=\(shortSession(sessionID)) source=\(record.sourceKind.rawValue) active_subagents=\(activeSubagents.count(sessionID: sessionID)) status=\(slot.status.rawValue) action=subagent_override_refreshed"
        )
        try applyLayerAwareUpdate(source: record.sourceKind, mutation: mutation, slot: slot)
        return true
    }

    /// TTL sweep (M6): drops any tracked subagent whose `SubagentStart`
    /// arrived more than `activeSubagentTTL` ago without a matching
    /// `SubagentStop`. Cheap (in-memory only), so run on every hook as well
    /// as every `syncCatalog` tick -- unlike `applyActiveSubagentStaleSweep`,
    /// which stats a directory and is therefore sync-only.
    private func pruneActiveSubagents(now: Date = Date()) {
        let changedSessionIDs = activeSubagents.pruneExpired(now: now, ttl: activeSubagentTTL)
        for sessionID in changedSessionIDs {
            logger.log(
                .info,
                "claude session=\(shortSession(sessionID)) action=active_subagents_ttl_pruned remaining=\(activeSubagents.count(sessionID: sessionID)) threshold_s=\(Int(activeSubagentTTL))"
            )
            _ = try? refreshSubagentOverride(sessionID: sessionID)
        }
    }

    /// On-disk staleness sweep (M6), run once per `syncCatalog` tick: if
    /// every `agent-*.jsonl` under a tracked session's `subagents/`
    /// directory has gone untouched for `activeSubagentStaleAfter`, the
    /// daemon presumes every subagent it's still counting for that session
    /// is actually dead (crashed, or its `SubagentStop` never arrived) and
    /// clears them outright -- well before the 2h TTL would. A session
    /// whose directory doesn't exist or can't be read is left to the TTL
    /// alone, mirroring `ClaudeSessionsCatalog.isTranscriptStale`'s
    /// "missing means unknown, not stale" rule.
    private func applyActiveSubagentStaleSweep(now: Date = Date()) {
        for sessionID in activeSubagents.activeSessionIDs {
            guard let record = claudeSessions[sessionID] else { continue }
            var sweptAny = false
            for (agentKey, startedAt) in activeSubagents.entries(sessionID: sessionID) {
                // Grace window: `SubagentStart` fires before the subagent's
                // transcript file exists, so a young entry must never be
                // swept just because its (or any sibling's) file is missing
                // or stale -- that false positive cleared a fresh subagent
                // 75ms after its start and let the next `Stop` show done.
                guard now.timeIntervalSince(startedAt) > activeSubagentStaleAfter else { continue }
                // Past the grace window the agent's own transcript must
                // prove liveness; a missing file (fallback keys included)
                // or a stale one means its SubagentStop was likely lost.
                if ClaudeSessionsCatalog.isSubagentTranscriptFresh(
                    configDir: record.configDir,
                    cwd: record.cwd,
                    sessionID: sessionID,
                    agentID: agentKey,
                    now: now,
                    staleAfter: activeSubagentStaleAfter
                ) == true { continue }
                activeSubagents.remove(sessionID: sessionID, agentKey: agentKey)
                sweptAny = true
                logger.log(
                    .info,
                    "claude session=\(shortSession(sessionID)) agent=\(agentKey.prefix(8)) action=active_subagent_swept reason=transcript_stale threshold_s=\(Int(activeSubagentStaleAfter))"
                )
            }
            if sweptAny {
                _ = try? refreshSubagentOverride(sessionID: sessionID)
            }
        }
    }

    private func claudeNavigationTarget(for hook: HookInput) -> NavigationTarget {
        switch hook.effectiveSource {
        case .claudeHerdr:
            if let paneID = hook.herdrPaneID {
                return .herdrPane(paneID: paneID)
            }
            return .ghosttyTab(sessionID: hook.sessionID, cwd: hook.projectKey, pid: nil)
        case .claudeDesktop:
            return .claudeDesktop
        case .claudeTerminal, .codex:
            // `pid` is left `nil` here: a hook doesn't reliably know its own
            // parent Claude process's pid (async hooks in particular can be
            // reparented), and Ghostty's AppleScript surface doesn't expose
            // terminal pids to match against anyway (see
            // `GhosttyNavigator` -- matching is cwd-only). The real pid,
            // when known, comes from `ClaudeSessionsCatalog`'s own
            // `sessions/<pid>.json` scan and is only used there for
            // liveness GC, not navigation.
            return .ghosttyTab(sessionID: hook.sessionID, cwd: hook.projectKey, pid: nil)
        }
    }

    private func pruneEndedClaudeSessions(now: Date = Date()) {
        endedClaudeSessions.prune(now: now, ttl: claudeSessionEndTombstoneTTL)
    }

    private func servicePendingApprovals() {
        let due = pendingApprovals.due(delay: approvalDisplayDelay)
        guard !due.isEmpty else { return }
        for entry in due {
            do {
                guard catalogSessionIDs.contains(entry.hook.sessionID)
                    || claudeSessions[entry.hook.sessionID] != nil else {
                    logger.log(
                        .debug,
                        "hook event=PermissionRequest session=\(shortSession(entry.hook.sessionID)) action=dropped_not_in_catalog\(hookDiagnosticContext(entry.hook))"
                    )
                    continue
                }
                // M6: the raw status this debounced approval represents is
                // still `.approval` even if a subagent happens to be running
                // concurrently (unusual, but not impossible) -- record it so
                // `refreshSubagentOverride` restores to `.approval`, not
                // whatever stale value predates it, once that subagent
                // stops. The *displayed* status, however, still defers to
                // the override for as long as it's active.
                claudeSessions[entry.hook.sessionID]?.rawStatus = .approval
                let hasActiveSubagents = activeSubagents.isActive(sessionID: entry.hook.sessionID)
                let displayStatus: AgentStatus = hasActiveSubagents ? .working : .approval
                let mutation = try stateStore.update(
                    sessionID: entry.hook.sessionID,
                    projectKey: resolvedProjectKey(for: entry.hook),
                    source: entry.hook.effectiveSource,
                    status: displayStatus
                )
                guard let slot = mutation.slot else { continue }
                logger.log(
                    .info,
                    "hook event=PermissionRequest session=\(shortSession(entry.hook.sessionID)) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=\(slot.status.rawValue) action=waiting_for_user\(hasActiveSubagents ? " raw_status=approval action=subagent_override" : "")\(hookDiagnosticContext(entry.hook))"
                )
                guard mutation.changed else { continue }
                try applyLayerAwareUpdate(source: entry.hook.effectiveSource, mutation: mutation, slot: slot)
            } catch {
                logger.log(
                    .warning,
                    "hook event=PermissionRequest session=\(shortSession(entry.hook.sessionID)) action=display_failed error=\(error)"
                )
            }
        }
    }

    private func apply(_ status: AgentStatus) throws {
        if dryRun {
            let color = status.color
            logger.log(.info, "HID skipped status=\(status.rawValue) hsv=\(color.hue),\(color.saturation),\(color.value)")
            return
        }
        if connection == nil {
            connection = try C100Connection.connect(locationID: locationID, companion: true)
            connection?.brightnessPercent = brightnessPercent
            logger.log(.info, "HID connected location=\(locationID.map { String(format: "0x%X", $0) } ?? "auto")")
            lastPaintedFrame = nil
        }
        do {
            try connection?.apply(status: status)
            logger.log(.info, "HID applied status=\(status.rawValue) persistence=volatile")
            // Whole-board effect write, same as `applyAll` -- invalidates any
            // MIXED_RGB per-key frame `reconcileLEDs` had cached.
            lastPaintedFrame = nil
        } catch {
            connection = nil
            lastPaintedFrame = nil
            logger.log(.warning, "HID connection discarded after failure")
            throw error
        }
    }

    /// Only meaningful for the currently-displayed layer -- painting every
    /// layer's sessions the same manual color onto keys 0-79 would overlay
    /// up to 4 layers' worth of placements onto the same physical keys at
    /// once, which makes no sense since only one layer's grid is ever
    /// visible.
    private func applyAssigned(status: AgentStatus) throws {
        let assignments = try visibleAssignments()
        if dryRun {
            logger.log(.info, "HID skipped assigned_keys status=\(status.rawValue) assigned=\(assignments.count) layer=\(activeLayer.rawValue)")
            return
        }
        guard let connection else {
            throw CLIError.runtime("C100 vendor HID connection is unavailable")
        }
        var colors = Dictionary(
            uniqueKeysWithValues: assignments.map { ($0.key, status.color) }
        )
        for (key, color) in layerKeyColors() { colors[key] = color }
        try connection.apply(colorsByIndex: colors, defaultColor: LEDColorName.off.color)
        // Manual command: rare (admin-triggered), always a deliberate
        // full-frame overwrite. Still keep `lastPaintedFrame` in sync with
        // what's actually on the board so the *next* `reconcileLEDs` diffs
        // against reality instead of a stale cached frame.
        lastPaintedFrame = colors
        logger.log(.info, "HID applied frame assigned=\(assignments.count) unassigned=\(100 - assignments.count) layer=\(activeLayer.rawValue) persistence=volatile")
    }

    /// Repaints keys 0-79 with `activeLayer`'s sessions only (every other
    /// layer's sessions stay tracked in `StateStore` but never reach the
    /// LEDs while inactive -- see the M5 doc comment on `GridState`), keys
    /// 90-93 with the layer bar (base color, or blinking between
    /// base/attention color), plus row selectors and directional controls.
    ///
    /// Sends an incremental diff (`C100Connection.update`) against
    /// `lastPaintedFrame` whenever that cache is populated, so a session
    /// being added or removed only touches the LEDs that actually changed
    /// instead of blacking out and redrawing the whole grid. Falls back to
    /// the full-frame `apply` (and its ~50ms blackout) only when the board's
    /// state is unknown -- see `lastPaintedFrame`'s doc comment for exactly
    /// when that happens. Note this method is also the fallback any caller
    /// reaches for a *non*-active-layer change (see `syncCatalog`'s
    /// `anyReconciliationChanged` etc.): once `lastPaintedFrame` is warm,
    /// such a call computes the same `colors` as last time, so the diff is
    /// empty and `update` sends nothing at all -- there's no need to
    /// separately restrict those triggers to the active layer.
    private func reconcileLEDs() throws {
        let assignments = try visibleAssignments()
        let layerColors = layerKeyColors()
        lastPaintedLayerColors = layerColors
        if dryRun {
            logger.log(.info, "HID skipped frame assigned=\(assignments.count) unassigned=\(100 - assignments.count) layer=\(activeLayer.rawValue)")
            return
        }
        guard let connection else {
            throw CLIError.runtime("C100 vendor HID connection is unavailable")
        }
        var colors = Dictionary(
            uniqueKeysWithValues: assignments.map { ($0.key, $0.slot.status.color) }
        )
        for (key, color) in layerColors { colors[key] = color }
        if let previous = lastPaintedFrame {
            try connection.update(colorsByIndex: colors, defaultColor: LEDColorName.off.color, previousColorsByIndex: previous)
            logger.log(.info, "HID applied diff assigned=\(assignments.count) unassigned=\(100 - assignments.count) layer=\(activeLayer.rawValue) persistence=volatile")
        } else {
            try connection.apply(colorsByIndex: colors, defaultColor: LEDColorName.off.color)
            logger.log(.info, "HID applied frame assigned=\(assignments.count) unassigned=\(100 - assignments.count) layer=\(activeLayer.rawValue) persistence=volatile")
        }
        lastPaintedFrame = colors
    }

    /// Colors for the 4 layer keys (90-93) right now, given the current
    /// active layer and blink phase. Pulled out of `reconcileLEDs` so the
    /// ~600ms blink timer (`updateLayerBlink`) can compute the same colors
    /// without doing a full grid repaint.
    private func layerKeyColors() -> [Int: HSVColor] {
        var colors: [Int: HSVColor] = [:]
        for part in keyboardLayout.parts where part.enabled && part.kind == .source {
            for assignment in part.serviceAssignments where enabledSources.contains(assignment.source) {
            let source = assignment.source, keyIndex = assignment.key
            let statuses = (try? stateStore.assignments(source: source))?.map(\.slot.status) ?? []
            colors[keyIndex] = LayerKeyColorLogic.color(
                for: source,
                isActive: source == activeLayer,
                sessionStatuses: statuses,
                blinkPhaseOn: layerBlinkPhaseOn
            )
        }
        }
        let viewport = configuredViewport()
        let utilities = viewport.utilityColors(projects: virtualProjects[activeLayer] ?? [:], slots: (try? stateStore.assignments(source: activeLayer).map(\.slot)) ?? [])
        colors.merge(utilities) { _, utility in utility }
        for part in keyboardLayout.parts where part.enabled && part.kind == .action {
            colors[part.y * 10 + part.x] = HSVColor(hue: 128, saturation: 170, value: 100)
        }
        return colors
    }

    /// Called every `layerBlinkInterval` (~600ms) from the main loop. Only
    /// issues a single-key HID write (the same path a status-change hook
    /// already uses) for a layer key whose color actually changed since the
    /// last paint, so steady-state (nothing blinking) costs nothing beyond
    /// recomputing 4 colors and comparing them.
    private func updateLayerBlink() {
        layerBlinkPhaseOn.toggle()
        let colors = layerKeyColors()
        for (key, color) in colors where lastPaintedLayerColors[key] != color {
            do {
                try apply(color: color, at: key)
            } catch {
                logger.log(.warning, "layer key blink update failed key=\(key) error=\(error)")
            }
        }
        lastPaintedLayerColors = colors
    }

    /// A status mutation only ever needs to touch the LEDs when it belongs
    /// to the layer currently on screen -- a hook for a background layer's
    /// session still updates `StateStore` (see every `stateStore.update`
    /// call site), but must never repaint keys 0-79, which only ever show
    /// `activeLayer`. `mutation.previousSlot == nil` (a session's very first
    /// placement) still goes through `reconcileLEDs()` rather than a
    /// single-key write, since only `reconcileLEDs()` knows how to bring a
    /// brand-new key into the assigned-region set (see
    /// `KeychronProtocol.setRegionsReports`). That used to mean a full-frame
    /// blackout-then-redraw of every key; now that `reconcileLEDs()` diffs
    /// against `lastPaintedFrame`, it costs exactly one `setColorReport` for
    /// the new key plus one region-map resend -- no more than this method's
    /// own single-key path already costs for the region resend.
    private func applyLayerAwareUpdate(source: SessionSourceKind, mutation: SessionMutation, slot: SessionSlot) throws {
        guard source == activeLayer else { return }
        try reconcileLEDs()
    }

    private func configuredViewport() -> GridViewport {
        var viewport = viewports[activeLayer] ?? GridViewport()
        if let area = keyboardLayout.taskArea { viewport.area = area }
        viewport.arrowKeys = keyboardLayout.taskArea == nil ? [:] : keyboardLayout.arrows
        return viewport
    }

    private func visibleAssignments() throws -> [(key: Int, sessionID: String, slot: SessionSlot)] {
        guard keyboardLayout.taskArea != nil, enabledSources.contains(activeLayer) else { return [] }
        let assignments = try stateStore.assignments(source: activeLayer)
        var viewport = configuredViewport()
        viewport.normalize(projects: virtualProjects[activeLayer] ?? [:], slots: assignments.map(\.slot))
        viewports[activeLayer] = viewport
        return assignments.compactMap { assignment in
            viewport.key(for: assignment.slot).map { (key: $0, sessionID: assignment.sessionID, slot: assignment.slot) }
        }
    }

    private func scroll(_ direction: String) throws {
        guard keyboardLayout.taskArea != nil, enabledSources.contains(activeLayer) else { return }
        var viewport = configuredViewport()
        viewport.move(direction, projects: virtualProjects[activeLayer] ?? [:], slots: try stateStore.assignments(source: activeLayer).map(\.slot))
        viewports[activeLayer] = viewport
        try reconcileLEDs()
        logger.log(.info, "viewport direction=\(direction) topRow=\(viewport.topRow) leftColumn=\(viewport.leftColumn)")
    }

    /// Handles a press on one of the 4 layer-switch keys (90=Codex,
    /// 91=herdr, 92=Claude CLI, 93=Claude Desktop): switches the displayed
    /// layer, persists the choice (so a daemon restart resumes on it), and
    /// does a full repaint -- both because the grid content itself changes
    /// entirely and because pressing a blinking layer key is this app's
    /// only "acknowledge" gesture for that layer's attention state (there is
    /// no separate read receipt; switching to it and seeing its sessions is
    /// the acknowledgment).
    private func switchLayer(to newLayer: SessionSourceKind) {
        guard enabledSources.contains(newLayer) else { return }
        guard newLayer != activeLayer else {
            logger.log(.debug, "layer press layer=\(newLayer.rawValue) action=already_active")
            return
        }
        activeLayer = newLayer
        layerStore.save(newLayer)
        logger.log(.info, "layer switch active=\(newLayer.rawValue) action=switched")
        // Bug fix (M5.1): repack the layer being switched to from scratch
        // (ignoring its sticky `previousUnifiedPlacements`) before
        // repainting, so a session left parked on a stale row -- inherited
        // from the pre-M5 unified grid, or simply never repacked to the top
        // since a since-departed session left that row occupied -- gets
        // pulled back up instead of staying stuck there indefinitely.
        // Routine 2s syncs never do this (see `syncCatalog`'s doc comment),
        // so this is the only other place besides the daemon's first sync
        // that can move an unranked session's row.
        syncCatalog(forceRepackSources: [newLayer])
        // Force a full-frame repaint rather than diffing against the
        // outgoing layer's frame: a layer switch is meant to read as a
        // deliberate, whole-grid change (see the doc comment above), not an
        // incremental one.
        lastPaintedFrame = nil
        do {
            try reconcileLEDs()
        } catch {
            logger.log(.error, "layer switch repaint failed layer=\(newLayer.rawValue) error=\(error)")
        }
    }

    private func apply(color: HSVColor, at index: Int) throws {
        if dryRun {
            logger.log(.info, "HID skipped key=\(index) hsv=\(color.hue),\(color.saturation),\(color.value)")
            return
        }
        if connection == nil {
            connection = try C100Connection.connect(locationID: locationID, companion: true)
            connection?.brightnessPercent = brightnessPercent
            logger.log(.info, "HID connected location=\(locationID.map { String(format: "0x%X", $0) } ?? "auto")")
            // Freshly (re)connected: the board's real state is unknown, so
            // the next `reconcileLEDs()` must fall back to a full frame
            // instead of diffing against a stale `lastPaintedFrame`.
            lastPaintedFrame = nil
        }
        do {
            try connection?.apply(color: color, at: index)
            logger.log(.info, "HID applied key=\(index) persistence=volatile")
            // Keep the diff cache in sync with this single-key write so a
            // later `reconcileLEDs()` diff doesn't redundantly resend a key
            // this call already painted.
            lastPaintedFrame?[index] = color
        } catch {
            connection = nil
            lastPaintedFrame = nil
            logger.log(.warning, "HID connection discarded after failure")
            throw error
        }
    }

    private func applyAll(color: HSVColor) throws {
        if dryRun {
            logger.log(.info, "HID skipped all_keys hsv=\(color.hue),\(color.saturation),\(color.value)")
            return
        }
        guard let connection else {
            throw CLIError.runtime("C100 vendor HID connection is unavailable")
        }
        try connection.apply(color: color)
        // `apply(color:)` sets a single whole-board effect (or turns
        // everything off), not MIXED_RGB per-key state -- the board no
        // longer matches whatever `reconcileLEDs` last painted, so the next
        // call must repaint everything from scratch.
        lastPaintedFrame = nil
        logger.log(.info, "HID applied all_keys persistence=volatile")
    }

    /// Retry interval while waiting for the C100 vendor HID to appear (see
    /// `waitForConnection`). Must stay comfortably below launchd's 10s
    /// KeepAlive minimum runtime so a genuinely-missing keyboard doesn't
    /// masquerade as a crash loop, while still being coarse enough not to
    /// spin the CPU.
    private static let hidRetryInterval: TimeInterval = 3

    /// How often the "still waiting for the HID" line repeats while
    /// retrying -- logged once immediately so the log isn't silent, then
    /// throttled to this interval so a keyboard left unplugged for hours
    /// doesn't fill the log with a line every 3s.
    private static let hidWaitLogInterval: TimeInterval = 60

    /// Blocks (retrying every `hidRetryInterval`) until the C100 vendor HID
    /// is found, `locationID` resolves to more than one candidate (a
    /// configuration problem retrying can never fix -- rethrown
    /// immediately), or a shutdown signal arrives. Returns `nil` only in
    /// the shutdown case so `runLoop()` can exit cleanly instead of racing
    /// this loop.
    private func waitForConnection() throws -> C100Connection? {
        var lastWaitLogAt: Date?
        while daemonStopRequested == 0 {
            do {
                return try C100Connection.connect(locationID: locationID, companion: true)
            } catch C100ConnectionError.notFound {
                let now = Date()
                if lastWaitLogAt == nil || now.timeIntervalSince(lastWaitLogAt!) >= Self.hidWaitLogInterval {
                    logger.log(
                        .info,
                        "HID waiting reason=not_found location=\(locationID.map { String(format: "0x%X", $0) } ?? "auto") retry_interval_s=\(Int(Self.hidRetryInterval))"
                    )
                    lastWaitLogAt = now
                }
                Thread.sleep(forTimeInterval: Self.hidRetryInterval)
            }
        }
        return nil
    }

    /// Returns `false` only when a shutdown signal interrupted
    /// `waitForConnection()` before a device ever appeared, telling
    /// `runLoop()` to exit cleanly instead of proceeding without hardware.
    private func setupHardware() throws -> Bool {
        guard let connection = try waitForConnection() else {
            return false
        }
        self.connection = connection
        connection.brightnessPercent = brightnessPercent
        // A fresh connection's board state is unknown (could be a first
        // boot, or a reconnect after this daemon or another process left it
        // in some other effect/frame), so the next `reconcileLEDs` must do a
        // full frame rather than trust a diff against stale state.
        lastPaintedFrame = nil
        let actualLocation = connection.locationID
        logger.log(.info, "HID connected location=\(String(format: "0x%X", actualLocation))")

        pressedKeyIndexes = try connection.drainCompanionStates().last ?? []
        logger.log(.info, "input capture=firmware transport=companion normal_keystrokes=suppressed")
        return true
    }

    private func pollMatrix() throws {
        guard let connection else {
            throw CLIError.runtime("C100 vendor HID connection is unavailable during matrix polling")
        }
        if let process = hardwareActionProcess, NSWorkspace.shared.frontmostApplication?.processIdentifier != process {
            try connection.cancelKeyboardOutput()
            hardwareActionProcess = nil
        }
        let states = try connection.drainCompanionStates()
        for current in states {
            let newlyPressed = current.subtracting(pressedKeyIndexes)
            pressedKeyIndexes = current
            arrowKeyRepeat.updateHeld(current, now: ProcessInfo.processInfo.systemUptime, arrows: Set(keyboardLayout.arrows.keys))
            for keyIndex in newlyPressed.sorted() {
                handleKeyPress(keyIndex: keyIndex)
            }
        }
        // Companion reports arrive only when state changes, so repeat even
        // when this poll received no new HID reports. Releases above cancel first.
        for keyIndex in arrowKeyRepeat.due(now: ProcessInfo.processInfo.systemUptime) {
            handleKeyPress(keyIndex: keyIndex)
        }
    }

    private func handleKeyPress(keyIndex: Int) {
        guard let part = keyboardLayout.part(at: keyIndex) else { return }
        switch part.kind {
        case .scroll:
            do { try scroll(part.direction!) } catch { logger.log(.error, "scroll failed error=\(error)") }
            return
        case .source:
            if let source = part.serviceAssignments.first(where: { $0.key == keyIndex })?.source { switchLayer(to: source) }
            return
        case .action:
            do {
                let bindings = CodexActionBindings(home: codexPaths.home)
                let app = NSWorkspace.shared.frontmostApplication
                let resolved = try ForegroundAction.resolve(part, foreground: app?.bundleIdentifier, enabledServices: enabledSources, bindings: bindings.read)
                guard let process = app?.processIdentifier else { throw CLIError.runtime("前面アプリを取得できません") }
                let shortcut = resolved.shortcut
                if let connection, connection.supportsKeyboardOutput {
                    guard let usb = USBShortcut(shortcut) else { throw CLIError.runtime("送信できる USB ショートカットがありません") }
                    try connection.configureShortcut(key: keyIndex, shortcut: usb)
                    hardwareActionProcess = process
                    // A switch between either supported app must also cancel this press.
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process else {
                        try connection.cancelKeyboardOutput(); hardwareActionProcess = nil
                        throw CLIError.runtime("前面アプリが変わったため送信を中止しました")
                    }
                    try connection.tapShortcut(key: keyIndex)
                    logger.log(.info, "action key_queued id=\(part.action!) app=\(resolved.bundleIdentifier) shortcut=\(shortcut.accelerator) route=keyboard-hid execution=unconfirmed")
                } else {
                    try resolved.post(to: process)
                    logger.log(.info, "action key_posted id=\(part.action!) app=\(resolved.bundleIdentifier) shortcut=\(shortcut.accelerator) route=session execution=unconfirmed")
                }
                actionError = nil
            } catch {
                actionError = String(describing: error)
                logger.log(.error, "action failed id=\(part.action!) error=\(error)")
            }
            return
        case .tasks: break
        }
        do {
            guard let assignment = try visibleAssignments().first(where: { $0.key == keyIndex }) else {
                logger.log(.debug, "input key=\(keyIndex) row=\(keyIndex / 10) col=\(keyIndex % 10) layer=\(activeLayer.rawValue) action=ignored_unassigned")
                return
            }
            logger.log(
                .info,
                "input key=\(keyIndex) row=\(keyIndex / 10) col=\(keyIndex % 10) session=\(shortSession(assignment.sessionID))"
            )
            // Bug fix (M5.1): hook-derived navigation (herdr pane id etc.) is
            // preferred when available since it is the most precise; next,
            // the herdr catalog's own resolved target; then the unified
            // catalog's resolved target for *any* source (covers a
            // claude-terminal/claude-desktop session `syncCatalog` has
            // placed via its file-scan providers but that has never sent a
            // hook). Only when none of those resolve -- and only on the
            // Codex layer itself -- does this fall back to `.codexThread`;
            // any other layer with nothing resolvable does nothing rather
            // than risk launching the wrong app (see
            // `resolveNavigationTarget`'s doc comment for the pre-fix bug).
            let target = StatusDaemon.resolveNavigationTarget(
                sessionID: assignment.sessionID,
                layer: activeLayer,
                hookNavigation: claudeSessions[assignment.sessionID]?.navigation,
                herdrNavigation: herdrNavigationBySession[assignment.sessionID],
                catalogNavigation: sessionNavigationBySession[assignment.sessionID]
            )
            guard let target else {
                logger.log(
                    .warning,
                    "input key=\(keyIndex) session=\(shortSession(assignment.sessionID)) layer=\(activeLayer.rawValue) action=navigation_unresolved reason=no_target_for_non_codex_session"
                )
                return
            }
            let navigated = navigationRouter.handleTap(
                keyIndex: keyIndex,
                sessionID: assignment.sessionID,
                target: target,
                status: assignment.slot.status
            )
            guard navigated, assignment.slot.status == .done else { return }

            let mutation = try stateStore.update(
                sessionID: assignment.sessionID,
                projectKey: assignment.slot.projectKey,
                source: activeLayer,
                status: .idle
            )
            guard mutation.slot != nil else { return }
            try reconcileLEDs()
            logger.log(
                .info,
                "input key=\(keyIndex) session=\(shortSession(assignment.sessionID)) action=acknowledge_done status=idle"
            )
        } catch {
            logger.log(.error, "input key=\(keyIndex) state_lookup_failed error=\(error)")
        }
    }

    /// Pure navigation-resolution rule for a key press. This is the fix for
    /// the "pressing a CLI/Desktop-layer key opens Codex Desktop" bug: the
    /// old `handleKeyPress` fell back to `.codexThread` for *any* session
    /// unresolved by `claudeSessions`/`herdrNavigationBySession` (an M1-era
    /// stopgap, back when Codex was the only source), so a claude-terminal
    /// or claude-desktop session `syncCatalog` had only ever placed via a
    /// file scan (no hook received yet) opened Codex Desktop instead of
    /// Ghostty/Claude Desktop. Precedence, most to least precise: hook data,
    /// herdr's own catalog resolution, the unified catalog's resolution for
    /// any source, and -- only on the Codex layer itself -- a
    /// `.codexThread` fallback built from the bare session id. Every other
    /// layer with nothing resolvable returns `nil` (do nothing) rather than
    /// guess and risk launching the wrong app.
    static func resolveNavigationTarget(
        sessionID: String,
        layer: SessionSourceKind,
        hookNavigation: NavigationTarget?,
        herdrNavigation: NavigationTarget?,
        catalogNavigation: NavigationTarget?
    ) -> NavigationTarget? {
        if let hookNavigation { return hookNavigation }
        if let herdrNavigation { return herdrNavigation }
        if let catalogNavigation { return catalogNavigation }
        guard layer == .codex else { return nil }
        return .codexThread(sessionID: sessionID)
    }

    /// `forceRepackSources` (M5.1 bug fix): sources in this set have their
    /// sticky `previousUnifiedPlacements` feedback ignored for this one
    /// sync, so every session in that layer without an explicit `rowRank`/
    /// `columnRank` (herdr workspace number, Codex absolute row -- those
    /// keep their claimed slot regardless) gets packed fresh from row 0 in
    /// recency-then-stable-key order (see `UnifiedLayout.compute`). Ranked
    /// rows/columns are unaffected either way since an explicit slot claim
    /// never depends on `previousPlacements`.
    ///
    /// This is intentionally *not* the default: repacking on every routine
    /// 2s sync would undo `UnifiedLayout`'s whole sticky-placement mechanism
    /// and reintroduce the flicker it was built to fix (see
    /// `UnifiedLayout.compute`'s doc comment and the M0.1 regression tests).
    /// It's only ever passed non-empty from `run()`'s first sync (a layer's
    /// grid has no placement history yet, so there is nothing to preserve)
    /// and from `switchLayer` (clears out any row a session inherited from
    /// the pre-M5 unified grid, or simply never got repacked to the top of,
    /// so a layer with e.g. one session doesn't keep showing it stuck on row
    /// 4 just because that's the row a since-departed session left behind).
    private func syncCatalog(forceRepackSources: Set<SessionSourceKind> = []) {
        nextCatalogSync = Date().addingTimeInterval(2)
        pruneEndedClaudeSessions()
        pruneActiveSubagents()
        applyActiveSubagentStaleSweep()
        do {
            // Codex-authoritative view: approval routing, deferred-hook
            // promotion, and turn-abort monitoring below remain gated to Codex
            // (sourceKind == .codex) and read this directly rather than going
            // through the generic AgentSession abstraction, since they need
            // Codex-only fields (rollout paths, createdAt) that the unified
            // model does not carry.
            let codexLayout = enabledSources.contains(.codex) ? try CodexCatalog.layout(paths: codexPaths, unbounded: true) : CodexCatalog.orderedLayout([], sidebar: .empty, unbounded: true)
            let catalogSessions = codexLayout.placements.map(\.session)
            let nextCatalogSessionIDs = Set(catalogSessions.map(\.sessionID))
            catalogProjectBySession = Dictionary(
                uniqueKeysWithValues: catalogSessions.map { ($0.sessionID, $0.projectKey) }
            )


            var agentSessions: [AgentSession] = []
            for provider in providers where enabledSources.contains(provider.kind) {
                agentSessions.append(contentsOf: try provider.snapshot())
            }

            // herdr is placement-authoritative for any session it currently
            // reports (M2): a session appearing in both the herdr snapshot
            // and the hook-derived `claudeSessions` map is placed using the
            // herdr entry only -- the hook-derived duplicate is dropped
            // below so it doesn't create a second, conflicting placement for
            // the same session id. Status, however, is decided separately
            // (stateStore.reconcile below carries the existing status
            // forward regardless of placement source; `handleClaudeHook`
            // remains the only writer of status for sessions the daemon has
            // ever received a hook for).
            let herdrAgentSessions = agentSessions.filter { $0.sourceKind == .claudeHerdr }
            let currentHerdrSessionIDs = Set(herdrAgentSessions.map(\.sessionID))
            herdrNavigationBySession = Dictionary(
                uniqueKeysWithValues: herdrAgentSessions.map { ($0.sessionID, $0.navigation) }
            )

            // A session herdr was reporting last sync but no longer reports
            // this sync means its pane closed (or herdr lost track of it):
            // tear it down outright rather than letting it fall back to a
            // stale hook-derived placement below. Tombstoned so a late/
            // reordered hook for it can't resurrect it either.
            var herdrRemovalChanged = false
            for sessionID in previousHerdrSessionIDs.subtracting(currentHerdrSessionIDs) {
                pendingApprovals.cancel(sessionID: sessionID)
                claudeSessions.removeValue(forKey: sessionID)
                activeSubagents.clear(sessionID: sessionID)
                herdrStatusStreaks.removeValue(forKey: sessionID)
                endedClaudeSessions.record(sessionID: sessionID)
                let mutation = try stateStore.update(
                    sessionID: sessionID,
                    projectKey: "(herdr-pane-closed)",
                    source: .claudeHerdr,
                    status: nil,
                    remove: true
                )
                if mutation.changed {
                    herdrRemovalChanged = true
                    logger.log(.info, "herdr session=\(shortSession(sessionID)) action=removed reason=pane_closed")
                }
            }
            previousHerdrSessionIDs = currentHerdrSessionIDs

            // ClaudeSessionsCatalog (M3) is placement-authoritative for any
            // claude-terminal session it currently reports, the same way
            // herdr is above: a session appearing in both the on-disk scan
            // and the hook-derived `claudeSessions` map is placed using the
            // scanned entry (whose cwd/navigation come straight from
            // `sessions/<pid>.json`, no staleness risk), and the
            // hook-derived duplicate is dropped below.
            let claudeTerminalAgentSessions = agentSessions.filter { $0.sourceKind == .claudeTerminal }
            let currentClaudeTerminalSessionIDs = Set(claudeTerminalAgentSessions.map(\.sessionID))

            // A claude-terminal session the daemon has a hook-derived record
            // for, but that no longer shows up in the on-disk scan (process
            // died / `sessions/<pid>.json` disappeared) without ever sending
            // `SessionEnd`: GC it outright, mirroring the herdr pane-closed
            // GC above. This closes the M1 gap where a crashed terminal
            // session lingered until the daemon itself restarted.
            var claudeTerminalRemovalChanged = false
            for sessionID in previousClaudeTerminalSessionIDs.subtracting(currentClaudeTerminalSessionIDs) {
                guard claudeSessions[sessionID]?.sourceKind == .claudeTerminal else { continue }
                pendingApprovals.cancel(sessionID: sessionID)
                claudeSessions.removeValue(forKey: sessionID)
                activeSubagents.clear(sessionID: sessionID)
                endedClaudeSessions.record(sessionID: sessionID)
                let mutation = try stateStore.update(
                    sessionID: sessionID,
                    projectKey: "(claude-terminal-ended)",
                    source: .claudeTerminal,
                    status: nil,
                    remove: true
                )
                if mutation.changed {
                    claudeTerminalRemovalChanged = true
                    logger.log(.info, "claude session=\(shortSession(sessionID)) source=claude-terminal action=removed reason=process_or_session_file_gone")
                }
            }
            previousClaudeTerminalSessionIDs = currentClaudeTerminalSessionIDs

            // ClaudeDesktopCatalog (M4) is placement-authoritative for any
            // claude-desktop session it currently reports, the same way
            // herdr/ClaudeSessionsCatalog are above.
            let claudeDesktopAgentSessions = agentSessions.filter { $0.sourceKind == .claudeDesktop }
            let currentClaudeDesktopSessionIDs = Set(claudeDesktopAgentSessions.map(\.sessionID))

            // A claude-desktop session the daemon has a hook-derived record
            // for, but that no longer shows up in the on-disk scan (archived,
            // aged out past the 6-hour liveness window, or Desktop itself
            // quit) without ever sending `SessionEnd`: GC it outright,
            // mirroring the herdr/claude-terminal GCs above.
            var claudeDesktopRemovalChanged = false
            for sessionID in previousClaudeDesktopSessionIDs.subtracting(currentClaudeDesktopSessionIDs) {
                guard claudeSessions[sessionID]?.sourceKind == .claudeDesktop else { continue }
                pendingApprovals.cancel(sessionID: sessionID)
                claudeSessions.removeValue(forKey: sessionID)
                activeSubagents.clear(sessionID: sessionID)
                endedClaudeSessions.record(sessionID: sessionID)
                let mutation = try stateStore.update(
                    sessionID: sessionID,
                    projectKey: "(claude-desktop-ended)",
                    source: .claudeDesktop,
                    status: nil,
                    remove: true
                )
                if mutation.changed {
                    claudeDesktopRemovalChanged = true
                    logger.log(.info, "claude session=\(shortSession(sessionID)) source=claude-desktop action=removed reason=archived_or_stale_or_app_quit")
                }
            }
            previousClaudeDesktopSessionIDs = currentClaudeDesktopSessionIDs

            // Dedup (M3/M4): the same Claude session id can legitimately be
            // reported by more than one provider at once -- most commonly a
            // herdr pane whose `sessions/<pid>.json` this scan also sees
            // directly, or a Claude Desktop session that also happens to
            // match a claude-terminal scan entry. Per the dedup priority
            // (claudeHerdr > claudeDesktop > claudeTerminal), drop the lower-
            // priority copy here, before `UnifiedLayout.compute` ever sees
            // it: leaving both in would hand the same session id two
            // candidate placements, and which one "wins" would depend on
            // non-deterministic dictionary/array ordering, showing up as
            // spurious `action=moved` churn between syncs instead of a
            // single stable placement.
            agentSessions.removeAll {
                $0.sourceKind == .claudeTerminal
                    && (currentHerdrSessionIDs.contains($0.sessionID) || currentClaudeDesktopSessionIDs.contains($0.sessionID))
            }
            agentSessions.removeAll { $0.sourceKind == .claudeDesktop && currentHerdrSessionIDs.contains($0.sessionID) }

            // Cross-source stale GC (M3): any hook-registered Claude session
            // (herdr/terminal/desktop alike) whose transcript jsonl hasn't
            // been touched in `claudeTranscriptStaleAfter` is presumed
            // abandoned. This is a safety net on top of the source-specific
            // GCs above/herdr's, covering crash scenarios those don't (e.g.
            // Claude Desktop, or a source-specific GC itself lagging).
            let (staleGCChanged, staleGCRemovedIDs) = try applyClaudeTranscriptStaleGC()
            for sessionID in staleGCRemovedIDs {
                logger.log(.info, "claude session=\(shortSession(sessionID)) action=removed reason=transcript_stale threshold_s=\(Int(claudeTranscriptStaleAfter))")
            }

            // Claude has no on-disk catalog to snapshot yet for the
            // terminal-direct path (M3), so the sessions the daemon has
            // learned about directly from hooks stand in here -- except any
            // session herdr or ClaudeSessionsCatalog already placed above.
            // This is what lets a hook-registered Claude session "move" from
            // its provisional row (assigned by handleClaudeHook's
            // stateStore.update) onto the UnifiedLayout row its
            // herdrWorkspaceID/cwd grouping actually resolves to.
            agentSessions.append(contentsOf: claudeSessions.compactMap { sessionID, record -> AgentSession? in
                guard !currentHerdrSessionIDs.contains(sessionID),
                      !currentClaudeTerminalSessionIDs.contains(sessionID),
                      !currentClaudeDesktopSessionIDs.contains(sessionID) else { return nil }
                return AgentSession(
                    sourceKind: record.sourceKind,
                    sessionID: sessionID,
                    cwd: record.cwd,
                    rowHints: RowGroupingHints(codexProjectID: nil, herdrWorkspaceID: record.herdrWorkspaceID),
                    recency: record.lastSeen.timeIntervalSince1970,
                    rowRank: nil,
                    columnRank: nil,
                    seedStatus: nil,
                    navigation: record.navigation
                )
            })
            // M5: each layer (SessionSourceKind) gets its own independent
            // `UnifiedLayout.compute` over all logical rows and columns,
            // no cross-layer row merging -- and its own `StateStore.reconcile`
            // call, which only ever touches that layer's slice of the grid
            // (see `GridState`'s doc comment). This is what makes a herdr
            // session and a Codex session that happen to share a cwd land on
            // independent rows in their own layers instead of merging into
            // one shared row the way pre-M5's single grid did.
            agentSessions = agentSessions.filter { enabledSources.contains($0.sourceKind) }
            var unifiedBySource: [SessionSourceKind: UnifiedLayoutResult] = [:]
            var reconciliationBySource: [SessionSourceKind: GridReconciliation] = [:]
            var anyReconciliationChanged = false
            var currentCatalogWarnings: Set<String> = []
            // Bug fix (M5.1): rebuilt fresh every sync from this sync's
            // placements across *every* layer, so `handleKeyPress` can
            // resolve a key press on any session regardless of source --
            // see `sessionNavigationBySession`'s doc comment.
            var nextSessionNavigationBySession: [String: NavigationTarget] = [:]
            for source in SessionSourceKind.allCases {
                let sourceSessions = agentSessions.filter { $0.sourceKind == source }
                let sourcePreviousPlacements = forceRepackSources.contains(source)
                    ? [:]
                    : (previousUnifiedPlacements[source] ?? [:])
                let unified = UnifiedLayout.compute(
                    sessions: sourceSessions,
                    previousPlacements: sourcePreviousPlacements,
                    maxRows: max(sourceSessions.count, (sourceSessions.compactMap(\.rowRank).max() ?? -1) + 1, 1),
                    columnCapacity: max(sourceSessions.count, (sourceSessions.compactMap(\.columnRank).max() ?? -1) + 1, 10)
                )
                virtualProjects[source] = unified.projectRows
                for placement in unified.placements {
                    nextSessionNavigationBySession[placement.session.sessionID] = placement.session.navigation
                }
                currentCatalogWarnings.formUnion(unified.warnings.map { "\(source.rawValue): \($0)" })
                previousUnifiedPlacements[source] = Dictionary(uniqueKeysWithValues: unified.placements.map {
                    ($0.session.sessionID, UnifiedLayout.PreviousSlot(row: $0.row, column: $0.column))
                })
                let reconciliation = try stateStore.reconcile(
                    source: source,
                    projectRows: unified.projectRows,
                    placements: unified.placements.map {
                        (
                            sessionID: $0.session.sessionID,
                            projectKey: $0.projectKey,
                            row: $0.row,
                            column: $0.column
                        )
                    }
                )
                unifiedBySource[source] = unified
                reconciliationBySource[source] = reconciliation
                if reconciliation.changed { anyReconciliationChanged = true }
            }
            sessionNavigationBySession = nextSessionNavigationBySession
            for warning in currentCatalogWarnings.subtracting(previousCatalogWarnings) {
                logger.log(.warning, "catalog layout warning=\(warning)")
            }
            previousCatalogWarnings = currentCatalogWarnings
            let sessions = catalogSessions

            let herdrStatusChanged = try applyHerdrStatusHeuristics(
                herdrAgentSessions: herdrAgentSessions,
                reconciliation: reconciliationBySource[.claudeHerdr] ?? GridReconciliation(previous: GridState(), current: GridState())
            )

            catalogSessionIDs = nextCatalogSessionIDs
            let deferredDrain = deferredHooks.drain(
                catalogSessionIDs: nextCatalogSessionIDs,
                maxAge: deferredHookMaxAge
            )
            for entry in deferredDrain.expired {
                logger.log(
                    .info,
                    "hook event=\(entry.hook.hookEventName) session=\(shortSession(entry.hook.sessionID)) status=\(entry.status.rawValue) action=dropped_not_in_catalog\(hookDiagnosticContext(entry.hook))"
                )
            }
            var deferredChanged = false
            for entry in deferredDrain.promoted {
                var promotedStatus = entry.status
                if entry.hook.requestsPermission {
                    switch CodexApprovalRouting.displayRoute(for: entry.hook, paths: codexPaths) {
                    case let .user(reason):
                        pendingApprovals.record(entry.hook)
                        logger.log(
                            .info,
                            "hook event=PermissionRequest session=\(shortSession(entry.hook.sessionID)) status=approval action=debounced_from_deferred route=user reason=\(reason) delay_ms=\(Int(approvalDisplayDelay * 1_000))\(hookDiagnosticContext(entry.hook))"
                        )
                        continue
                    case let .automatic(reviewer):
                        promotedStatus = .working
                        logger.log(
                            .info,
                            "hook event=PermissionRequest session=\(shortSession(entry.hook.sessionID)) status=working action=keep_working_from_deferred route=automatic reviewer=\(reviewer ?? "unknown")\(hookDiagnosticContext(entry.hook))"
                        )
                    }
                }
                let mutation = try stateStore.update(
                    sessionID: entry.hook.sessionID,
                    projectKey: resolvedProjectKey(for: entry.hook),
                    source: .codex,
                    status: promotedStatus
                )
                guard let slot = mutation.slot else { continue }
                deferredChanged = deferredChanged || mutation.changed
                logger.log(
                    .info,
                    "hook event=\(entry.hook.hookEventName) session=\(shortSession(entry.hook.sessionID)) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=\(slot.status.rawValue) action=promoted_from_deferred\(hookDiagnosticContext(entry.hook))"
                )
            }
            var interruptionChanged = false
            let interruptedSessionIDs = turnMonitor.interruptedSessionIDs(in: sessions, paths: codexPaths)
            let assignments = Dictionary(
                uniqueKeysWithValues: try stateStore.assignments().map { ($0.sessionID, $0.slot) }
            )
            for sessionID in interruptedSessionIDs {
                guard let slot = assignments[sessionID],
                      slot.status == .working || slot.status == .approval else { continue }
                pendingApprovals.cancel(sessionID: sessionID)
                let mutation = try stateStore.update(
                    sessionID: sessionID,
                    projectKey: slot.projectKey,
                    source: .codex,
                    status: .idle
                )
                guard let updated = mutation.slot, mutation.changed else { continue }
                interruptionChanged = true
                logger.log(
                    .info,
                    "catalog session=\(shortSession(sessionID)) event=turn_aborted row=\(updated.row) col=\(updated.column) key=\(updated.keyIndex) status=idle action=interrupted"
                )
            }

            for source in SessionSourceKind.allCases {
                guard let reconciliation = reconciliationBySource[source], reconciliation.changed else { continue }
                let previousIDs = Set(reconciliation.previous.sessions.keys)
                let currentIDs = Set(reconciliation.current.sessions.keys)
                for sessionID in previousIDs.subtracting(currentIDs) {
                    guard let slot = reconciliation.previous.sessions[sessionID] else { continue }
                    logger.log(
                        .info,
                        "catalog session=\(shortSession(sessionID)) layer=\(source.rawValue) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) action=released"
                    )
                }
                for sessionID in currentIDs {
                    guard let slot = reconciliation.current.sessions[sessionID] else { continue }
                    let previous = reconciliation.previous.sessions[sessionID]
                    guard previous != slot else { continue }
                    let action = previous == nil ? "assigned" : "moved"
                    logger.log(
                        .info,
                        "catalog session=\(shortSession(sessionID)) layer=\(source.rawValue) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=\(slot.status.rawValue) action=\(action)"
                    )
                }
                let unified = unifiedBySource[source]
                logger.log(
                    .info,
                    "catalog sync layer=\(source.rawValue) projects=\(unified?.projectRows.count ?? 0) sessions=\(unified?.placements.count ?? 0) layout=updated"
                )
            }
            if anyReconciliationChanged || deferredChanged || interruptionChanged || herdrRemovalChanged || herdrStatusChanged
                || claudeTerminalRemovalChanged || claudeDesktopRemovalChanged || staleGCChanged {
                try reconcileLEDs()
            }
        } catch {
            logger.log(.warning, "catalog sync failed error=\(error)")
        }
    }

    /// Removes any hook-registered Claude session (herdr/terminal/desktop
    /// alike) whose transcript jsonl mtime is older than
    /// `claudeTranscriptStaleAfter`. A missing transcript is never treated
    /// as stale (see `ClaudeSessionsCatalog.isTranscriptStale`), so a
    /// brand-new session or one whose `configDir` this daemon doesn't have
    /// right is left alone rather than GC'd on a false signal.
    private func applyClaudeTranscriptStaleGC() throws -> (changed: Bool, removedSessionIDs: [String]) {
        var changed = false
        var removed: [String] = []
        for (sessionID, record) in claudeSessions {
            guard ClaudeSessionsCatalog.isTranscriptStale(
                configDir: record.configDir,
                cwd: record.cwd,
                sessionID: sessionID,
                staleAfter: claudeTranscriptStaleAfter
            ) else { continue }
            pendingApprovals.cancel(sessionID: sessionID)
            claudeSessions.removeValue(forKey: sessionID)
            activeSubagents.clear(sessionID: sessionID)
            endedClaudeSessions.record(sessionID: sessionID)
            let mutation = try stateStore.update(
                sessionID: sessionID,
                projectKey: "(claude-transcript-stale)",
                source: record.sourceKind,
                status: nil,
                remove: true
            )
            if mutation.changed {
                changed = true
                removed.append(sessionID)
            }
        }
        return (changed, removed)
    }

    /// herdr `agent_status` is only ever used (a) to seed a brand-new
    /// session's initial status when no Claude hook has registered it yet,
    /// or (b) to recover from a genuinely missed hook: when the current
    /// slot is stuck in `.working`/`.approval` (never `.done`/`.idle` --
    /// see below) and herdr reports idle/done for at least
    /// `HerdrHookMissRecovery.minStreakSeconds` worth of consecutive syncs
    /// *and* the last hook seen for that session predates that streak, the
    /// hook is presumed lost and herdr's status wins. In every other case
    /// the hook remains authoritative (this function never touches a
    /// session's status while its hook activity is current). The actual
    /// eligibility decision for (b) lives in `HerdrHookMissRecovery`, kept
    /// separate so it can be unit-tested without a live `StatusDaemon`.
    ///
    /// Two guards exist specifically to stop a real race: herdr's
    /// `agent_status` has no "done" concept of its own and reports idle
    /// almost immediately after a Claude Stop hook lands, which used to
    /// read as a "missed hook" within a couple of sync cycles and demote a
    /// just-finished `.done` session back to `.idle` (full-frame repaint,
    /// visible flicker). To prevent that:
    ///   - recovery never fires when the current slot is already
    ///     `.done` or `.idle` -- those states are terminal enough from
    ///     herdr's perspective that there is nothing to "recover"; a
    ///     `.done -> .idle` downgrade in particular must never happen here.
    ///   - the idle/done streak must have persisted for a minimum wall-clock
    ///     duration, not just a minimum sync count, since two consecutive
    ///     syncs can both land within a second of the hook firing.
    private func applyHerdrStatusHeuristics(
        herdrAgentSessions: [AgentSession],
        reconciliation: GridReconciliation
    ) throws -> Bool {
        var changed = false
        let currentHerdrSessionIDs = Set(herdrAgentSessions.map(\.sessionID))
        herdrStatusStreaks = herdrStatusStreaks.filter { currentHerdrSessionIDs.contains($0.key) }

        for session in herdrAgentSessions {
            // (a) Seed brand-new sessions -- ones UnifiedLayout just placed
            // for the first time (no previous slot) that no Claude hook has
            // ever touched -- with herdr's reported status instead of the
            // hard-coded `.idle` default `stateStore.reconcile` assigns.
            if reconciliation.previous.sessions[session.sessionID] == nil,
               claudeSessions[session.sessionID] == nil,
               let seedStatus = session.seedStatus, seedStatus != .idle {
                let mutation = try stateStore.update(
                    sessionID: session.sessionID,
                    projectKey: reconciliation.current.sessions[session.sessionID]?.projectKey ?? "(herdr)",
                    source: .claudeHerdr,
                    status: seedStatus
                )
                if mutation.changed {
                    changed = true
                    logger.log(
                        .info,
                        "herdr session=\(shortSession(session.sessionID)) action=seeded status=\(seedStatus.rawValue)"
                    )
                }
            }

            // (b) Hook-miss recovery bookkeeping: only idle/done are ever
            // used to correct a stuck status (working/approval streaks are
            // ignored -- a stuck "working" LED is a much smaller nuisance
            // than incorrectly clearing a genuine approval prompt).
            guard let seedStatus = session.seedStatus, seedStatus == .idle || seedStatus == .done else {
                herdrStatusStreaks.removeValue(forKey: session.sessionID)
                continue
            }
            if let streak = herdrStatusStreaks[session.sessionID], streak.status == seedStatus {
                herdrStatusStreaks[session.sessionID] = (seedStatus, streak.count + 1, streak.since)
            } else {
                herdrStatusStreaks[session.sessionID] = (seedStatus, 1, Date())
            }
        }

        for (sessionID, streak) in herdrStatusStreaks {
            guard let currentSlot = reconciliation.current.sessions[sessionID] else { continue }
            guard let recovered = HerdrHookMissRecovery.recoveredStatus(
                streak: streak,
                hookLastSeen: claudeSessions[sessionID]?.lastSeen,
                currentStatus: currentSlot.status
            ) else { continue }
            let mutation = try stateStore.update(
                sessionID: sessionID,
                projectKey: currentSlot.projectKey,
                source: .claudeHerdr,
                status: recovered
            )
            if mutation.changed {
                changed = true
                logger.log(
                    .info,
                    "herdr session=\(shortSession(sessionID)) action=hook_miss_recovered status=\(recovered.rawValue) streak=\(streak.count)"
                )
            }
        }

        return changed
    }

    private func resolvedProjectKey(for hook: HookInput) -> String {
        guard hook.effectiveSource == .codex else { return hook.projectKey }
        return catalogProjectBySession[hook.sessionID]
            ?? CodexCatalog.projectKey(sessionID: hook.sessionID, paths: codexPaths)
    }

    private func shortSession(_ sessionID: String) -> String {
        String(sessionID.prefix(8))
    }

    private func hookDiagnosticContext(_ hook: HookInput) -> String {
        let fields = [
            hook.turnID.map { "turn=\(shortSession($0))" },
            hook.agentID.map { "agent=\(shortSession($0))" },
            hook.agentType.map { "agent_type=\(safeLogValue($0))" },
            hook.toolName.map { "tool=\(safeLogValue($0))" },
            hook.permissionMode.map { "permission_mode=\(safeLogValue($0))" },
        ].compactMap { $0 }
        return fields.isEmpty ? "" : " " + fields.joined(separator: " ")
    }

    private func safeLogValue(_ value: String) -> String {
        String(
            value
                .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
                .prefix(48)
        )
    }
}
