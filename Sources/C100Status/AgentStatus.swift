import Foundation

enum AgentStatus: String, Codable, CaseIterable {
    case idle
    case working
    case approval
    case done
    case error

    var priority: Int {
        switch self {
        case .idle: 0
        case .done: 1
        case .error: 2
        case .working: 3
        case .approval: 4
        }
    }

    var color: HSVColor {
        switch self {
        case .idle: HSVColor(hue: 0, saturation: 0, value: 24)
        case .working: HSVColor(hue: 168, saturation: 255, value: 112)
        case .approval: HSVColor(hue: 21, saturation: 255, value: 160)
        case .done: HSVColor(hue: 85, saturation: 255, value: 112)
        case .error: HSVColor(hue: 0, saturation: 255, value: 144)
        }
    }
}

struct HookInput: Codable {
    let sessionID: String
    let hookEventName: String
    let cwd: String?
    let turnID: String?
    let agentID: String?
    let agentType: String?
    let transcriptPath: String?
    let permissionMode: String?
    let toolName: String?
    /// Which product produced this hook. `nil` on the wire means a
    /// pre-M1 Codex hook payload (back-compat) -- see `effectiveSource`.
    let source: SessionSourceKind?
    let herdrPaneID: String?
    let herdrWorkspaceID: String?
    let configDir: String?
    /// Only populated for `Notification` events; distinguishes the four
    /// Claude Code notification matchers (`permission_prompt`,
    /// `idle_prompt`, `agent_needs_input`, `agent_completed`).
    let notificationMatcher: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case turnID = "turn_id"
        case agentID = "agent_id"
        case agentType = "agent_type"
        case transcriptPath = "transcript_path"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case source
        case herdrPaneID = "herdr_pane_id"
        case herdrWorkspaceID = "herdr_workspace_id"
        case configDir = "config_dir"
        case notificationMatcher = "notification_matcher"
    }

    /// Resolves the wire-optional `source` back to a concrete kind: missing
    /// `source` (every hook emitted before M1) is a Codex hook.
    var effectiveSource: SessionSourceKind { source ?? .codex }

    /// Claude subagent hooks (`agent_id` present, or a `/subagents/`
    /// transcript path) are excluded from the grid entirely -- only the
    /// top-level session is tracked. Codex's own `agent_id` semantics
    /// (executor turns) are untouched since this is only consulted on the
    /// Claude path.
    ///
    /// `SubagentStart`/`SubagentStop` are a deliberate exception (M6): per
    /// Claude Code's hooks reference, these fire with the *parent* session's
    /// `session_id` plus an `agent_id` identifying the subagent that just
    /// started/stopped -- i.e. exactly the shape this check would otherwise
    /// classify as "a subagent's own hook call" and drop. They need to reach
    /// `Daemon` (to drive the working-while-a-subagent-runs override), so
    /// they're carved out here rather than only at the `Daemon` call site,
    /// keeping this predicate the single source of truth for "is this hook
    /// call ignorable".
    var isSubagent: Bool {
        guard !isSubagentLifecycleEvent else { return false }
        return agentID != nil || (transcriptPath?.contains("/subagents/") ?? false)
    }

    /// `true` for the two hook events that report a subagent's own
    /// lifecycle (as opposed to firing *because* the hook happens to run
    /// inside a subagent, which is what `isSubagent` guards against).
    var isSubagentLifecycleEvent: Bool {
        hookEventName == "SubagentStart" || hookEventName == "SubagentStop"
    }

    var projectKey: String {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return "(unknown)"
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    var status: AgentStatus? {
        guard effectiveSource == .codex else { return claudeStatus }
        switch hookEventName {
        case "SessionStart", "SessionEnd": return .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .working
        case "PermissionRequest": return .approval
        case "Stop": return .done
        default: return nil
        }
    }

    /// Claude Code event -> LED status mapping (M1). `SessionEnd` is
    /// intentionally excluded here (returns `nil`): unlike Codex, Claude is
    /// hook-authoritative, so `SessionEnd` removes the session outright
    /// rather than setting a status -- `Daemon` handles that via
    /// `endsSession` before ever consulting `status`.
    private var claudeStatus: AgentStatus? {
        switch hookEventName {
        case "SessionStart": return .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .working
        case "PermissionRequest": return .approval
        case "Notification":
            switch notificationMatcher {
            case "permission_prompt", "agent_needs_input": return .approval
            case "idle_prompt": return .idle
            case "agent_completed": return .done
            default: return nil
            }
        case "Stop": return .done
        case "StopFailure": return .error
        // M6: recognized events, but they never carry a status of their own
        // -- they're pure count-operation signals for `Daemon`'s
        // `activeSubagents` bookkeeping (see `handleSubagentLifecycle`),
        // which then decides whether to override the session's already-
        // mapped status with `.working`.
        case "SubagentStart", "SubagentStop": return nil
        default: return nil
        }
    }

    var endsSession: Bool { hookEventName == "SessionEnd" }
    var requestsPermission: Bool { hookEventName == "PermissionRequest" }
    var beginsToolUse: Bool { hookEventName == "PreToolUse" }
    var directlyRequestsUserPermission: Bool {
        requestsPermission && toolName == "request_permissions"
    }

    /// Returns a copy of this hook with the Claude source-identification
    /// fields attached. Used by `c100-status hook --source claude` after it
    /// resolves the source kind from the process environment; leaves every
    /// other field untouched.
    func applyingSource(
        _ source: SessionSourceKind,
        herdrPaneID: String?,
        herdrWorkspaceID: String?,
        configDir: String?,
        notificationMatcher: String?
    ) -> HookInput {
        HookInput(
            sessionID: sessionID,
            hookEventName: hookEventName,
            cwd: cwd,
            turnID: turnID,
            agentID: agentID,
            agentType: agentType,
            transcriptPath: transcriptPath,
            permissionMode: permissionMode,
            toolName: toolName,
            source: source,
            herdrPaneID: herdrPaneID,
            herdrWorkspaceID: herdrWorkspaceID,
            configDir: configDir,
            notificationMatcher: notificationMatcher
        )
    }

    /// Returns a copy with only `notificationMatcher` changed. Used when
    /// `--notification-matcher` is passed without `--source claude` (e.g.
    /// tests, or a future non-Claude source that also has notifications).
    func applyingNotificationMatcher(_ notificationMatcher: String?) -> HookInput {
        HookInput(
            sessionID: sessionID,
            hookEventName: hookEventName,
            cwd: cwd,
            turnID: turnID,
            agentID: agentID,
            agentType: agentType,
            transcriptPath: transcriptPath,
            permissionMode: permissionMode,
            toolName: toolName,
            source: source,
            herdrPaneID: herdrPaneID,
            herdrWorkspaceID: herdrWorkspaceID,
            configDir: configDir,
            notificationMatcher: notificationMatcher
        )
    }
}

