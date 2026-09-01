import Darwin
import Foundation

nonisolated(unsafe) private var daemonStopRequested: sig_atomic_t = 0

private func requestDaemonStop(_: Int32) {
    daemonStopRequested = 1
}

final class StatusDaemon {
    private let socketPath: String
    private let locationID: Int?
    private let grabberSocketPath: String
    private let dryRun: Bool
    private let logger: StatusLogger
    private let stateStore = StateStore()
    private var connection: C100Connection?
    private var grabberLease: GrabberLeaseClient?
    private var nextGrabberHeartbeat = Date.distantFuture
    private var protocolVersion = 0
    private var pressedKeyIndexes: Set<Int> = []
    private var nextCatalogSync = Date.distantPast
    private var catalogProjectBySession: [String: String] = [:]
    private var catalogProjectByCWD: [String: String] = [:]
    private var catalogSessionIDs: Set<String> = []
    /// Sticky feedback for `UnifiedLayout.compute`: the previous sync's
    /// placements, so a repeating rank conflict resolves the same way (and a
    /// session that lost one keeps its fallback slot) every time instead of
    /// churning when a source's `recency` value moves or the session set
    /// briefly flickers -- see `UnifiedLayout.compute`'s doc comment.
    private var previousUnifiedPlacements: [String: UnifiedLayout.PreviousSlot] = [:]
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
    private lazy var herdrCatalog = HerdrCatalog(herdrBinaryPath: herdrBinaryPath) { [weak self] level, message in
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
        isHookRegistered: { [weak self] sessionID in self?.claudeSessions[sessionID]?.sourceKind == .claudeDesktop },
        log: { [weak self] level, message in self?.logger.log(level, message) }
    )
    private lazy var providers: [SessionSourceProvider] = [
        CodexSourceProvider(), herdrCatalog, claudeSessionsCatalog, claudeDesktopCatalog,
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
    }
    private var claudeSessions: [String: ClaudeSessionRecord] = [:]
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
    /// Consecutive-sync streak of a herdr-reported idle/done status per
    /// session, used for hook-miss recovery (see `applyHerdrStatusHeuristics`).
    private var herdrStatusStreaks: [String: (status: AgentStatus, count: Int, since: Date)] = [:]

    init(
        socketPath: String,
        logURL: URL,
        locationID: Int?,
        grabberSocketPath: String,
        dryRun: Bool,
        herdrBinaryPath: String? = nil,
        claudeConfigDirs: [String]? = nil,
        claudeDesktopDir: String? = nil
    ) throws {
        guard geteuid() != 0 else {
            throw CLIError.runtime(
                "Refusing to run the user daemon as root. Install the helper once with sudo, then run c100-status without sudo."
            )
        }
        self.socketPath = socketPath
        self.locationID = locationID
        self.grabberSocketPath = grabberSocketPath
        self.dryRun = dryRun
        self.herdrBinaryPath = herdrBinaryPath
        self.claudeConfigDirs = claudeConfigDirs ?? ClaudeConfigDirs.resolved(additional: [])
        self.claudeDesktopDir = claudeDesktopDir ?? ClaudeDesktopCatalog.defaultSessionsDir()
        logger = try StatusLogger(fileURL: logURL)
    }

