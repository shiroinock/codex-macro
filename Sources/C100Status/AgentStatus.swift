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
    }

    var projectKey: String {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return "(unknown)"
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    var status: AgentStatus? {
        switch hookEventName {
        case "SessionStart", "SessionEnd": .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": .working
        case "PermissionRequest": .approval
        case "Stop": .done
        default: nil
        }
    }

    var endsSession: Bool { hookEventName == "SessionEnd" }
    var requestsPermission: Bool { hookEventName == "PermissionRequest" }
    var beginsToolUse: Bool { hookEventName == "PreToolUse" }
    var directlyRequestsUserPermission: Bool {
        requestsPermission && toolName == "request_permissions"
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