struct PendingApproval {
    let hook: HookInput
    let receivedAt: Date
}

struct PendingApprovalBuffer {
    private(set) var entriesBySessionID: [String: PendingApproval] = [:]

    var count: Int { entriesBySessionID.count }

    mutating func record(_ hook: HookInput, at date: Date = Date()) {
        entriesBySessionID[hook.sessionID] = PendingApproval(hook: hook, receivedAt: date)
    }

    @discardableResult
    mutating func cancel(sessionID: String) -> PendingApproval? {
        entriesBySessionID.removeValue(forKey: sessionID)
    }

    mutating func removeAll() {
        entriesBySessionID.removeAll()
    }

    mutating func due(now: Date = Date(), delay: TimeInterval) -> [PendingApproval] {
        var result: [PendingApproval] = []
        for sessionID in entriesBySessionID.keys.sorted() {
            guard let entry = entriesBySessionID[sessionID],
                  now.timeIntervalSince(entry.receivedAt) >= delay else { continue }
            result.append(entry)
            entriesBySessionID.removeValue(forKey: sessionID)
        }
        return result
    }
}

struct DeferredHook {
    let hook: HookInput
    let status: AgentStatus
    let receivedAt: Date
}

struct DeferredHookDrain {
    let promoted: [DeferredHook]
    let expired: [DeferredHook]
}

