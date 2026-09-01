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
    private var deferredHooks = DeferredHookBuffer()
    private let deferredHookMaxAge: TimeInterval = 6
    private var pendingApprovals = PendingApprovalBuffer()
    private let approvalDisplayDelay: TimeInterval = 0.5
    private let turnMonitor = CodexTurnMonitor()
    private lazy var navigator = CodexNavigator { [weak self] level, message in
        self?.logger.log(level, message)
    }
    private lazy var navigationRouter = NavigationRouter(codexNavigator: navigator)
    private let providers: [SessionSourceProvider] = [CodexSourceProvider()]

    init(socketPath: String, logURL: URL, locationID: Int?, grabberSocketPath: String, dryRun: Bool) throws {
        guard geteuid() != 0 else {
            throw CLIError.runtime(
                "Refusing to run the user daemon as root. Install the helper once with sudo, then run c100-status without sudo."
            )
        }
        self.socketPath = socketPath
        self.locationID = locationID
        self.grabberSocketPath = grabberSocketPath
        self.dryRun = dryRun
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

    private func servicePendingApprovals() {
        let due = pendingApprovals.due(delay: approvalDisplayDelay)
        guard !due.isEmpty else { return }
        for entry in due {
            do {
                guard catalogSessionIDs.contains(entry.hook.sessionID) else {
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
            // Only Codex is wired up as a session source in M0, so every stored
            // slot navigates as a Codex thread. Once StateStore/SessionSlot carry
            // a per-session NavigationTarget (M1+), this will be read from there.
            let navigated = navigationRouter.handleTap(
                keyIndex: keyIndex,
                sessionID: assignment.sessionID,
                target: .codexThread(sessionID: assignment.sessionID)
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
            let unified = UnifiedLayout.compute(sessions: agentSessions)
            for warning in unified.warnings {
                logger.log(.warning, "catalog layout warning=\(warning)")
            }
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
            if reconciliation.changed || deferredChanged || interruptionChanged {
                try reconcileLEDs()
            }
        } catch {
            logger.log(.warning, "catalog sync failed error=\(error)")
        }
    }

    private func resolvedProjectKey(for hook: HookInput) -> String {
        catalogProjectBySession[hook.sessionID]
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