    func run() throws {
        defer { grabberLease?.release() }
        daemonStopRequested = 0
        Darwin.signal(SIGINT, requestDaemonStop)
        Darwin.signal(SIGTERM, requestDaemonStop)
        Darwin.signal(SIGPIPE, SIG_IGN)

        logger.log(.info, "daemon initializing pid=\(getpid()) dry_run=\(dryRun) euid=\(geteuid())")
        if dryRun {
            logger.log(.info, "HID writes and input capture are disabled")
        } else {
            try setupHardware()
        }
        let instanceLock = try DaemonInstanceLock(socketPath: socketPath)
        _ = instanceLock
        try stateStore.clear()
        try stateStore.discardLegacyEndedSessions()
        try applyAll(color: LEDColorName.off.color)
        syncCatalog()
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

            if grabberLease != nil, Date() >= nextGrabberHeartbeat {
                try renewGrabberLease()
            }
            if !dryRun {
                try pollMatrix()
            }
            servicePendingApprovals()
            if Date() >= nextCatalogSync {
                syncCatalog()
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
            case .ping:
                return DaemonResponse(ok: true, message: "daemon is running", status: nil)
            case .clear:
                try stateStore.clear()
                deferredHooks.removeAll()
                pendingApprovals.removeAll()
                try applyAll(color: LEDColorName.off.color)
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
            switch CodexApprovalRouting.displayRoute(for: hook) {
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
            if mutation.previousSlot == nil {
                try reconcileLEDs()
            } else {
                try apply(color: slot.status.color, at: slot.keyIndex)
            }
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
            endedClaudeSessions.record(sessionID: hook.sessionID)
            let mutation = try stateStore.update(
                sessionID: hook.sessionID,
                projectKey: hook.projectKey,
                status: nil,
                remove: true
            )
            logger.log(
                .info,
                "hook event=SessionEnd session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue) action=session_removed\(hookDiagnosticContext(hook))"
            )
            if mutation.changed {
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

        claudeSessions[hook.sessionID] = ClaudeSessionRecord(
            sourceKind: hook.effectiveSource,
            cwd: hook.projectKey,
            herdrWorkspaceID: hook.herdrWorkspaceID,
            navigation: claudeNavigationTarget(for: hook),
            configDir: hook.configDir ?? (NSHomeDirectory() + "/.claude"),
            lastSeen: Date()
        )

        guard let status = hook.status else {
            logger.log(
                .debug,
                "hook ignored event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue)"
            )
            return DaemonResponse(ok: true, message: "hook ignored", status: nil)
        }

        let projectKey = hook.projectKey
        if status == .approval {
            // Ensure the session already has a key before its approval
            // color is (debounced-)displayed, in case this is the very
            // first hook seen for it.
            _ = try stateStore.assignIfNeeded(sessionID: hook.sessionID, projectKey: projectKey)
            pendingApprovals.record(hook)
            logger.log(
                .info,
                "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) status=approval action=debounced route=user source=\(hook.effectiveSource.rawValue) delay_ms=\(Int(approvalDisplayDelay * 1_000))\(hookDiagnosticContext(hook))"
            )
            return DaemonResponse(ok: true, message: "user approval display deferred", status: nil)
        }

        let cancelledApproval = pendingApprovals.cancel(sessionID: hook.sessionID) != nil
        let mutation = try stateStore.update(sessionID: hook.sessionID, projectKey: projectKey, status: status)
        guard let slot = mutation.slot else {
            throw CLIError.runtime("Hook session was not assigned a C100 key")
        }
        logger.log(
            .info,
            "hook event=\(hook.hookEventName) session=\(shortSession(hook.sessionID)) source=\(hook.effectiveSource.rawValue) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=\(slot.status.rawValue) changed=\(mutation.changed)\(cancelledApproval ? " approval=resolved_before_display" : "")"
        )
        if mutation.changed {
            if mutation.previousSlot == nil {
                try reconcileLEDs()
            } else {
                try apply(color: slot.status.color, at: slot.keyIndex)
            }
        }
        return DaemonResponse(ok: true, message: "hook accepted on key \(slot.keyIndex)", status: slot.status)
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
                let mutation = try stateStore.update(
                    sessionID: entry.hook.sessionID,
                    projectKey: resolvedProjectKey(for: entry.hook),
                    status: .approval
                )
                guard let slot = mutation.slot else { continue }
                logger.log(
                    .info,
                    "hook event=PermissionRequest session=\(shortSession(entry.hook.sessionID)) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=approval action=waiting_for_user\(hookDiagnosticContext(entry.hook))"
                )
                guard mutation.changed else { continue }
                if mutation.previousSlot == nil {
                    try reconcileLEDs()
                } else {
                    try apply(color: slot.status.color, at: slot.keyIndex)
                }
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
            connection = try C100Connection.connect(locationID: locationID)
            logger.log(.info, "HID connected location=\(locationID.map { String(format: "0x%X", $0) } ?? "auto")")
        }
        do {
            try connection?.apply(status: status)
            logger.log(.info, "HID applied status=\(status.rawValue) persistence=volatile")
        } catch {
            connection = nil
            logger.log(.warning, "HID connection discarded after failure")
            throw error
        }
    }

    private func applyAssigned(status: AgentStatus) throws {
        let assignments = try stateStore.assignments()
        if dryRun {
            logger.log(.info, "HID skipped assigned_keys status=\(status.rawValue) assigned=\(assignments.count)")
            return
        }
        guard let connection else {
            throw CLIError.runtime("C100 vendor HID connection is unavailable")
        }
        let colors = Dictionary(
            uniqueKeysWithValues: assignments.map { ($0.slot.keyIndex, status.color) }
        )
        try connection.apply(colorsByIndex: colors, defaultColor: LEDColorName.off.color)
        logger.log(.info, "HID applied frame assigned=\(assignments.count) unassigned=\(100 - assignments.count) persistence=volatile")
    }

    private func reconcileLEDs() throws {
        let assignments = try stateStore.assignments()
        if dryRun {
            logger.log(.info, "HID skipped frame assigned=\(assignments.count) unassigned=\(100 - assignments.count)")
            return
        }
        guard let connection else {
            throw CLIError.runtime("C100 vendor HID connection is unavailable")
        }
        let colors = Dictionary(
            uniqueKeysWithValues: assignments.map { ($0.slot.keyIndex, $0.slot.status.color) }
        )
        try connection.apply(colorsByIndex: colors, defaultColor: LEDColorName.off.color)
        logger.log(.info, "HID applied frame assigned=\(assignments.count) unassigned=\(100 - assignments.count) persistence=volatile")
    }

    private func apply(color: HSVColor, at index: Int) throws {
        if dryRun {
            logger.log(.info, "HID skipped key=\(index) hsv=\(color.hue),\(color.saturation),\(color.value)")
            return
        }
        if connection == nil {
            connection = try C100Connection.connect(locationID: locationID)
            logger.log(.info, "HID connected location=\(locationID.map { String(format: "0x%X", $0) } ?? "auto")")
        }
        do {
            try connection?.apply(color: color, at: index)
            logger.log(.info, "HID applied key=\(index) persistence=volatile")
        } catch {
            connection = nil
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
        logger.log(.info, "HID applied all_keys persistence=volatile")
    }

    private func setupHardware() throws {
        let connection = try C100Connection.connect(locationID: locationID)
        self.connection = connection
        let actualLocation = connection.locationID
        logger.log(.info, "HID connected location=\(String(format: "0x%X", actualLocation))")

        protocolVersion = try connection.protocolVersion()
        pressedKeyIndexes = try connection.pressedKeyIndexes(protocolVersion: protocolVersion)
        logger.log(.info, "matrix polling=enabled protocol=\(protocolVersion) layout=10x10 interval_ms=10")

        let lease = GrabberLeaseClient(socketPath: grabberSocketPath, locationID: actualLocation)
        do {
            try lease.acquire()
            grabberLease = lease
            nextGrabberHeartbeat = Date().addingTimeInterval(1)
            logger.log(.info, "input capture=privileged_helper lease=active normal_keystrokes=suppressed")
        } catch {
            self.connection = nil
            throw CLIError.runtime(
                "Privileged C100 grabber is unavailable at \(grabberSocketPath). "
                    + "Install it once with `sudo c100-status install-helper --location \(String(format: "0x%X", actualLocation))`; error: \(error)"
            )
        }
    }

    private func renewGrabberLease() throws {
        guard let grabberLease else { return }
        do {
            try grabberLease.heartbeat()
            nextGrabberHeartbeat = Date().addingTimeInterval(1)
        } catch {
            logger.log(.error, "privileged grabber lease lost error=\(error)")
            throw error
        }
    }

    private func pollMatrix() throws {
        guard let connection else {
            throw CLIError.runtime("C100 vendor HID connection is unavailable during matrix polling")
        }
        let current = try connection.pressedKeyIndexes(protocolVersion: protocolVersion)
        let newlyPressed = current.subtracting(pressedKeyIndexes)
        pressedKeyIndexes = current
        for keyIndex in newlyPressed.sorted() {
            handleKeyPress(keyIndex: keyIndex)
        }
    }

    private func handleKeyPress(keyIndex: Int) {
        do {
            guard let assignment = try stateStore.assignment(at: keyIndex) else {
                logger.log(.debug, "input key=\(keyIndex) row=\(keyIndex / 10) col=\(keyIndex % 10) action=ignored_unassigned")
                return
            }
            logger.log(
                .info,
                "input key=\(keyIndex) row=\(keyIndex / 10) col=\(keyIndex % 10) session=\(shortSession(assignment.sessionID))"
            )
            // Claude sessions carry their own resolved NavigationTarget
            // (herdr pane / Ghostty tab / Claude Desktop) recorded from their
            // hooks; anything else (Codex, or a Claude session the daemon
            // hasn't seen a hook for yet) falls back to Codex-thread
            // navigation, matching pre-M1 behavior.
            let target = claudeSessions[assignment.sessionID]?.navigation
                ?? herdrNavigationBySession[assignment.sessionID]
                ?? .codexThread(sessionID: assignment.sessionID)
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
                status: .idle
            )
            guard let slot = mutation.slot else { return }
            try apply(color: slot.status.color, at: slot.keyIndex)
            logger.log(
                .info,
                "input key=\(keyIndex) session=\(shortSession(assignment.sessionID)) action=acknowledge_done status=idle"
            )
        } catch {
            logger.log(.error, "input key=\(keyIndex) state_lookup_failed error=\(error)")
        }
    }

    private func syncCatalog() {
        nextCatalogSync = Date().addingTimeInterval(2)
        pruneEndedClaudeSessions()
        do {
            // Codex-authoritative view: approval routing, deferred-hook
            // promotion, and turn-abort monitoring below remain gated to Codex
            // (sourceKind == .codex) and read this directly rather than going
            // through the generic AgentSession abstraction, since they need
            // Codex-only fields (rollout paths, createdAt) that the unified
            // model does not carry.
            let codexLayout = try CodexCatalog.layout()
            let catalogSessions = codexLayout.placements.map(\.session)
            let nextCatalogSessionIDs = Set(catalogSessions.map(\.sessionID))
            catalogProjectBySession = Dictionary(
                uniqueKeysWithValues: catalogSessions.map { ($0.sessionID, $0.projectKey) }
            )
            catalogProjectByCWD = Dictionary(
                catalogSessions.map { (URL(fileURLWithPath: $0.cwd).standardizedFileURL.path, $0.projectKey) },
                uniquingKeysWith: { first, _ in first }
            )

            var agentSessions: [AgentSession] = []
            for provider in providers {
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
                herdrStatusStreaks.removeValue(forKey: sessionID)
                endedClaudeSessions.record(sessionID: sessionID)
                let mutation = try stateStore.update(
                    sessionID: sessionID,
                    projectKey: "(herdr-pane-closed)",
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
                endedClaudeSessions.record(sessionID: sessionID)
                let mutation = try stateStore.update(
                    sessionID: sessionID,
                    projectKey: "(claude-terminal-ended)",
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
                endedClaudeSessions.record(sessionID: sessionID)
                let mutation = try stateStore.update(
                    sessionID: sessionID,
                    projectKey: "(claude-desktop-ended)",
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
            let unified = UnifiedLayout.compute(sessions: agentSessions, previousPlacements: previousUnifiedPlacements)
            let currentCatalogWarnings = Set(unified.warnings)
            for warning in currentCatalogWarnings.subtracting(previousCatalogWarnings) {
                logger.log(.warning, "catalog layout warning=\(warning)")
            }
            previousCatalogWarnings = currentCatalogWarnings
            previousUnifiedPlacements = Dictionary(uniqueKeysWithValues: unified.placements.map {
                ($0.session.sessionID, UnifiedLayout.PreviousSlot(row: $0.row, column: $0.column))
            })
            let sessions = catalogSessions

            let reconciliation = try stateStore.reconcile(
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
            let herdrStatusChanged = try applyHerdrStatusHeuristics(
                herdrAgentSessions: herdrAgentSessions,
                reconciliation: reconciliation
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
                    switch CodexApprovalRouting.displayRoute(for: entry.hook) {
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
            let interruptedSessionIDs = turnMonitor.interruptedSessionIDs(in: sessions)
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
                    status: .idle
                )
                guard let updated = mutation.slot, mutation.changed else { continue }
                interruptionChanged = true
                logger.log(
                    .info,
                    "catalog session=\(shortSession(sessionID)) event=turn_aborted row=\(updated.row) col=\(updated.column) key=\(updated.keyIndex) status=idle action=interrupted"
                )
            }

            if reconciliation.changed {
                let previousIDs = Set(reconciliation.previous.sessions.keys)
                let currentIDs = Set(reconciliation.current.sessions.keys)
                for sessionID in previousIDs.subtracting(currentIDs) {
                    guard let slot = reconciliation.previous.sessions[sessionID] else { continue }
                    logger.log(
                        .info,
                        "catalog session=\(shortSession(sessionID)) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) action=released"
                    )
                }
                for sessionID in currentIDs {
                    guard let slot = reconciliation.current.sessions[sessionID] else { continue }
                    let previous = reconciliation.previous.sessions[sessionID]
                    guard previous != slot else { continue }
                    let action = previous == nil ? "assigned" : "moved"
                    logger.log(
                        .info,
                        "catalog session=\(shortSession(sessionID)) project=\(slot.projectKey) row=\(slot.row) col=\(slot.column) key=\(slot.keyIndex) status=\(slot.status.rawValue) action=\(action)"
                    )
                }
                logger.log(
                    .info,
                    "catalog sync projects=\(unified.projectRows.count) sessions=\(unified.placements.count) layout=updated"
                )
            }
            if reconciliation.changed || deferredChanged || interruptionChanged || herdrRemovalChanged || herdrStatusChanged
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
            endedClaudeSessions.record(sessionID: sessionID)
            let mutation = try stateStore.update(
                sessionID: sessionID,
                projectKey: "(claude-transcript-stale)",
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
    /// or (b) to recover from a missed hook: if herdr reports idle/done for
    /// two consecutive syncs *and* the last hook seen for that session
    /// predates that streak, the hook is presumed lost and herdr's status
    /// wins. In every other case the hook remains authoritative (this
    /// function never touches a session's status while its hook activity is
    /// current).
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

        for (sessionID, streak) in herdrStatusStreaks where streak.count >= 2 {
            guard let hookLastSeen = claudeSessions[sessionID]?.lastSeen, hookLastSeen < streak.since else { continue }
            guard let currentSlot = reconciliation.current.sessions[sessionID], currentSlot.status != streak.status else { continue }
            let mutation = try stateStore.update(
                sessionID: sessionID,
                projectKey: currentSlot.projectKey,
                status: streak.status
            )
            if mutation.changed {
                changed = true
                logger.log(
                    .info,
                    "herdr session=\(shortSession(sessionID)) action=hook_miss_recovered status=\(streak.status.rawValue) streak=\(streak.count)"
                )
            }
        }

        return changed
    }

    private func resolvedProjectKey(for hook: HookInput) -> String {
        guard hook.effectiveSource == .codex else { return hook.projectKey }
        return catalogProjectBySession[hook.sessionID]
            ?? catalogProjectByCWD[hook.projectKey]
            ?? CodexCatalog.projectKey(sessionID: hook.sessionID)
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