struct DeferredHookBuffer {
    private(set) var entriesBySessionID: [String: DeferredHook] = [:]

    var count: Int { entriesBySessionID.count }

    mutating func record(_ hook: HookInput, status: AgentStatus, at date: Date = Date()) {
        entriesBySessionID[hook.sessionID] = DeferredHook(
            hook: hook,
            status: status,
            receivedAt: date
        )
    }

    mutating func remove(sessionID: String) {
        entriesBySessionID.removeValue(forKey: sessionID)
    }

    mutating func removeAll() {
        entriesBySessionID.removeAll()
    }

    mutating func drain(
        catalogSessionIDs: Set<String>,
        now: Date = Date(),
        maxAge: TimeInterval
    ) -> DeferredHookDrain {
        var promoted: [DeferredHook] = []
        var expired: [DeferredHook] = []
        for sessionID in entriesBySessionID.keys.sorted() {
            guard let entry = entriesBySessionID[sessionID] else { continue }
            if now.timeIntervalSince(entry.receivedAt) >= maxAge {
                expired.append(entry)
                entriesBySessionID.removeValue(forKey: sessionID)
            } else if catalogSessionIDs.contains(sessionID) {
                promoted.append(entry)
                entriesBySessionID.removeValue(forKey: sessionID)
            }
        }
        return DeferredHookDrain(promoted: promoted, expired: expired)
    }
}

/// Tracks recently-ended Claude sessions so a reordered/late hook (e.g. an
/// async `PostToolUse` that lands after `SessionEnd`) doesn't resurrect a
/// session the daemon has already torn down. Entries age out after `ttl`
/// seconds -- there is no unbounded growth since every lookup path also
/// prunes.
struct ClaudeSessionEndTombstoneBuffer {
    private(set) var endedAtBySessionID: [String: Date] = [:]

    var count: Int { endedAtBySessionID.count }

    mutating func record(sessionID: String, at date: Date = Date()) {
        endedAtBySessionID[sessionID] = date
    }

    func isTombstoned(sessionID: String, now: Date = Date(), ttl: TimeInterval) -> Bool {
        guard let endedAt = endedAtBySessionID[sessionID] else { return false }
        return now.timeIntervalSince(endedAt) < ttl
    }

    mutating func prune(now: Date = Date(), ttl: TimeInterval) {
        guard !endedAtBySessionID.isEmpty else { return }
        endedAtBySessionID = endedAtBySessionID.filter { now.timeIntervalSince($0.value) < ttl }
    }
}

/// M6: tracks Claude subagents currently running, grouped by their parent
/// session id, purely to drive the "keep the session's key showing working
/// while at least one of its subagents is still running" LED override --
/// see `StatusDaemon.refreshSubagentOverride`. Extracted as its own struct
/// (mirroring `DeferredHookBuffer`/`PendingApprovalBuffer`/
/// `ClaudeSessionEndTombstoneBuffer` above) so the increment/decrement/TTL
/// bookkeeping is unit-testable independent of `StatusDaemon`'s socket/HID
/// plumbing.
struct ActiveSubagentTracker {
    /// sessionID -> (agentID or synthetic fallback key) -> when its
    /// `SubagentStart` was recorded.
    private(set) var startedAtByAgentID: [String: [String: Date]] = [:]
    /// Per-session stack of synthetic keys minted for `SubagentStart` calls
    /// that arrived without an `agent_id` -- see `start`/`stop`.
    private var fallbackStackBySession: [String: [String]] = [:]

    /// Every session id with at least one tracked subagent right now.
    var activeSessionIDs: Set<String> { Set(startedAtByAgentID.keys) }

    /// `true` while `sessionID` has at least one tracked subagent running.
    func isActive(sessionID: String) -> Bool {
        !(startedAtByAgentID[sessionID]?.isEmpty ?? true)
    }

    func count(sessionID: String) -> Int {
        startedAtByAgentID[sessionID]?.count ?? 0
    }

