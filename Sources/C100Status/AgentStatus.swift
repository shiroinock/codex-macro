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
    var isSubagent: Bool {
        agentID != nil || (transcriptPath?.contains("/subagents/") ?? false)
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