    /// Records a `SubagentStart`. `agentID` should always be present per
    /// Claude Code's hooks reference, but a missing one is tolerated: a
    /// synthetic per-call key is minted and pushed onto a LIFO fallback
    /// stack so a same-session `SubagentStop` that also lacks `agent_id`
    /// can still be matched back to it (see `stop`).
    mutating func start(sessionID: String, agentID: String?, at date: Date = Date()) {
        let key = agentID ?? "fallback-\(UUID().uuidString)"
        startedAtByAgentID[sessionID, default: [:]][key] = date
        if agentID == nil {
            fallbackStackBySession[sessionID, default: []].append(key)
        }
    }

    /// Records a `SubagentStop`. Matches by `agentID` when present;
    /// otherwise pops the most recently pushed no-id fallback key for this
    /// session, and failing that (a same-session `SubagentStart` that *did*
    /// have an `agent_id`, unexpected but not contractually ruled out)
    /// drops whichever tracked entry has been running longest, so the count
    /// never gets stuck inflated by a `SubagentStop` this tracker can't
    /// otherwise attribute.
    mutating func stop(sessionID: String, agentID: String?) {
        if let agentID {
            startedAtByAgentID[sessionID]?.removeValue(forKey: agentID)
        } else if var stack = fallbackStackBySession[sessionID], let popped = stack.popLast() {
            fallbackStackBySession[sessionID] = stack
            startedAtByAgentID[sessionID]?.removeValue(forKey: popped)
        } else if let oldestKey = startedAtByAgentID[sessionID]?.min(by: { $0.value < $1.value })?.key {
            startedAtByAgentID[sessionID]?.removeValue(forKey: oldestKey)
        }
        if startedAtByAgentID[sessionID]?.isEmpty ?? false {
            clear(sessionID: sessionID)
        }
    }

    /// Drops every tracked subagent for `sessionID` outright -- used when
    /// the session itself is torn down (`SessionEnd`, any cross-source GC)
    /// so a leftover entry can't resurrect an override once the session id
    /// is reused.
    mutating func clear(sessionID: String) {
        startedAtByAgentID.removeValue(forKey: sessionID)
        fallbackStackBySession.removeValue(forKey: sessionID)
    }

    mutating func clearAll() {
        startedAtByAgentID.removeAll()
        fallbackStackBySession.removeAll()
    }

    /// Take-over-if-lost TTL sweep: drops any tracked subagent whose
    /// `SubagentStart` is older than `ttl` (a `SubagentStop` that never
    /// arrived -- crashed process, dropped async hook, ...). Returns the
    /// session ids whose active count changed (including dropping to zero)
    /// so the caller knows which sessions' displayed status needs
    /// re-deriving.
    @discardableResult
    mutating func pruneExpired(now: Date = Date(), ttl: TimeInterval) -> Set<String> {
        var changedSessionIDs: Set<String> = []
        for sessionID in Array(startedAtByAgentID.keys) {
            guard let perAgent = startedAtByAgentID[sessionID] else { continue }
            let survivors = perAgent.filter { now.timeIntervalSince($0.value) < ttl }
            guard survivors.count != perAgent.count else { continue }
            changedSessionIDs.insert(sessionID)
            if survivors.isEmpty {
                clear(sessionID: sessionID)
            } else {
                startedAtByAgentID[sessionID] = survivors
                fallbackStackBySession[sessionID] = fallbackStackBySession[sessionID]?.filter { survivors[$0] != nil }
            }
        }
        return changedSessionIDs
    }
}

enum LEDColorName: String, CaseIterable {
    case off
    case white
    case red
    case green
    case blue
    case amber

    var color: HSVColor {
        switch self {
        case .off: HSVColor(hue: 0, saturation: 0, value: 0)
        case .white: HSVColor(hue: 0, saturation: 0, value: 112)
        case .red: AgentStatus.error.color
        case .green: AgentStatus.done.color
        case .blue: AgentStatus.working.color
        case .amber: AgentStatus.approval.color
        }
    }
}
