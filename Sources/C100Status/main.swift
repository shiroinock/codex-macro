import Darwin
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case runtime(String)

    var description: String {
        switch self {
        case .usage(let message), .runtime(let message): message
        }
    }
}

struct Options {
    var dryRun = false
    var locationID: Int?
    var socketPath = RuntimePaths.socket()
    var logPath = RuntimePaths.log()
    var grabberSocketPath = RuntimePaths.grabberSocket()
    var ownerUID: uid_t?
    var ownerGID: gid_t?
    var hookSource = "codex"
    var notificationMatcher: String?
    var herdrBinaryPath: String?
    var claudeConfigDirs: [String] = []
    var claudeDesktopDir: String?
    var installClaudeHooksConfigDirs: [String] = []
    var installClaudeHooksBinaryPath: String?
    var uninstallClaudeHooks = false
}

enum C100StatusCLI {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        let (positionals, options) = try parseOptions(Array(arguments.dropFirst()))
        switch command {
        case "run":
            let daemon = try StatusDaemon(
                socketPath: options.socketPath,
                logURL: URL(fileURLWithPath: options.logPath),
                locationID: options.locationID,
                grabberSocketPath: options.grabberSocketPath,
                dryRun: options.dryRun,
                herdrBinaryPath: options.herdrBinaryPath,
                claudeConfigDirs: ClaudeConfigDirs.resolved(additional: options.claudeConfigDirs),
                claudeDesktopDir: options.claudeDesktopDir
            )
            try daemon.run()
        case "grabber-service":
            guard let ownerUID = options.ownerUID,
                  let ownerGID = options.ownerGID,
                  let locationID = options.locationID else {
                throw CLIError.usage("grabber-service requires --owner-uid, --owner-gid, and --location")
            }
            let service = PrivilegedGrabberService(
                socketPath: options.grabberSocketPath,
                ownerUID: ownerUID,
                ownerGID: ownerGID,
                allowedLocationID: locationID
            )
            try service.run()
        case "install-helper":
            guard let locationID = options.locationID else {
                throw CLIError.usage("install-helper requires --location")
            }
            let ownerUID = options.ownerUID ?? RuntimePaths.ownerUID
            let ownerGID = options.ownerGID ?? RuntimePaths.ownerGID
            try HelperInstaller.install(
                sourceExecutable: HelperInstaller.currentExecutableURL(),
                ownerUID: ownerUID,
                ownerGID: ownerGID,
                locationID: locationID
            )
            print("helper=installed label=\(HelperInstaller.label) owner_uid=\(ownerUID) location=0x\(hex(locationID, width: 6))")
            print("c100-status run can now start without sudo")
        case "uninstall-helper":
            try HelperInstaller.uninstall()
            print("helper=uninstalled label=\(HelperInstaller.label)")
        case "grabber-status":
            let response = try UnixSocketServer.send(
                GrabberRequest.ping,
                path: options.grabberSocketPath,
                response: GrabberResponse.self
            )
            try requireGrabberSuccess(response)
            print("\(response.message) capturing=\(response.capturing)")
        case "list":
            let descriptors = try C100Connection.descriptors()
            guard !descriptors.isEmpty else {
                throw CLIError.runtime("Keychron C100 8K vendor HID was not found")
            }
            for descriptor in descriptors {
                print("\(descriptor.product) vid=0x\(hex(descriptor.vendorID, width: 4)) pid=0x\(hex(descriptor.productID, width: 4)) location=0x\(hex(descriptor.locationID, width: 6)) registry=0x\(String(descriptor.registryEntryID, radix: 16))")
            }
        case "catalog":
            let layout = try CodexCatalog.layout()
            for (project, row) in layout.projectRows.sorted(by: { $0.value < $1.value }) {
                print("row=\(row) project=\(project)")
                for placement in layout.placements.filter({ $0.row == row }) {
                    let session = placement.session
                    print("  key=\(placement.keyIndex) col=\(placement.column) session=\(session.sessionID) cwd=\(session.cwd)")
                }
            }
            if let herdrBinary = HerdrBinaryResolver.resolve(explicitPath: options.herdrBinaryPath) {
                do {
                    let herdrSessions = try HerdrCatalog.fetchOnce(binary: herdrBinary)
                    print("herdr sessions (binary=\(herdrBinary)):")
                    for entry in herdrSessions.sorted(by: { $0.workspaceNumber < $1.workspaceNumber }) {
                        print(
                            "  workspace=\(entry.workspaceNumber) pane=\(entry.paneID) session=\(entry.sessionID) status=\(entry.seedStatus.rawValue) cwd=\(entry.cwd)"
                        )
                    }
                    if herdrSessions.isEmpty {
                        print("  (no claude agents reported by herdr)")
                    }
                } catch {
                    print("herdr sessions: unavailable (\(error))")
                }
            } else {
                print("herdr sessions: herdr binary not found (--herdr-bin / HERDR_BIN / PATH)")
            }
            let claudeConfigDirs = ClaudeConfigDirs.resolved(additional: options.claudeConfigDirs)
            let claudeTerminalSessions = try ClaudeSessionsCatalog(configDirs: claudeConfigDirs).snapshot()
            print("claude-terminal sessions (config_dirs=\(claudeConfigDirs.joined(separator: ","))):")
            for session in claudeTerminalSessions.sorted(by: { $0.sessionID < $1.sessionID }) {
                print("  session=\(session.sessionID) cwd=\(session.cwd)")
            }
            if claudeTerminalSessions.isEmpty {
                print("  (no live claude sessions/<pid>.json found)")
            }
            let claudeDesktopDir = options.claudeDesktopDir ?? ClaudeDesktopCatalog.defaultSessionsDir()
            let claudeDesktopSessions = try ClaudeDesktopCatalog(desktopSessionsDir: claudeDesktopDir).snapshot()
            print("claude-desktop sessions (dir=\(claudeDesktopDir)):")
            for session in claudeDesktopSessions.sorted(by: { $0.sessionID < $1.sessionID }) {
                print("  session=\(session.sessionID) cwd=\(session.cwd)")
            }
            if claudeDesktopSessions.isEmpty {
                print("  (no live Claude Desktop sessions found -- either Desktop isn't running, or every local_*.json is archived/stale)")
            }
        case "request-input-access":
            let before = C100InputCapture.accessDescription
            let granted = C100InputCapture.requestAccess()
            let after = C100InputCapture.accessDescription
            print("input-monitoring before=\(before) request-returned=\(granted) after=\(after)")
            if after != "granted" {
                print("Enable c100-status (or its launching terminal app) in System Settings > Privacy & Security > Input Monitoring, then restart run.")
            }
        case "watch-input":
            let seconds = positionals.first.flatMap(Double.init) ?? 20
            guard seconds > 0 && seconds <= 300 else {
                throw CLIError.usage("watch-input seconds must be between 1 and 300")
            }
            let connection = try C100Connection.connect(locationID: options.locationID)
            print("watching C100 vendor HID reports for \(seconds) seconds; press C100 keys now")
            connection.watchReports(seconds: seconds)
        case "watch-matrix":
            let seconds = positionals.first.flatMap(Double.init) ?? 20
            guard seconds > 0 && seconds <= 300 else {
                throw CLIError.usage("watch-matrix seconds must be between 1 and 300")
            }
            let connection = try C100Connection.connect(locationID: options.locationID)
            print("polling C100 10x10 matrix for \(seconds) seconds; press C100 keys now")
            try connection.watchMatrix(seconds: seconds)
        case "status":
            guard let value = positionals.first, let status = AgentStatus(rawValue: value) else {
                throw CLIError.usage("status requires one of: \(AgentStatus.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let response = try send(.manual(status), options: options)
            try requireSuccess(response)
            print("status=\(response.status?.rawValue ?? status.rawValue) daemon=accepted")
        case "key":
            guard positionals.count == 2,
                  let index = parseInteger(positionals[0]),
                  (0..<100).contains(index),
                  let color = LEDColorName(rawValue: positionals[1]) else {
                throw CLIError.usage(
                    "key requires an index from 0 to 99 and one of: \(LEDColorName.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            let response = try send(.key(index: index, color: color.color), options: options)
            try requireSuccess(response)
            print("key=\(index) color=\(color.rawValue) daemon=accepted")
        case "apply":
            guard let value = positionals.first, let status = AgentStatus(rawValue: value) else {
                throw CLIError.usage("apply requires one of: \(AgentStatus.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            if options.dryRun {
                let color = status.color
                print("status=\(status.rawValue) hsv=\(color.hue),\(color.saturation),\(color.value) device-write=skipped")
            } else {
                try OperationLock().withLock {
                    let connection = try C100Connection.connect(locationID: options.locationID)
                    try connection.apply(status: status)
                }
                print("status=\(status.rawValue) applied-directly persistence=volatile")
            }
        case "install-claude-hooks":
            let configDirs = options.installClaudeHooksConfigDirs.isEmpty
                ? ClaudeHooksInstaller.defaultInstallConfigDirs()
                : options.installClaudeHooksConfigDirs
            let binaryPath = options.installClaudeHooksBinaryPath ?? HelperInstaller.currentExecutableURL().path
            let results = ClaudeHooksInstaller.run(
                configDirs: configDirs,
                binaryPath: binaryPath,
                dryRun: options.dryRun,
                uninstall: options.uninstallClaudeHooks
            )
            for result in results {
                print("config_dir=\(result.configDir) settings=\(result.settingsPath) status=\(result.status.rawValue) \(result.message)")
            }
            print("summary: \(ClaudeHooksInstaller.summarize(results)) binary=\(binaryPath)")
        case "hook":
            try runHook(options: options)
        case "clear":
            let response = try send(.clear, options: options)
            try requireSuccess(response)
            print("state=cleared status=idle daemon=accepted")
        case "ping":
            let response = try send(.ping, options: options)
            try requireSuccess(response)
            print(response.message)
        case "logs":
            let data = try Data(contentsOf: URL(fileURLWithPath: options.logPath))
            FileHandle.standardOutput.write(data)
        case "log-path":
            print(options.logPath)
        case "self-test":
            try selfTest()
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.usage("Unknown command: \(command)")
        }
    }

    private static func runHook(options: Options) throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        var input = try JSONDecoder().decode(HookInput.self, from: data)
        if options.hookSource == "claude" {
            input = applyClaudeEnvironment(to: input, notificationMatcher: options.notificationMatcher)
        } else if let notificationMatcher = options.notificationMatcher {
            input = input.applyingNotificationMatcher(notificationMatcher)
        }
        if options.dryRun {
            if input.endsSession {
                writeDiagnostic("event=SessionEnd session=\(input.sessionID) daemon-send=skipped")
            } else if let status = input.status {
                writeDiagnostic("event=\(input.hookEventName) status=\(status.rawValue) daemon-send=skipped")
            }
            print("{}")
            return
        }

        do {
            let response = try send(.hook(input), options: options)
            if !response.ok {
                writeDiagnostic("daemon rejected hook: \(response.message)")
            }
        } catch {
            // LED status must never block or alter the Codex agentic loop.
            writeDiagnostic("daemon unavailable; hook ignored: \(error)")
        }
        print("{}")
    }

    /// Resolves which of the three Claude Code launch paths produced this
    /// hook invocation, using only the environment variables set for each
    /// path (stdin JSON cannot distinguish them -- see the implementation
    /// plan's "調査で確定した環境事実").
    static func resolveClaudeSource(
        environment: [String: String]
    ) -> (kind: SessionSourceKind, herdrPaneID: String?, herdrWorkspaceID: String?) {
        if environment["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop" {
            return (.claudeDesktop, nil, nil)
        }
        if environment["HERDR_ENV"] == "1" {
            return (.claudeHerdr, environment["HERDR_PANE_ID"], environment["HERDR_WORKSPACE_ID"])
        }
        return (.claudeTerminal, nil, nil)
    }

    static func applyClaudeEnvironment(
        to input: HookInput,
        notificationMatcher: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HookInput {
        let (kind, herdrPaneID, herdrWorkspaceID) = resolveClaudeSource(environment: environment)
        let configDir = environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        return input.applyingSource(
            kind,
            herdrPaneID: herdrPaneID,
            herdrWorkspaceID: herdrWorkspaceID,
            configDir: configDir,
            notificationMatcher: notificationMatcher
        )
    }

    private static func send(_ request: DaemonRequest, options: Options) throws -> DaemonResponse {
        try UnixSocketServer.send(request, path: options.socketPath, response: DaemonResponse.self)
    }

    private static func requireSuccess(_ response: DaemonResponse) throws {
        guard response.ok else { throw CLIError.runtime(response.message) }
    }

    private static func requireGrabberSuccess(_ response: GrabberResponse) throws {
        guard response.ok else { throw CLIError.runtime(response.message) }
    }

    private static func parseOptions(_ arguments: [String]) throws -> ([String], Options) {
        var options = Options()
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--dry-run":
                options.dryRun = true
            case "--location":
                index += 1
                guard index < arguments.count, let location = parseInteger(arguments[index]) else {
                    throw CLIError.usage("--location requires a decimal or 0x-prefixed integer")
                }
                options.locationID = location
            case "--socket":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("--socket requires a path")
                }
                options.socketPath = arguments[index]
            case "--log-file":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("--log-file requires a path")
                }
                options.logPath = arguments[index]
            case "--grabber-socket":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("--grabber-socket requires a path")
                }
                options.grabberSocketPath = arguments[index]
            case "--owner-uid":
                index += 1
                guard index < arguments.count, let value = UInt32(arguments[index]) else {
                    throw CLIError.usage("--owner-uid requires a numeric uid")
                }
                options.ownerUID = uid_t(value)
            case "--owner-gid":
                index += 1
                guard index < arguments.count, let value = UInt32(arguments[index]) else {
                    throw CLIError.usage("--owner-gid requires a numeric gid")
                }
                options.ownerGID = gid_t(value)
            case "--source":
                index += 1
                guard index < arguments.count, ["codex", "claude"].contains(arguments[index]) else {
                    throw CLIError.usage("--source requires one of: codex, claude")
                }
                options.hookSource = arguments[index]
            case "--notification-matcher":
                index += 1
                guard index < arguments.count,
                      ["permission_prompt", "idle_prompt", "agent_needs_input", "agent_completed"].contains(arguments[index]) else {
                    throw CLIError.usage(
                        "--notification-matcher requires one of: permission_prompt, idle_prompt, agent_needs_input, agent_completed"
                    )
                }
                options.notificationMatcher = arguments[index]
            case "--herdr-bin":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("--herdr-bin requires a path")
                }
                options.herdrBinaryPath = arguments[index]
            case "--claude-config-dirs":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CLIError.usage("--claude-config-dirs requires a comma-separated list of paths")
                }
                options.claudeConfigDirs = arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--claude-desktop-dir":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CLIError.usage("--claude-desktop-dir requires a path")
                }
                options.claudeDesktopDir = arguments[index]
            case "--config-dir":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CLIError.usage("--config-dir requires a path")
                }
                options.installClaudeHooksConfigDirs.append(arguments[index])
            case "--binary":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    throw CLIError.usage("--binary requires a path")
                }
                options.installClaudeHooksBinaryPath = arguments[index]
            case "--uninstall":
                options.uninstallClaudeHooks = true
            default:
                positionals.append(arguments[index])
            }
            index += 1
        }
        return (positionals, options)
    }

    private static func parseInteger(_ value: String) -> Int? {
        if value.lowercased().hasPrefix("0x") {
            return Int(value.dropFirst(2), radix: 16)
        }
        return Int(value)
    }

    private static func selfTest() throws {
        let decoder = JSONDecoder()
        let samples: [(String, AgentStatus)] = [
            ("SessionStart", .idle),
            ("UserPromptSubmit", .working),
            ("PermissionRequest", .approval),
            ("PreToolUse", .working),
            ("PostToolUse", .working),
            ("Stop", .done),
            ("SessionEnd", .idle),
        ]
        for (event, expected) in samples {
            let json = #"{"session_id":"self-test","cwd":"/tmp/example/../project","hook_event_name":"EVENT"}"#
                .replacingOccurrences(of: "EVENT", with: event)
            let input = try decoder.decode(HookInput.self, from: Data(json.utf8))
            guard input.status == expected,
                  input.projectKey == "/tmp/project",
                  input.endsSession == (event == "SessionEnd") else {
                throw CLIError.runtime("Hook mapping self-test failed for \(event)")
            }
            let request = DaemonRequest.hook(input)
            let roundTrip = try decoder.decode(DaemonRequest.self, from: JSONEncoder().encode(request))
            guard roundTrip.hook?.hookEventName == event else {
                throw CLIError.runtime("Daemon request self-test failed for \(event)")
            }
        }

        // Backward-compat decode: a source-less JSON payload (every hook
        // emitted before M1) must decode with `source == nil` and resolve
        // to `.codex` via `effectiveSource`, so the Codex path is completely
        // unaffected by the M1 field additions.
        let backCompatInput = try decoder.decode(
            HookInput.self,
            from: Data(#"{"session_id":"legacy","cwd":"/tmp","hook_event_name":"SessionStart"}"#.utf8)
        )
        guard backCompatInput.source == nil,
              backCompatInput.effectiveSource == .codex,
              backCompatInput.herdrPaneID == nil,
              backCompatInput.herdrWorkspaceID == nil,
              backCompatInput.configDir == nil,
              backCompatInput.notificationMatcher == nil else {
            throw CLIError.runtime("Legacy source-less hook decode self-test failed")
        }

        // Claude Code event -> LED status mapping table (M1).
        let claudeMappingSamples: [(event: String, matcher: String?, expected: AgentStatus?)] = [
            ("SessionStart", nil, .idle),
            ("UserPromptSubmit", nil, .working),
            ("PreToolUse", nil, .working),
            ("PostToolUse", nil, .working),
            ("PermissionRequest", nil, .approval),
            ("Notification", "permission_prompt", .approval),
            ("Notification", "agent_needs_input", .approval),
            ("Notification", "idle_prompt", .idle),
            ("Notification", "agent_completed", .done),
            ("Stop", nil, .done),
            ("StopFailure", nil, .error),
            ("SessionEnd", nil, nil),
        ]
        for sample in claudeMappingSamples {
            let json = #"{"session_id":"claude-self-test","cwd":"/tmp/claude-project","hook_event_name":"EVENT","source":"claude-terminal"}"#
                .replacingOccurrences(of: "EVENT", with: sample.event)
            var claudeInput = try decoder.decode(HookInput.self, from: Data(json.utf8))
            if let matcher = sample.matcher {
                claudeInput = claudeInput.applyingNotificationMatcher(matcher)
            }
            guard claudeInput.effectiveSource == .claudeTerminal,
                  claudeInput.status == sample.expected else {
                throw CLIError.runtime(
                    "Claude hook mapping self-test failed for \(sample.event)/\(sample.matcher ?? "-")"
                )
            }
        }
        guard try decoder.decode(
            HookInput.self,
            from: Data(#"{"session_id":"c","cwd":"/tmp","hook_event_name":"SessionEnd","source":"claude-terminal"}"#.utf8)
        ).endsSession else {
            throw CLIError.runtime("Claude SessionEnd endsSession self-test failed")
        }

        // Subagent exclusion: an `agent_id` field or a `/subagents/`
        // transcript path marks a hook as belonging to a subagent, which
        // Daemon.handleClaudeHook ignores outright.
        let subagentByID = try decoder.decode(
            HookInput.self,
            from: Data(#"{"session_id":"s1","cwd":"/tmp","hook_event_name":"PostToolUse","agent_id":"sub-1","source":"claude-terminal"}"#.utf8)
        )
        let subagentByTranscriptPath = try decoder.decode(
            HookInput.self,
            from: Data(#"{"session_id":"s2","cwd":"/tmp","hook_event_name":"PostToolUse","transcript_path":"/tmp/.claude/subagents/foo.jsonl","source":"claude-terminal"}"#.utf8)
        )
        let nonSubagent = try decoder.decode(
            HookInput.self,
            from: Data(#"{"session_id":"s3","cwd":"/tmp","hook_event_name":"PostToolUse","source":"claude-terminal"}"#.utf8)
        )
        guard subagentByID.isSubagent, subagentByTranscriptPath.isSubagent, !nonSubagent.isSubagent else {
            throw CLIError.runtime("Claude subagent exclusion self-test failed")
        }

        // Environment-variable source discrimination (stdin JSON cannot tell
        // the three Claude launch paths apart -- see the implementation
        // plan's confirmed environment facts).
        let desktopEnvironment = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]
        let herdrEnvironment = [
            "HERDR_ENV": "1",
            "HERDR_PANE_ID": "w1:p2",
            "HERDR_WORKSPACE_ID": "ws1",
        ]
        let terminalEnvironment: [String: String] = [:]
        let desktopResolved = resolveClaudeSource(environment: desktopEnvironment)
        let herdrResolved = resolveClaudeSource(environment: herdrEnvironment)
        let terminalResolved = resolveClaudeSource(environment: terminalEnvironment)
        guard desktopResolved.kind == .claudeDesktop,
              desktopResolved.herdrPaneID == nil,
              herdrResolved.kind == .claudeHerdr,
              herdrResolved.herdrPaneID == "w1:p2",
              herdrResolved.herdrWorkspaceID == "ws1",
              terminalResolved.kind == .claudeTerminal,
              terminalResolved.herdrPaneID == nil else {
            throw CLIError.runtime("Claude source environment discrimination self-test failed")
        }

        let envAttachmentBaseInput = try decoder.decode(
            HookInput.self,
            from: Data(#"{"session_id":"env-test","cwd":"/tmp","hook_event_name":"Notification"}"#.utf8)
        )
        let desktopAttached = applyClaudeEnvironment(
            to: envAttachmentBaseInput,
            notificationMatcher: nil,
            environment: desktopEnvironment
        )
        guard desktopAttached.source == .claudeDesktop,
              desktopAttached.configDir == NSHomeDirectory() + "/.claude" else {
            throw CLIError.runtime("Claude Desktop environment attachment self-test failed")
        }
        var herdrEnvironmentWithConfigDir = herdrEnvironment
        herdrEnvironmentWithConfigDir["CLAUDE_CONFIG_DIR"] = "/tmp/custom-claude-config"
        let herdrAttached = applyClaudeEnvironment(
            to: envAttachmentBaseInput,
            notificationMatcher: "agent_needs_input",
            environment: herdrEnvironmentWithConfigDir
        )
        guard herdrAttached.source == .claudeHerdr,
              herdrAttached.herdrPaneID == "w1:p2",
              herdrAttached.herdrWorkspaceID == "ws1",
              herdrAttached.configDir == "/tmp/custom-claude-config",
              herdrAttached.notificationMatcher == "agent_needs_input",
              herdrAttached.status == .approval else {
            throw CLIError.runtime("Claude herdr environment attachment self-test failed")
        }

        // SessionEnd tombstone: a session that has ended stays tombstoned
        // (re-delivered/late hooks must be ignorable) until the TTL elapses.
        var tombstones = ClaudeSessionEndTombstoneBuffer()
        tombstones.record(sessionID: "ended-session", at: Date(timeIntervalSince1970: 1_000))
        guard tombstones.isTombstoned(sessionID: "ended-session", now: Date(timeIntervalSince1970: 1_030), ttl: 60),
              !tombstones.isTombstoned(sessionID: "ended-session", now: Date(timeIntervalSince1970: 1_061), ttl: 60),
              !tombstones.isTombstoned(sessionID: "never-ended", now: Date(timeIntervalSince1970: 1_000), ttl: 60) else {
            throw CLIError.runtime("Claude SessionEnd tombstone self-test failed")
        }
        tombstones.prune(now: Date(timeIntervalSince1970: 1_061), ttl: 60)
        guard tombstones.count == 0 else {
            throw CLIError.runtime("Claude SessionEnd tombstone pruning self-test failed")
        }

        // herdr (M2): fixed JSON parse test, shaped exactly like the real
        // `herdr agent list` / `herdr workspace list` output captured from a
        // live herdr instance (two workspaces, one Claude pane each, plus a
        // non-Claude agent that must be filtered out).
        let herdrAgentListJSON = #"""
        {"id":"cli:agent:list","result":{"agents":[
          {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"11111111-1111-1111-1111-111111111111"},"agent_status":"working","cwd":"/Users/dev/project-a","focused":false,"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"},
          {"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"22222222-2222-2222-2222-222222222222"},"agent_status":"idle","cwd":"/Users/dev/project-b","focused":true,"pane_id":"w2:p1","tab_id":"w2:t1","workspace_id":"w2"},
          {"agent":"codex","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"33333333-3333-3333-3333-333333333333"},"agent_status":"idle","cwd":"/Users/dev/project-c","focused":false,"pane_id":"w3:p1","tab_id":"w3:t1","workspace_id":"w3"}
        ],"type":"agent_list"}}
        """#
        let herdrWorkspaceListJSON = #"""
        {"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
          {"active_tab_id":"w1:t1","agent_status":"working","focused":false,"label":"project-a","number":1,"pane_count":1,"tab_count":1,"workspace_id":"w1"},
          {"active_tab_id":"w2:t1","agent_status":"idle","focused":true,"label":"project-b","number":2,"pane_count":1,"tab_count":1,"workspace_id":"w2"}
        ]}}
        """#
        let herdrAgents = try decoder.decode(HerdrAgentListResponse.self, from: Data(herdrAgentListJSON.utf8)).result.agents
        let herdrWorkspaces = try decoder.decode(HerdrWorkspaceListResponse.self, from: Data(herdrWorkspaceListJSON.utf8)).result.workspaces
        guard herdrAgents.count == 3, herdrWorkspaces.count == 2 else {
            throw CLIError.runtime("herdr fixture decode self-test failed")
        }
        let herdrEntries = HerdrCatalog.buildSessionEntries(agents: herdrAgents, workspaces: herdrWorkspaces)
        guard herdrEntries.count == 2,
              herdrEntries.map(\.sessionID) == ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"],
              herdrEntries.map(\.workspaceNumber) == [1, 2],
              herdrEntries.map(\.paneNumber) == [1, 1],
              herdrEntries.map(\.seedStatus) == [.working, .idle] else {
            throw CLIError.runtime("herdr agent-list/workspace-list parse self-test failed (codex agent must be filtered out)")
        }

        // herdr agent_status -> AgentStatus seed mapping (blocked -> approval,
        // unknown -> idle, everything else 1:1).
        let herdrStatusSamples: [(String, AgentStatus)] = [
            ("idle", .idle),
            ("working", .working),
            ("blocked", .approval),
            ("done", .done),
            ("unknown", .idle),
        ]
        for (herdrStatus, expected) in herdrStatusSamples {
            guard HerdrCatalog.seedStatus(forHerdrStatus: herdrStatus) == expected else {
                throw CLIError.runtime("herdr status mapping self-test failed for \(herdrStatus)")
            }
        }

        // Pane-id -> pane-number parsing.
        guard HerdrCatalog.parsePaneNumber("w9:p1") == 1,
              HerdrCatalog.parsePaneNumber("wA:p12") == 12,
              HerdrCatalog.parsePaneNumber("not-a-pane-id") == nil,
              HerdrCatalog.parsePaneNumber("w1:") == nil else {
            throw CLIError.runtime("herdr pane-number parsing self-test failed")
        }

        // herdr binary resolution precedence: explicit path > HERDR_BIN env > PATH candidates.
        let herdrBinaryFixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-herdr-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: herdrBinaryFixtureDirectory) }
        try FileManager.default.createDirectory(at: herdrBinaryFixtureDirectory, withIntermediateDirectories: true)
        let explicitHerdrBinary = herdrBinaryFixtureDirectory.appendingPathComponent("explicit-herdr")
        let envHerdrBinary = herdrBinaryFixtureDirectory.appendingPathComponent("env-herdr")
        try Data("#!/bin/sh\n".utf8).write(to: explicitHerdrBinary)
        try Data("#!/bin/sh\n".utf8).write(to: envHerdrBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: explicitHerdrBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: envHerdrBinary.path)
        guard HerdrBinaryResolver.resolve(
            explicitPath: explicitHerdrBinary.path,
            environment: ["HERDR_BIN": envHerdrBinary.path]
        ) == explicitHerdrBinary.path,
              HerdrBinaryResolver.resolve(
                  explicitPath: "/nonexistent/herdr",
                  environment: ["HERDR_BIN": envHerdrBinary.path]
              ) == envHerdrBinary.path,
              HerdrBinaryResolver.resolve(explicitPath: nil, environment: [:]) == nil
                  || HerdrBinaryResolver.pathCandidates.contains(
                      HerdrBinaryResolver.resolve(explicitPath: nil, environment: [:]) ?? ""
                  ) else {
            throw CLIError.runtime("herdr binary resolution precedence self-test failed")
        }

        // HerdrProcessRunner: a command that outrun its timeout must fail
        // with `.timedOut` rather than hang the caller.
        var herdrTimeoutObserved = false
        do {
            _ = try HerdrProcessRunner.run(binary: "/bin/sleep", arguments: ["2"], timeout: 0.1)
        } catch let error as HerdrProcessRunner.RunError {
            if case .timedOut = error { herdrTimeoutObserved = true }
        }
        guard herdrTimeoutObserved else {
            throw CLIError.runtime("herdr process timeout self-test failed")
        }

        // HerdrSnapshotStore: keeps the last successful snapshot available
        // for 15s past its fetch time, then treats it as gone.
        let herdrStore = HerdrSnapshotStore()
        let herdrFetchTime = Date(timeIntervalSince1970: 10_000)
        let herdrStoredEntries = [
            HerdrCatalog.SessionEntry(
                sessionID: "stale-test",
                cwd: "/tmp",
                workspaceID: "w1",
                workspaceNumber: 1,
                paneID: "w1:p1",
                paneNumber: 1,
                seedStatus: .idle
            ),
        ]
        herdrStore.recordSuccess(herdrStoredEntries, at: herdrFetchTime)
        guard herdrStore.currentEntries(now: herdrFetchTime.addingTimeInterval(14), staleGrace: 15) == herdrStoredEntries,
              herdrStore.currentEntries(now: herdrFetchTime.addingTimeInterval(15), staleGrace: 15) == herdrStoredEntries,
              herdrStore.currentEntries(now: herdrFetchTime.addingTimeInterval(15.5), staleGrace: 15).isEmpty else {
            throw CLIError.runtime("herdr snapshot 15s stale-grace self-test failed")
        }

        // UnifiedLayout row ordering with herdr's negative-encoded rowRank:
        // two herdr workspaces (numbers 3 and 1) must land ordered by
        // ascending workspace number (workspace 1 before workspace 3), both
        // ahead of an unranked Codex row, while an explicitly-ranked Codex
        // row (absolute slot 0, exactly as CodexSourceProvider emits) keeps
        // its literal slot untouched -- herdr rows pack into the remaining
        // free rows rather than colliding with it.
        let herdrOrderingSessions = [
            AgentSession(
                sourceKind: .codex,
                sessionID: "codex-reserved",
                cwd: "/repo/reserved",
                rowHints: RowGroupingHints(codexProjectID: "reserved-project", herdrWorkspaceID: nil),
                recency: 1,
                rowRank: 0,
                columnRank: 0,
                seedStatus: nil,
                navigation: .codexThread(sessionID: "codex-reserved")
            ),
            AgentSession(
                sourceKind: .codex,
                sessionID: "codex-unranked",
                cwd: "/repo/unranked",
                rowHints: .none,
                recency: 100,
                rowRank: nil,
                columnRank: nil,
                seedStatus: nil,
                navigation: .codexThread(sessionID: "codex-unranked")
            ),
            AgentSession(
                sourceKind: .claudeHerdr,
                sessionID: "herdr-ws3",
                cwd: "/repo/ws3",
                rowHints: RowGroupingHints(codexProjectID: nil, herdrWorkspaceID: "w3"),
                recency: 5,
                rowRank: HerdrCatalog.rowRank(forWorkspaceNumber: 3),
                columnRank: 0,
                seedStatus: .idle,
                navigation: .herdrPane(paneID: "w3:p1")
            ),
            AgentSession(
                sourceKind: .claudeHerdr,
                sessionID: "herdr-ws1",
                cwd: "/repo/ws1",
                rowHints: RowGroupingHints(codexProjectID: nil, herdrWorkspaceID: "w1"),
                recency: 5,
                rowRank: HerdrCatalog.rowRank(forWorkspaceNumber: 1),
                columnRank: 0,
                seedStatus: .working,
                navigation: .herdrPane(paneID: "w1:p1")
            ),
        ]
        let herdrOrderingLayout = UnifiedLayout.compute(sessions: herdrOrderingSessions)
        guard herdrOrderingLayout.projectRows["reserved-project"] == 0,
              herdrOrderingLayout.warnings.isEmpty,
              let herdrWS1Row = herdrOrderingLayout.placements.first(where: { $0.session.sessionID == "herdr-ws1" })?.row,
              let herdrWS3Row = herdrOrderingLayout.placements.first(where: { $0.session.sessionID == "herdr-ws3" })?.row,
              let codexUnrankedRow = herdrOrderingLayout.placements.first(where: { $0.session.sessionID == "codex-unranked" })?.row,
              herdrWS1Row != 0, herdrWS3Row != 0,
              herdrWS1Row < herdrWS3Row,
              herdrWS3Row < codexUnrankedRow else {
            throw CLIError.runtime("herdr row-ordering (workspace number ascending, ahead of unranked Codex rows) self-test failed")
        }

        let diagnosticJSON = #"{"session_id":"deferred","cwd":"/tmp/project","hook_event_name":"PostToolUse","turn_id":"turn-1","agent_id":"agent-1","agent_type":"executor","transcript_path":"/tmp/transcript.jsonl","permission_mode":"default","tool_name":"exec_command"}"#
        let diagnosticInput = try decoder.decode(HookInput.self, from: Data(diagnosticJSON.utf8))
        guard diagnosticInput.turnID == "turn-1",
              diagnosticInput.agentID == "agent-1",
              diagnosticInput.agentType == "executor",
              diagnosticInput.transcriptPath == "/tmp/transcript.jsonl",
              diagnosticInput.permissionMode == "default",
              diagnosticInput.toolName == "exec_command" else {
            throw CLIError.runtime("Hook diagnostic metadata self-test failed")
        }
        let permissionJSON = diagnosticJSON
            .replacingOccurrences(of: "PostToolUse", with: "PermissionRequest")
        let permissionInput = try decoder.decode(HookInput.self, from: Data(permissionJSON.utf8))
        guard !permissionInput.directlyRequestsUserPermission else {
            throw CLIError.runtime("Generic PermissionRequest routing self-test failed")
        }
        let requestPermissionsJSON = permissionJSON
            .replacingOccurrences(of: "exec_command", with: "request_permissions")
        let requestPermissionsInput = try decoder.decode(
            HookInput.self,
            from: Data(requestPermissionsJSON.utf8)
        )
        guard requestPermissionsInput.directlyRequestsUserPermission,
              CodexApprovalRouting.displayRoute(
                for: requestPermissionsInput,
                homeDirectory: "/private/nonexistent"
              ) == .user(reason: "request_permissions") else {
            throw CLIError.runtime("Direct request_permissions routing self-test failed")
        }
        let reviewerLines = [
            #"{"type":"turn_context","payload":{"approvals_reviewer":"user"}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"approvals_reviewer":"auto_review"}}}"#,
        ]
        guard CodexApprovalRouting.latestApprovalsReviewer(in: reviewerLines) == .autoReview else {
            throw CLIError.runtime("Approval reviewer rollout parsing self-test failed")
        }
        var pendingApprovals = PendingApprovalBuffer()
        pendingApprovals.record(permissionInput, at: Date(timeIntervalSince1970: 100))
        guard pendingApprovals.due(
            now: Date(timeIntervalSince1970: 100.499),
            delay: 0.5
        ).isEmpty,
              pendingApprovals.count == 1,
              pendingApprovals.cancel(sessionID: permissionInput.sessionID) != nil,
              pendingApprovals.count == 0 else {
            throw CLIError.runtime("Approval debounce cancellation self-test failed")
        }
        pendingApprovals.record(permissionInput, at: Date(timeIntervalSince1970: 200))
        guard pendingApprovals.due(
            now: Date(timeIntervalSince1970: 200.5),
            delay: 0.5
        ).map(\.hook.sessionID) == ["deferred"],
              pendingApprovals.count == 0 else {
            throw CLIError.runtime("Approval debounce expiry self-test failed")
        }
        var deferredHooks = DeferredHookBuffer()
        deferredHooks.record(
            diagnosticInput,
            status: .working,
            at: Date(timeIntervalSince1970: 100)
        )
        let waitingDrain = deferredHooks.drain(
            catalogSessionIDs: [],
            now: Date(timeIntervalSince1970: 105),
            maxAge: 6
        )
        guard waitingDrain.promoted.isEmpty,
              waitingDrain.expired.isEmpty,
              deferredHooks.count == 1 else {
            throw CLIError.runtime("Deferred hook waiting self-test failed")
        }
        let promotedDrain = deferredHooks.drain(
            catalogSessionIDs: ["deferred"],
            now: Date(timeIntervalSince1970: 105),
            maxAge: 6
        )
        guard promotedDrain.promoted.map(\.hook.sessionID) == ["deferred"],
              promotedDrain.expired.isEmpty,
              deferredHooks.count == 0 else {
            throw CLIError.runtime("Deferred hook promotion self-test failed")
        }
        deferredHooks.record(
            diagnosticInput,
            status: .working,
            at: Date(timeIntervalSince1970: 200)
        )
        let expiredDrain = deferredHooks.drain(
            catalogSessionIDs: [],
            now: Date(timeIntervalSince1970: 206),
            maxAge: 6
        )
        guard expiredDrain.promoted.isEmpty,
              expiredDrain.expired.map(\.hook.sessionID) == ["deferred"],
              deferredHooks.count == 0 else {
            throw CLIError.runtime("Deferred hook expiry self-test failed")
        }

        let migrationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-state-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: migrationDirectory) }
        try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
        let migrationUID: uid_t = 1234
        let legacyEndedSessionsURL = migrationDirectory
            .appendingPathComponent("keychron-c100-status-\(migrationUID)-ended-sessions.json")
        try Data(#"["stale-session"]"#.utf8).write(to: legacyEndedSessionsURL)
        let migrationStore = StateStore(uid: migrationUID, runtimeDirectory: migrationDirectory)
        try migrationStore.discardLegacyEndedSessions()
        guard !FileManager.default.fileExists(atPath: legacyEndedSessionsURL.path) else {
            throw CLIError.runtime("Legacy SessionEnd tombstone migration self-test failed")
        }

        var socketPair = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketPair) == 0 else {
            throw CLIError.runtime("Unix socket framing self-test could not create socketpair")
        }
        defer {
            Darwin.close(socketPair[0])
            Darwin.close(socketPair[1])
        }
        try UnixSocketServer.write(DaemonRequest.ping, to: socketPair[0])
        let framedRequest = try UnixSocketServer.readRequest(
            from: socketPair[1],
            timeoutMilliseconds: 100
        )
        guard try decoder.decode(DaemonRequest.self, from: framedRequest).kind == .ping else {
            throw CLIError.runtime("Unix socket newline framing self-test failed")
        }
        var socketReadTimedOut = false
        do {
            _ = try UnixSocketServer.readRequest(from: socketPair[1], timeoutMilliseconds: 20)
        } catch {
            socketReadTimedOut = String(describing: error).contains("timed out")
        }
        guard socketReadTimedOut else {
            throw CLIError.runtime("Unix socket timeout self-test failed")
        }

        var grid = GridState()
        let a0 = try grid.update(sessionID: "a0", projectKey: "/project/a", status: .idle)
        let a1 = try grid.update(sessionID: "a1", projectKey: "/project/a", status: .working)
        let b0 = try grid.update(sessionID: "b0", projectKey: "/project/b", status: .approval)
        let b0Done = try grid.update(sessionID: "b0", projectKey: "/project/b", status: .done)
        let b0Acknowledged = try grid.update(sessionID: "b0", projectKey: "/project/b", status: .idle)
        _ = try grid.update(sessionID: "a0", projectKey: "/project/a", status: nil, remove: true)
        let a2 = try grid.update(sessionID: "a2", projectKey: "/project/a", status: .idle)
        guard a0.slot?.keyIndex == 0,
              a1.slot?.keyIndex == 1,
              b0.slot?.keyIndex == 10,
              b0Done.slot?.status == .done,
              b0Acknowledged.slot?.status == .idle,
              b0Acknowledged.changed,
              a2.slot?.keyIndex == 0,
              grid.projectRows["/project/a"] == 0,
              grid.projectRows["/project/b"] == 1 else {
            throw CLIError.runtime("Project-row/session-column allocation self-test failed")
        }

        let catalogLayout = CodexCatalog.orderedLayout([
            CatalogSession(sessionID: "a-new", cwd: "/worktree/a", projectID: "shared", recency: 4, createdAt: 4),
            CatalogSession(sessionID: "a-old", cwd: "/repo/a", projectID: "shared", recency: 3, createdAt: 3),
            CatalogSession(sessionID: "b", cwd: "/repo/b", projectID: nil, recency: 2, createdAt: 2),
        ], sidebar: CodexSidebarOrdering(
            projectIDs: ["empty", "shared"],
            threadIDsByProject: ["shared": ["a-old", "a-new"]],
            pinnedThreadIDs: [],
            projectAssignments: [:]
        ))
        guard catalogLayout.projectRows["project:empty"] == 0,
              catalogLayout.projectRows["project:shared"] == 1,
              catalogLayout.projectRows[CodexCatalog.projectlessKey] == 2,
              catalogLayout.placements.map(\.session.sessionID) == ["a-old", "a-new", "b"],
              catalogLayout.placements.map(\.keyIndex) == [10, 11, 20] else {
            throw CLIError.runtime("Codex sidebar-order/projectless-row self-test failed")
        }

        // M0 golden test: for Codex-only input, UnifiedLayout must reproduce the
        // exact placements CodexCatalog.orderedLayout (as used by the pre-M0
        // Daemon.syncCatalog) produces, by construction from the same
        // row/column ranks CodexSourceProvider would derive.
        let codexOnlyAgentSessions = catalogLayout.placements.map { placement -> AgentSession in
            let session = placement.session
            return AgentSession(
                sourceKind: .codex,
                sessionID: session.sessionID,
                cwd: URL(fileURLWithPath: session.cwd).standardizedFileURL.path,
                rowHints: RowGroupingHints(codexProjectID: session.projectKey, herdrWorkspaceID: nil),
                recency: session.recency,
                rowRank: catalogLayout.projectRows[session.projectKey],
                columnRank: placement.column,
                seedStatus: nil,
                navigation: .codexThread(sessionID: session.sessionID)
            )
        }
        let unifiedCodexOnly = UnifiedLayout.compute(sessions: codexOnlyAgentSessions)
        // Note: catalogLayout.projectRows also reserves row 0 for the
        // sidebar-listed "project:empty" project, which has zero sessions in
        // this fixture and therefore no AgentSession to carry it -- so it
        // cannot appear in unifiedCodexOnly.projectRows. What must match
        // exactly is the row/column/key each *actual* session lands on,
        // which is the real correctness bar ("identical placements").
        guard unifiedCodexOnly.projectRows.allSatisfy({ catalogLayout.projectRows[$0.key] == $0.value }),
              unifiedCodexOnly.warnings.isEmpty,
              unifiedCodexOnly.placements.map(\.session.sessionID)
                  == catalogLayout.placements.map(\.session.sessionID),
              unifiedCodexOnly.placements.map(\.keyIndex) == catalogLayout.placements.map(\.keyIndex),
              unifiedCodexOnly.placements.map(\.projectKey)
                  == catalogLayout.placements.map(\.session.projectKey) else {
            throw CLIError.runtime("UnifiedLayout Codex-parity golden self-test failed")
        }

        // Union-find row merging: sessions sharing a codexProjectID (worktree
        // case) or herdrWorkspaceID (M2 groundwork) merge onto one row even
        // when their cwds differ; unrelated cwds stay on separate rows.
        let mergeSessions = [
            AgentSession(
                sourceKind: .codex,
                sessionID: "merge-a",
                cwd: "/repo/main",
                rowHints: RowGroupingHints(codexProjectID: "proj", herdrWorkspaceID: nil),
                recency: 10,
                rowRank: 0,
                columnRank: 0,
                seedStatus: nil,
                navigation: .codexThread(sessionID: "merge-a")
            ),
            AgentSession(
                sourceKind: .codex,
                sessionID: "merge-b",
                cwd: "/repo/worktree",
                rowHints: RowGroupingHints(codexProjectID: "proj", herdrWorkspaceID: nil),
                recency: 9,
                rowRank: 0,
                columnRank: 1,
                seedStatus: nil,
                navigation: .codexThread(sessionID: "merge-b")
            ),
            AgentSession(
                sourceKind: .claudeHerdr,
                sessionID: "herdr-a",
                cwd: "/repo/pane-a",
                rowHints: RowGroupingHints(codexProjectID: nil, herdrWorkspaceID: "ws1"),
                recency: 8,
                rowRank: 1,
                columnRank: 0,
                seedStatus: nil,
                navigation: .herdrPane(paneID: "pane-a")
            ),
            AgentSession(
                sourceKind: .claudeHerdr,
                sessionID: "herdr-b",
                cwd: "/repo/pane-b",
                rowHints: RowGroupingHints(codexProjectID: nil, herdrWorkspaceID: "ws1"),
                recency: 7,
                rowRank: 1,
                columnRank: 1,
                seedStatus: nil,
                navigation: .herdrPane(paneID: "pane-b")
            ),
            AgentSession(
                sourceKind: .codex,
                sessionID: "unrelated",
                cwd: "/repo/other",
                rowHints: RowGroupingHints(codexProjectID: "other-proj", herdrWorkspaceID: nil),
                recency: 6,
                rowRank: 2,
                columnRank: 0,
                seedStatus: nil,
                navigation: .codexThread(sessionID: "unrelated")
            ),
        ]
        let mergedLayout = UnifiedLayout.compute(sessions: mergeSessions)
        guard mergedLayout.projectRows["proj"] == 0,
              mergedLayout.projectRows["ws1"] == 1,
              mergedLayout.projectRows["other-proj"] == 2,
              mergedLayout.placements.filter({ $0.row == 0 }).map(\.session.sessionID) == ["merge-a", "merge-b"],
              mergedLayout.placements.filter({ $0.row == 1 }).map(\.session.sessionID) == ["herdr-a", "herdr-b"],
              mergedLayout.placements.filter({ $0.row == 2 }).map(\.session.sessionID) == ["unrelated"],
              mergedLayout.warnings.isEmpty else {
            throw CLIError.runtime("UnifiedLayout union-find row merging self-test failed")
        }

        // 10x10 truncation: 12 distinct unranked rows collapse to the first 10
        // by recency, with a warning; 12 sessions crammed into a single row
        // collapse to the first 10 columns by rank, with a warning.
        let overflowRowSessions = (0..<12).map { index in
            AgentSession(
                sourceKind: .codex,
                sessionID: "row-\(index)",
                cwd: "/repo/row-\(index)",
                rowHints: .none,
                recency: Double(12 - index),
                rowRank: nil,
                columnRank: 0,
                seedStatus: nil,
                navigation: .codexThread(sessionID: "row-\(index)")
            )
        }
        let overflowRowLayout = UnifiedLayout.compute(sessions: overflowRowSessions)
        guard overflowRowLayout.placements.count == 10,
              overflowRowLayout.placements.map(\.session.sessionID)
                  == (0..<10).map({ "row-\($0)" }),
              overflowRowLayout.warnings.count == 2,
              overflowRowLayout.warnings.allSatisfy({ $0.contains("row") }) else {
            throw CLIError.runtime("UnifiedLayout row-overflow truncation self-test failed")
        }

        let overflowColumnSessions = (0..<12).map { index in
            AgentSession(
                sourceKind: .codex,
                sessionID: "col-\(index)",
                cwd: "/repo/shared-\(index)",
                rowHints: RowGroupingHints(codexProjectID: "crowded", herdrWorkspaceID: nil),
                recency: Double(index),
                rowRank: 0,
                columnRank: index,
                seedStatus: nil,
                navigation: .codexThread(sessionID: "col-\(index)")
            )
        }
        let overflowColumnLayout = UnifiedLayout.compute(sessions: overflowColumnSessions)
        guard overflowColumnLayout.placements.count == 10,
              overflowColumnLayout.placements.map(\.session.sessionID)
                  == (0..<10).map({ "col-\($0)" }),
              overflowColumnLayout.warnings.count == 2,
              overflowColumnLayout.warnings.allSatisfy({ $0.contains("column") }) else {
            throw CLIError.runtime("UnifiedLayout column-overflow truncation self-test failed")
        }

        let forkSessionMeta = Data(#"{"type":"session_meta","payload":{"id":"fork","forked_from_id":"subagent"}}"#.utf8)
        let forkProject = CodexCatalog.resolvedForkProjectID(
            explicitProjectID: nil,
            forkedFromID: CodexCatalog.forkedFromID(sessionMetaLine: forkSessionMeta),
            parentByChild: ["subagent": "parent"],
            projectBySession: ["parent": "shared"]
        )
        let explicitForkProject = CodexCatalog.resolvedForkProjectID(
            explicitProjectID: "worktree-project",
            forkedFromID: "subagent",
            parentByChild: ["subagent": "parent"],
            projectBySession: ["parent": "shared"]
        )
        guard forkProject == "shared", explicitForkProject == "worktree-project" else {
            throw CLIError.runtime("Codex fork ancestry/project inheritance self-test failed")
        }

        let interruptedLines = [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"message","text":"turn_aborted"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
        ]
        let resumedLines = interruptedLines + [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        ]
        guard CodexTurnMonitor.latestTurnSignal(in: interruptedLines) == .aborted,
              CodexTurnMonitor.latestTurnSignal(in: resumedLines) == .started else {
            throw CLIError.runtime("Codex interrupted-turn monitor self-test failed")
        }

        let monitorHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-turn-monitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: monitorHome) }
        let rolloutDirectory = monitorHome
            .appendingPathComponent(".codex/sessions/1970/01/01")
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)
        let monitorSessionID = "00000000-0000-0000-0000-000000000001"
        let rolloutURL = rolloutDirectory
            .appendingPathComponent("rollout-1970-01-01T00-00-00-\(monitorSessionID).jsonl")
        try Data((interruptedLines[0] + "\n").utf8).write(to: rolloutURL)
        let monitorSession = CatalogSession(
            sessionID: monitorSessionID,
            cwd: "/tmp",
            projectID: nil,
            recency: 1,
            createdAt: 0
        )
        let turnMonitor = CodexTurnMonitor()
        guard turnMonitor.interruptedSessionIDs(
            in: [monitorSession],
            homeDirectory: monitorHome.path
        ).isEmpty else {
            throw CLIError.runtime("Codex interrupted-turn monitor reported a false positive")
        }
        let rolloutHandle = try FileHandle(forWritingTo: rolloutURL)
        try rolloutHandle.seekToEnd()
        try rolloutHandle.write(contentsOf: Data((interruptedLines[2] + "\n").utf8))
        try rolloutHandle.close()
        guard turnMonitor.interruptedSessionIDs(
            in: [monitorSession],
            homeDirectory: monitorHome.path
        ) == [monitorSessionID] else {
            throw CLIError.runtime("Codex interrupted-turn monitor missed an appended abort")
        }

        let grabberRequest = GrabberRequest.acquire(locationID: 0x110000)
        let grabberRoundTrip = try decoder.decode(
            GrabberRequest.self,
            from: JSONEncoder().encode(grabberRequest)
        )
        let helperPlistData = Data(
            HelperInstaller.plist(
                ownerUID: 502,
                ownerGID: 20,
                locationID: 0x110000,
                socketPath: "/var/run/keychron-c100-grabber-502.sock"
            ).utf8
        )
        let helperPlist = try PropertyListSerialization.propertyList(from: helperPlistData, format: nil) as? [String: Any]
        let helperArguments = helperPlist?["ProgramArguments"] as? [String]
        let helperAppInfoData = Data(HelperInstaller.appInfoPlist().utf8)
        let helperAppInfo = try PropertyListSerialization.propertyList(from: helperAppInfoData, format: nil) as? [String: Any]
        let allowedGrabberLocation = try PrivilegedGrabberService.validateRequestedLocation(
            grabberRoundTrip.locationID,
            allowedLocationID: 0x110000
        )
        let rejectedGrabberLocation: Bool
        do {
            _ = try PrivilegedGrabberService.validateRequestedLocation(0x220000, allowedLocationID: 0x110000)
            rejectedGrabberLocation = false
        } catch {
            rejectedGrabberLocation = true
        }
        let loggerSafetyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-logger-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: loggerSafetyDirectory) }
        try FileManager.default.createDirectory(at: loggerSafetyDirectory, withIntermediateDirectories: false)
        let loggerTarget = loggerSafetyDirectory.appendingPathComponent("target.log")
        let loggerSymlink = loggerSafetyDirectory.appendingPathComponent("status.log")
        try Data().write(to: loggerTarget)
        try FileManager.default.createSymbolicLink(at: loggerSymlink, withDestinationURL: loggerTarget)
        let rejectedLoggerSymlink: Bool
        do {
            _ = try StatusLogger(fileURL: loggerSymlink)
            rejectedLoggerSymlink = false
        } catch {
            rejectedLoggerSymlink = true
        }
        guard grabberRoundTrip.kind == .acquire,
              grabberRoundTrip.locationID == 0x110000,
              allowedGrabberLocation == 0x110000,
              rejectedGrabberLocation,
              rejectedLoggerSymlink,
              helperPlist?["Label"] as? String == HelperInstaller.label,
              helperArguments?.first == HelperInstaller.executablePath,
              helperArguments?.contains("grabber-service") == true,
              helperArguments?.contains("1114112") == true,
              helperAppInfo?["CFBundleIdentifier"] as? String == HelperInstaller.label,
              helperAppInfo?["CFBundleExecutable"] as? String == "c100-status-grabber",
              helperAppInfo?["LSBackgroundOnly"] as? Bool == true else {
            throw CLIError.runtime("Privileged grabber protocol/LaunchDaemon plist self-test failed")
        }

        let reports = KeychronProtocol.setColorReports(
            ledCount: 100,
            color: AgentStatus.working.color
        )
        var frame = [HSVColor](repeating: LEDColorName.off.color, count: 100)
        frame[0] = AgentStatus.idle.color
        frame[99] = AgentStatus.done.color
        let frameReports = KeychronProtocol.setColorReports(colors: frame)
        let regionReports = KeychronProtocol.setRegionsReports(assignedIndexes: [0, 99], ledCount: 100)
        let mixedEffectReports = KeychronProtocol.mixedEffectListReports()
        let effectReport = KeychronProtocol.setEffectReport()
        let oneKeyReport = KeychronProtocol.setColorReport(index: 42, color: LEDColorName.red.color)
        let keymapReport = KeychronProtocol.keymapBufferReport(offset: 28, keyCount: 14)
        let physicalMap = PhysicalKeyMap(qmkKeycodes: [4, 5, 4, 0x612C])
        guard reports.count == 12,
              frameReports.count == 12,
              regionReports.count == 4,
              mixedEffectReports.count == 4,
              reports.allSatisfy({ $0.count == KeychronProtocol.reportLength }),
              frameReports.allSatisfy({ $0.count == KeychronProtocol.reportLength }),
              reports.first?[0] == KeychronProtocol.keychronRGB,
              reports.first?[1] == KeychronProtocol.RGBCommand.setLEDColor.rawValue,
              reports.first?[2] == 0,
              reports.first?[3] == 9,
              reports.last?[2] == 99,
              reports.last?[3] == 1,
              Array(frameReports.first!.prefix(10)) == [0xA8, 10, 0, 9, 0, 0, 24, 0, 0, 0],
              Array(frameReports.last!.prefix(7)) == [0xA8, 10, 99, 1, 85, 255, 112],
              Array(regionReports.first!.prefix(8)) == [0xA8, 13, 0, 28, 0, 1, 1, 1],
              Array(regionReports.last!.prefix(8)) == [0xA8, 13, 84, 16, 1, 1, 1, 1],
              Array(mixedEffectReports[0].prefix(8)) == [0xA8, 15, 0, 0, 3, 23, 0, 0],
              effectReport.count == KeychronProtocol.reportLength,
              Array(effectReport.prefix(4)) == [7, 3, 2, KeychronProtocol.perKeyEffect],
              Array(oneKeyReport.prefix(7)) == [KeychronProtocol.keychronRGB, 10, 42, 1, 0, 255, 144],
              Array(keymapReport.prefix(4)) == [18, 0, 28, 28],
              physicalMap.resolve(usage: 4) == .ambiguous([0, 2]),
              physicalMap.resolve(usage: 5) == .key(1),
              physicalMap.resolve(usage: 44) == .key(3),
              physicalMap.resolve(usage: 99) == .unmapped else {
            throw CLIError.runtime("Keychron report self-test failed")
        }

        // M3: `sessions/<pid>.json` decode against the real schema confirmed
        // from a live Claude Code process (fields beyond pid/sessionId/cwd
        // are present on the real file but irrelevant here and must be
        // ignored, not rejected).
        let claudeSessionFileJSON = #"""
        {"pid":32317,"sessionId":"a4085832-886f-4195-86cd-3c8bbfef72c0","cwd":"/Users/dev/repo","startedAt":1788247808700,"version":"2.1.252","kind":"interactive","entrypoint":"cli","status":"idle"}
        """#
        let claudeSessionFileEntry = try decoder.decode(
            ClaudeSessionFileEntry.self,
            from: Data(claudeSessionFileJSON.utf8)
        )
        guard claudeSessionFileEntry.pid == 32317,
              claudeSessionFileEntry.sessionID == "a4085832-886f-4195-86cd-3c8bbfef72c0",
              claudeSessionFileEntry.cwd == "/Users/dev/repo" else {
            throw CLIError.runtime("Claude sessions/<pid>.json schema decode self-test failed")
        }
        guard ClaudeSessionsCatalog.parsePID(fromFilename: "32317.json") == 32317,
              ClaudeSessionsCatalog.parsePID(fromFilename: "32317.4a51adf0722fc5.key") == nil,
              ClaudeSessionsCatalog.parsePID(fromFilename: "not-a-pid.json") == nil,
              ClaudeSessionsCatalog.parsePID(fromFilename: "32317") == nil else {
            throw CLIError.runtime("Claude sessions filename pid-parsing self-test failed")
        }

        // M3: full ClaudeSessionsCatalog.snapshot() scan -- pid liveness
        // branching (dead pid's file is ignored), pid/filename mismatch
        // rejection, and multi-config-dir aggregation, all via a real
        // temp-directory scan (only `isProcessAlive` is faked).
        let claudeCatalogFixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-claude-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: claudeCatalogFixtureRoot) }
        let claudeConfigDirA = claudeCatalogFixtureRoot.appendingPathComponent("configA")
        let claudeConfigDirB = claudeCatalogFixtureRoot.appendingPathComponent("configB")
        for dir in [claudeConfigDirA, claudeConfigDirB] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("sessions"),
                withIntermediateDirectories: true
            )
        }
        // Alive, well-formed session in config dir A.
        try Data(#"{"pid":111,"sessionId":"alive-session","cwd":"/repo/a"}"#.utf8)
            .write(to: claudeConfigDirA.appendingPathComponent("sessions/111.json"))
        // Dead pid (isProcessAlive will report false) -- must be excluded.
        try Data(#"{"pid":222,"sessionId":"dead-session","cwd":"/repo/a"}"#.utf8)
            .write(to: claudeConfigDirA.appendingPathComponent("sessions/222.json"))
        // A `.key` sibling file must never be parsed as a session file.
        try Data("not-json-and-should-never-be-read".utf8)
            .write(to: claudeConfigDirA.appendingPathComponent("sessions/111.somehash.key"))
        // pid/filename mismatch -- suspicious, must be skipped even though
        // its own pid (333) is alive.
        try Data(#"{"pid":999,"sessionId":"mismatched-session","cwd":"/repo/a"}"#.utf8)
            .write(to: claudeConfigDirA.appendingPathComponent("sessions/333.json"))
        // Second config dir, alive session, proving multi-dir aggregation.
        try Data(#"{"pid":444,"sessionId":"alive-session-b","cwd":"/repo/b"}"#.utf8)
            .write(to: claudeConfigDirB.appendingPathComponent("sessions/444.json"))
        let claudeCatalogFixture = ClaudeSessionsCatalog(
            configDirs: [claudeConfigDirA.path, claudeConfigDirB.path],
            isProcessAlive: { pid in pid != 222 }
        )
        let claudeCatalogSnapshot = try claudeCatalogFixture.snapshot()
        guard Set(claudeCatalogSnapshot.map(\.sessionID)) == ["alive-session", "alive-session-b"],
              claudeCatalogSnapshot.allSatisfy({ $0.sourceKind == .claudeTerminal }),
              claudeCatalogSnapshot.first(where: { $0.sessionID == "alive-session" })?.cwd == "/repo/a" else {
            throw CLIError.runtime("ClaudeSessionsCatalog.snapshot self-test failed")
        }

        // M3: config-dir resolution merges the 3 defaults with
        // `--claude-config-dirs` additions, de-duplicating.
        let claudeConfigDirDefaults = ClaudeConfigDirs.defaults(homeDirectory: "/Users/example")
        guard claudeConfigDirDefaults == [
            "/Users/example/.claude",
            "/Users/example/.claude-config/max",
            "/Users/example/.claude-config/enterprise",
        ] else {
            throw CLIError.runtime("ClaudeConfigDirs.defaults self-test failed")
        }
        let claudeConfigDirResolved = ClaudeConfigDirs.resolved(
            additional: ["/extra/claude-config", "/Users/example/.claude"],
            homeDirectory: "/Users/example"
        )
        guard claudeConfigDirResolved == [
            "/Users/example/.claude",
            "/Users/example/.claude-config/max",
            "/Users/example/.claude-config/enterprise",
            "/extra/claude-config",
        ] else {
            throw CLIError.runtime("ClaudeConfigDirs.resolved self-test failed")
        }

        // M3: transcript-mtime stale GC judgment -- fresh transcript is not
        // stale, a transcript older than the threshold is, and a missing
        // transcript is never treated as stale (avoids false-positive GC of
        // a brand-new session or a wrong configDir/cwd pairing).
        let transcriptFixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-claude-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: transcriptFixtureRoot) }
        let transcriptCWD = "/Users/dev/some-repo"
        let transcriptProjectDir = transcriptFixtureRoot
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeSessionsCatalog.flattenedProjectDirectoryName(cwd: transcriptCWD))
        try FileManager.default.createDirectory(at: transcriptProjectDir, withIntermediateDirectories: true)
        guard ClaudeSessionsCatalog.flattenedProjectDirectoryName(cwd: transcriptCWD) == "-Users-dev-some-repo" else {
            throw CLIError.runtime("Claude transcript path flattening self-test failed")
        }
        let transcriptURL = transcriptProjectDir.appendingPathComponent("stale-transcript-session.jsonl")
        try Data("{}".utf8).write(to: transcriptURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: transcriptURL.path
        )
        guard ClaudeSessionsCatalog.isTranscriptStale(
            configDir: transcriptFixtureRoot.path,
            cwd: transcriptCWD,
            sessionID: "stale-transcript-session",
            staleAfter: 1_800
        ) else {
            throw CLIError.runtime("Claude transcript stale-GC (stale case) self-test failed")
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: transcriptURL.path
        )
        guard !ClaudeSessionsCatalog.isTranscriptStale(
            configDir: transcriptFixtureRoot.path,
            cwd: transcriptCWD,
            sessionID: "stale-transcript-session",
            staleAfter: 1_800
        ) else {
            throw CLIError.runtime("Claude transcript stale-GC (fresh case) self-test failed")
        }
        guard !ClaudeSessionsCatalog.isTranscriptStale(
            configDir: transcriptFixtureRoot.path,
            cwd: transcriptCWD,
            sessionID: "never-written-session",
            staleAfter: 1_800
        ) else {
            throw CLIError.runtime("Claude transcript stale-GC (missing-file case) self-test failed")
        }

        // M3: dedup priority (claudeHerdr > claudeDesktop > claudeTerminal,
        // first-wins) -- a herdr-reported and a terminal-reported session
        // sharing the same session id must resolve to the herdr entry, and
        // an unrelated third session must pass through untouched.
        let dedupHerdrEntry = AgentSession(
            sourceKind: .claudeHerdr,
            sessionID: "shared-session",
            cwd: "/repo/from-herdr",
            rowHints: .none,
            recency: 1,
            rowRank: nil,
            columnRank: nil,
            seedStatus: nil,
            navigation: .herdrPane(paneID: "w1:p1")
        )
        let dedupTerminalEntry = AgentSession(
            sourceKind: .claudeTerminal,
            sessionID: "shared-session",
            cwd: "/repo/from-terminal",
            rowHints: .none,
            recency: 1,
            rowRank: nil,
            columnRank: nil,
            seedStatus: nil,
            navigation: .ghosttyTab(sessionID: "shared-session", cwd: "/repo/from-terminal", pid: 555)
        )
        let dedupUnrelatedEntry = AgentSession(
            sourceKind: .claudeTerminal,
            sessionID: "solo-session",
            cwd: "/repo/solo",
            rowHints: .none,
            recency: 1,
            rowRank: nil,
            columnRank: nil,
            seedStatus: nil,
            navigation: .ghosttyTab(sessionID: "solo-session", cwd: "/repo/solo", pid: 666)
        )
        let dedupResolved = SessionSourceDedup.resolve([dedupTerminalEntry, dedupHerdrEntry, dedupUnrelatedEntry])
        guard dedupResolved.count == 2,
              dedupResolved.first(where: { $0.sessionID == "shared-session" })?.sourceKind == .claudeHerdr,
              dedupResolved.first(where: { $0.sessionID == "shared-session" })?.cwd == "/repo/from-herdr",
              dedupResolved.first(where: { $0.sessionID == "solo-session" })?.sourceKind == .claudeTerminal else {
            throw CLIError.runtime("Claude session-source dedup priority self-test failed")
        }

        // M4: `local_<uuid>.json` schema decode, confirmed against a real
        // file written by a live Claude Desktop install (see M4
        // investigation notes -- fields beyond the ones declared here, e.g.
        // `enabledMcpTools`/`spawnSeed`/`remoteMcpServersConfig`, are present
        // in the real file and simply ignored).
        let claudeDesktopSessionFileJSON = """
        {
          "sessionId": "local_cd0c64c6-feb1-4568-ae81-db30f88d39fe",
          "cliSessionId": "5a7a3295-e4c7-4189-90c3-aa3140529c71",
          "cwd": "/Users/dev/repo",
          "originCwd": "/Users/dev/repo",
          "lastFocusedAt": 1788232819595,
          "createdAt": 1788226254674,
          "lastActivityAt": 1788232819550,
          "model": "claude-opus-5[1m]",
          "isArchived": false,
          "title": "Example title",
          "permissionMode": "auto",
          "enabledMcpTools": {},
          "remoteMcpServersConfig": []
        }
        """
        let claudeDesktopSessionFileEntry = try JSONDecoder().decode(
            ClaudeDesktopSessionFileEntry.self,
            from: Data(claudeDesktopSessionFileJSON.utf8)
        )
        guard claudeDesktopSessionFileEntry.sessionID == "local_cd0c64c6-feb1-4568-ae81-db30f88d39fe",
              claudeDesktopSessionFileEntry.cliSessionID == "5a7a3295-e4c7-4189-90c3-aa3140529c71",
              claudeDesktopSessionFileEntry.cwd == "/Users/dev/repo",
              claudeDesktopSessionFileEntry.isArchived == false,
              claudeDesktopSessionFileEntry.lastActivityAt == 1_788_232_819_550 else {
            throw CLIError.runtime("Claude Desktop local_*.json schema decode self-test failed")
        }

        // M4: liveness judgment -- fresh `lastActivityAt` is recent, one well
        // past the 6-hour default window is not, and archived sessions are
        // never recent regardless of timestamp (that check lives in
        // `ClaudeDesktopCatalog.snapshot()` itself, exercised via the full
        // scan below).
        let claudeDesktopNow = Date(timeIntervalSince1970: 1_788_240_000)
        guard ClaudeDesktopCatalog.isRecent(
            epochMilliseconds: 1_788_232_819_550,
            now: claudeDesktopNow,
            within: ClaudeDesktopCatalog.defaultStaleAfter
        ) else {
            throw CLIError.runtime("Claude Desktop recency judgment (recent case) self-test failed")
        }
        guard !ClaudeDesktopCatalog.isRecent(
            epochMilliseconds: 1_788_232_819_550 - 7 * 60 * 60 * 1_000,
            now: claudeDesktopNow,
            within: ClaudeDesktopCatalog.defaultStaleAfter
        ) else {
            throw CLIError.runtime("Claude Desktop recency judgment (stale case) self-test failed")
        }
        guard !ClaudeDesktopCatalog.isRecent(epochMilliseconds: nil, now: claudeDesktopNow, within: ClaudeDesktopCatalog.defaultStaleAfter) else {
            throw CLIError.runtime("Claude Desktop recency judgment (missing timestamp case) self-test failed")
        }

        // M4: full `ClaudeDesktopCatalog.snapshot()` scan against a real
        // two-level `<accountId>/<workspaceId>/local_*.json` temp-directory
        // layout -- covers archived exclusion, stale-timestamp exclusion,
        // hook-registered lifetime extension past the timestamp window, and
        // the "Desktop isn't running" short-circuit. Only `isDesktopRunning`/
        // `isHookRegistered`/`now` are faked.
        let claudeDesktopFixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-claude-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: claudeDesktopFixtureRoot) }
        let claudeDesktopWorkspaceDir = claudeDesktopFixtureRoot
            .appendingPathComponent("account-1")
            .appendingPathComponent("workspace-1")
        try FileManager.default.createDirectory(at: claudeDesktopWorkspaceDir, withIntermediateDirectories: true)

        func writeClaudeDesktopFixture(name: String, cliSessionID: String, cwd: String, isArchived: Bool, lastActivityAt: Double) throws {
            let json = """
            {"sessionId":"local_\(UUID().uuidString)","cliSessionId":"\(cliSessionID)","cwd":"\(cwd)","isArchived":\(isArchived),"lastActivityAt":\(lastActivityAt)}
            """
            try Data(json.utf8).write(to: claudeDesktopWorkspaceDir.appendingPathComponent(name))
        }
        let claudeDesktopNowMillis = claudeDesktopNow.timeIntervalSince1970 * 1_000
        // Recently active, not archived -- must survive.
        try writeClaudeDesktopFixture(
            name: "local_recent.json",
            cliSessionID: "desktop-recent",
            cwd: "/repo/desktop-recent",
            isArchived: false,
            lastActivityAt: claudeDesktopNowMillis - 60_000
        )
        // Not archived, but 7 hours stale and never hook-registered -- must
        // be excluded.
        try writeClaudeDesktopFixture(
            name: "local_stale.json",
            cliSessionID: "desktop-stale",
            cwd: "/repo/desktop-stale",
            isArchived: false,
            lastActivityAt: claudeDesktopNowMillis - 7 * 60 * 60 * 1_000
        )
        // Archived, even though recently active -- must always be excluded.
        try writeClaudeDesktopFixture(
            name: "local_archived.json",
            cliSessionID: "desktop-archived",
            cwd: "/repo/desktop-archived",
            isArchived: true,
            lastActivityAt: claudeDesktopNowMillis - 60_000
        )
        // 7 hours stale by timestamp, but hook-registered -- hooks are
        // authoritative, so this must survive anyway.
        try writeClaudeDesktopFixture(
            name: "local_hook_kept_alive.json",
            cliSessionID: "desktop-hook-kept-alive",
            cwd: "/repo/desktop-hook-kept-alive",
            isArchived: false,
            lastActivityAt: claudeDesktopNowMillis - 7 * 60 * 60 * 1_000
        )
        let claudeDesktopCatalogFixture = ClaudeDesktopCatalog(
            desktopSessionsDir: claudeDesktopFixtureRoot.path,
            staleAfter: ClaudeDesktopCatalog.defaultStaleAfter,
            isDesktopRunning: { true },
            isHookRegistered: { $0 == "desktop-hook-kept-alive" },
            now: { claudeDesktopNow }
        )
        let claudeDesktopCatalogSnapshot = try claudeDesktopCatalogFixture.snapshot()
        guard Set(claudeDesktopCatalogSnapshot.map(\.sessionID)) == ["desktop-recent", "desktop-hook-kept-alive"],
              claudeDesktopCatalogSnapshot.allSatisfy({ $0.sourceKind == .claudeDesktop && $0.navigation == .claudeDesktop }),
              claudeDesktopCatalogSnapshot.first(where: { $0.sessionID == "desktop-recent" })?.cwd == "/repo/desktop-recent" else {
            throw CLIError.runtime("ClaudeDesktopCatalog.snapshot self-test failed")
        }

        // M4: when Claude Desktop isn't running, the snapshot is always
        // empty regardless of what's on disk -- a quit app can never
        // navigate anywhere and can't fire `SessionEnd` for what it had
        // open, so holding those sessions alive would light dead keys
        // forever.
        let claudeDesktopNotRunningFixture = ClaudeDesktopCatalog(
            desktopSessionsDir: claudeDesktopFixtureRoot.path,
            isDesktopRunning: { false },
            now: { claudeDesktopNow }
        )
        guard try claudeDesktopNotRunningFixture.snapshot().isEmpty else {
            throw CLIError.runtime("ClaudeDesktopCatalog app-not-running self-test failed")
        }

        // M4: needs-input routing branch -- approval status routes to
        // Desktop's needs-input list, every other status (including no
        // status at all) just activates the app. This only exercises the
        // pure decision function, never `NSWorkspace`/`open`, so no
        // `claude://` URL is ever actually opened by the self-test.
        guard NavigationRouter.claudeDesktopAction(forStatus: .approval) == .openNeedsInput else {
            throw CLIError.runtime("Claude Desktop needs-input routing (approval case) self-test failed")
        }
        for otherStatus: AgentStatus? in [.idle, .working, .done, .error, nil] {
            guard NavigationRouter.claudeDesktopAction(forStatus: otherStatus) == .activateOnly else {
                throw CLIError.runtime("Claude Desktop needs-input routing (non-approval case) self-test failed status=\(String(describing: otherStatus))")
            }
        }

        // M3: `NavigationTarget.ghosttyTab` now carries cwd/pid (used by
        // `ClaudeSessionsCatalog.snapshot()`'s pid-bearing entries above and
        // `Daemon.claudeNavigationTarget`'s hook-derived, pid-less ones).
        let ghosttyTargetFromScan = NavigationTarget.ghosttyTab(sessionID: "gt", cwd: "/tmp/gt-project", pid: 777)
        guard case let .ghosttyTab(sessionID, cwd, pid) = ghosttyTargetFromScan,
              sessionID == "gt", cwd == "/tmp/gt-project", pid == 777 else {
            throw CLIError.runtime("Ghostty navigation target self-test failed")
        }

        // M3: AppleScript argv passthrough is injection-safe -- a cwd
        // containing quotes, ampersands, and AppleScript-looking text comes
        // back byte-for-byte unmodified rather than being interpreted, since
        // it's bound via `on run argv` rather than interpolated into the
        // script text. This deliberately never touches Ghostty (or any
        // other app) -- the probe script only echoes its argument back.
        let argvEchoScript = """
        on run argv
            return item 1 of argv
        end run
        """
        let injectionAttemptCWD = #"/tmp/weird "quote" & tell application "Finder" to activate -- end"#
        let argvEchoOutput = try OsascriptRunner.run(
            arguments: ["-e", argvEchoScript, injectionAttemptCWD],
            timeout: 2
        )
        guard String(decoding: argvEchoOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            == injectionAttemptCWD else {
            throw CLIError.runtime("AppleScript argv injection-safety self-test failed")
        }
        var osascriptTimedOut = false
        do {
            _ = try OsascriptRunner.run(arguments: ["-e", "delay 2"], timeout: 0.1)
        } catch let error as OsascriptRunner.RunError {
            if case .timedOut = error { osascriptTimedOut = true }
        }
        guard osascriptTimedOut else {
            throw CLIError.runtime("OsascriptRunner timeout self-test failed")
        }

        try selfTestClaudeHooksInstaller()

        print("self-test passed: hooks, Codex catalog, herdr catalog, Claude sessions catalog, Claude Desktop catalog, Ghostty AppleScript navigation, project/session grid, privileged grabber, daemon messages, RGB reports, keymap reports, physical-key resolution, and install-claude-hooks")
    }

    /// M-install-claude-hooks: exercises `ClaudeHooksInstaller` end to end
    /// against synthetic `settings.json` fixtures in a temporary directory
    /// (never against the real `~/.claude*` profiles). Covers: install onto
    /// a herdr-bearing file (all 9 events added, herdr entries kept),
    /// re-install is a no-op, a binary-path change is picked up as an
    /// update (no duplicate entries), `--dry-run` writes nothing,
    /// `--uninstall` removes only the c100 entries, and a malformed
    /// `settings.json` is left untouched and reported as an error.
    private static func selfTestClaudeHooksInstaller() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c100-status-claude-hooks-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profileDir = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let settingsPath = profileDir.appendingPathComponent("settings.json").path

        let herdrFixture = """
        {
          "hooks": {
            "SessionStart": [
              { "matcher": "startup", "hooks": [ { "type": "command", "command": "/opt/herdr/hooks/herdr-agent-state.sh session-start", "timeout": 5 } ] }
            ],
            "PreToolUse": [
              { "hooks": [ { "type": "command", "command": "/opt/herdr/hooks/herdr-agent-state.sh pre-tool" } ] }
            ]
          },
          "otherTopLevelKey": { "foo": "bar" }
        }
        """
        try Data(herdrFixture.utf8).write(to: URL(fileURLWithPath: settingsPath))

        func readSettings() throws -> [String: Any] {
            let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.runtime("install-claude-hooks self-test: settings.json did not decode as an object")
            }
            return object
        }
        func hookCommands(_ settings: [String: Any], event: String) -> [String] {
            guard let hooks = settings["hooks"] as? [String: Any], let entries = hooks[event] as? [[String: Any]] else { return [] }
            return entries.flatMap { entry -> [String] in
                (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
        func backupCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: profileDir.path))?
                .filter { $0.contains(".c100-backup-") }.count ?? 0
        }

        // 1. Install onto the herdr fixture: all 9 events gain a c100 entry,
        // herdr's untouched, unrelated top-level key preserved, one backup written.
        let binaryA = "/tmp/c100-status-fake-a"
        let installResults = ClaudeHooksInstaller.run(configDirs: [profileDir.path], binaryPath: binaryA, dryRun: false, uninstall: false)
        guard installResults.count == 1, installResults[0].status == .installed else {
            throw CLIError.runtime("install-claude-hooks self-test: initial install status was not .installed")
        }
        guard backupCount() == 1 else {
            throw CLIError.runtime("install-claude-hooks self-test: initial install did not write exactly one backup")
        }
        var settings = try readSettings()
        guard (settings["otherTopLevelKey"] as? [String: Any])?["foo"] as? String == "bar" else {
            throw CLIError.runtime("install-claude-hooks self-test: unrelated top-level key was not preserved")
        }
        for event in ClaudeHooksInstaller.eventOrder {
            guard hookCommands(settings, event: event).contains(where: { $0.contains(binaryA) }) else {
                throw CLIError.runtime("install-claude-hooks self-test: event \(event) missing its c100 entry after install")
            }
        }
        guard hookCommands(settings, event: "SessionStart").contains(where: { $0.contains("herdr-agent-state.sh") }),
              hookCommands(settings, event: "PreToolUse").contains(where: { $0.contains("herdr-agent-state.sh") }) else {
            throw CLIError.runtime("install-claude-hooks self-test: herdr entries were dropped by install")
        }
        guard hookCommands(settings, event: "Notification").filter({ $0.contains(binaryA) }).count == 4 else {
            throw CLIError.runtime("install-claude-hooks self-test: Notification should gain exactly 4 c100 entries")
        }

        // 2. Re-install with the same binary path: unchanged, no new backup.
        let reinstallResults = ClaudeHooksInstaller.run(configDirs: [profileDir.path], binaryPath: binaryA, dryRun: false, uninstall: false)
        guard reinstallResults.count == 1, reinstallResults[0].status == .unchanged, backupCount() == 1 else {
            throw CLIError.runtime("install-claude-hooks self-test: re-install with the same binary path was not a no-op")
        }

        // 3. Install with a different binary path: updated, old command gone, no duplicates.
        let binaryB = "/tmp/c100-status-fake-b"
        let updateResults = ClaudeHooksInstaller.run(configDirs: [profileDir.path], binaryPath: binaryB, dryRun: false, uninstall: false)
        guard updateResults.count == 1, updateResults[0].status == .updated, backupCount() == 2 else {
            throw CLIError.runtime("install-claude-hooks self-test: binary-path change was not reported as .updated")
        }
        settings = try readSettings()
        for event in ClaudeHooksInstaller.eventOrder {
            let commands = hookCommands(settings, event: event)
            guard commands.contains(where: { $0.contains(binaryB) }), !commands.contains(where: { $0.contains(binaryA) }) else {
                throw CLIError.runtime("install-claude-hooks self-test: event \(event) did not cleanly switch to the new binary path")
            }
        }
        guard hookCommands(settings, event: "SessionStart").contains(where: { $0.contains("herdr-agent-state.sh") }) else {
            throw CLIError.runtime("install-claude-hooks self-test: herdr entry lost across a binary-path update")
        }

        // 4. --uninstall removes only the c100 entries; herdr's remain.
        let uninstallResults = ClaudeHooksInstaller.run(configDirs: [profileDir.path], binaryPath: binaryB, dryRun: false, uninstall: true)
        guard uninstallResults.count == 1, uninstallResults[0].status == .uninstalled else {
            throw CLIError.runtime("install-claude-hooks self-test: uninstall was not reported as .uninstalled")
        }
        settings = try readSettings()
        let hooksAfterUninstall = settings["hooks"] as? [String: Any] ?? [:]
        for event in ClaudeHooksInstaller.eventOrder where event != "SessionStart" && event != "PreToolUse" {
            guard hooksAfterUninstall[event] == nil else {
                throw CLIError.runtime("install-claude-hooks self-test: event \(event) should have been removed entirely by uninstall")
            }
        }
        guard hookCommands(settings, event: "SessionStart") == ["/opt/herdr/hooks/herdr-agent-state.sh session-start"],
              hookCommands(settings, event: "PreToolUse") == ["/opt/herdr/hooks/herdr-agent-state.sh pre-tool"] else {
            throw CLIError.runtime("install-claude-hooks self-test: herdr entries were not left intact by uninstall")
        }
        let reuninstallResults = ClaudeHooksInstaller.run(configDirs: [profileDir.path], binaryPath: binaryB, dryRun: false, uninstall: true)
        guard reuninstallResults.count == 1, reuninstallResults[0].status == .unchanged else {
            throw CLIError.runtime("install-claude-hooks self-test: re-uninstall was not a no-op")
        }

        // 5. --dry-run reports the change but never touches disk.
        let dryRunProfileDir = root.appendingPathComponent("dry-run-profile")
        try FileManager.default.createDirectory(at: dryRunProfileDir, withIntermediateDirectories: true)
        let dryRunSettingsPath = dryRunProfileDir.appendingPathComponent("settings.json").path
        try Data(#"{"hooks":{}}"#.utf8).write(to: URL(fileURLWithPath: dryRunSettingsPath))
        let beforeDryRun = try Data(contentsOf: URL(fileURLWithPath: dryRunSettingsPath))
        let dryRunResults = ClaudeHooksInstaller.run(configDirs: [dryRunProfileDir.path], binaryPath: binaryA, dryRun: true, uninstall: false)
        let afterDryRun = try Data(contentsOf: URL(fileURLWithPath: dryRunSettingsPath))
        guard dryRunResults.count == 1, dryRunResults[0].status == .installed, beforeDryRun == afterDryRun else {
            throw CLIError.runtime("install-claude-hooks self-test: --dry-run reported wrong status or modified the file")
        }

        // 6. A missing settings.json is skipped, not created.
        let missingProfileDir = root.appendingPathComponent("missing-profile")
        try FileManager.default.createDirectory(at: missingProfileDir, withIntermediateDirectories: true)
        let missingResults = ClaudeHooksInstaller.run(configDirs: [missingProfileDir.path], binaryPath: binaryA, dryRun: false, uninstall: false)
        guard missingResults.count == 1, missingResults[0].status == .skipped else {
            throw CLIError.runtime("install-claude-hooks self-test: a config dir with no settings.json should be .skipped")
        }

        // 7. A malformed settings.json is left byte-for-byte untouched and reported as .error.
        let brokenProfileDir = root.appendingPathComponent("broken-profile")
        try FileManager.default.createDirectory(at: brokenProfileDir, withIntermediateDirectories: true)
        let brokenSettingsPath = brokenProfileDir.appendingPathComponent("settings.json").path
        let brokenContents = Data("{ not valid json".utf8)
        try brokenContents.write(to: URL(fileURLWithPath: brokenSettingsPath))
        let brokenResults = ClaudeHooksInstaller.run(configDirs: [brokenProfileDir.path], binaryPath: binaryA, dryRun: false, uninstall: false)
        let brokenAfter = try Data(contentsOf: URL(fileURLWithPath: brokenSettingsPath))
        guard brokenResults.count == 1, brokenResults[0].status == .error, brokenAfter == brokenContents else {
            throw CLIError.runtime("install-claude-hooks self-test: malformed settings.json should be left untouched and reported as .error")
        }
    }

    private static func writeDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data("c100-status: \(message)\n".utf8))
    }

    private static func hex(_ value: Int, width: Int) -> String {
        String(format: "%0*X", width, value)
    }

    private static func printHelp() {
        print("""
        Usage:
          c100-status run [--location 0x110000] [--socket PATH] [--log-file PATH] [--grabber-socket PATH] [--dry-run] [--herdr-bin PATH] [--claude-config-dirs DIR1,DIR2,...] [--claude-desktop-dir PATH]
          sudo c100-status install-helper --location 0x110000
          sudo c100-status uninstall-helper
          c100-status grabber-status [--grabber-socket PATH]
          c100-status status <idle|working|approval|done|error> [--socket PATH]
          c100-status key <0...99> <off|white|red|green|blue|amber> [--socket PATH]
          c100-status hook [--socket PATH] [--dry-run] [--source <codex|claude>] [--notification-matcher <permission_prompt|idle_prompt|agent_needs_input|agent_completed>]
                                                          # reads hook JSON on stdin; --source defaults to codex
          c100-status clear [--socket PATH]
          c100-status ping [--socket PATH]
          c100-status logs [--log-file PATH]
          c100-status log-path [--log-file PATH]
          c100-status list
          c100-status catalog
          c100-status request-input-access
          c100-status watch-input [SECONDS] [--location 0x110000]
          c100-status watch-matrix [SECONDS] [--location 0x110000]
          c100-status apply <status> [--location 0x110000] [--dry-run]
          c100-status install-claude-hooks [--config-dir PATH]... [--binary PATH] [--dry-run] [--uninstall]
          c100-status self-test

        `install-claude-hooks` idempotently adds this binary's `hook --source claude` entries to each Claude Code profile's settings.json (default config dirs: ~/.claude, ~/.claude-config/max, ~/.claude-config/enterprise, plus any other ~/.claude-config/* subdirectory), alongside any existing hooks (e.g. herdr's) without touching them. Repeat `--config-dir` to override the default set; `--binary` overrides the auto-detected absolute path to this executable. `--dry-run` reports planned changes without writing. `--uninstall` removes only the c100-managed entries. Each write is preceded by a `settings.json.c100-backup-<epoch-ms>` backup; a config dir with no settings.json is skipped, and unparseable settings.json is left untouched and reported as an error.
        `--herdr-bin` overrides the herdr binary path (else `HERDR_BIN` env, else /opt/homebrew/bin/herdr, /usr/local/bin/herdr, ~/.cargo/bin/herdr).
        If herdr can't be resolved, herdr support is silently disabled (logged once at INFO).
        `--claude-config-dirs` adds extra Claude profile directories (scanned for sessions/<pid>.json) on top of the defaults: ~/.claude, ~/.claude-config/max, ~/.claude-config/enterprise.
        `--claude-desktop-dir` overrides where Claude Desktop's session files are scanned from (default: ~/Library/Application Support/Claude/claude-code-sessions).
        `install-helper` performs the one-time root-owned LaunchDaemon installation.
        `run` then stays in the foreground as the user, leases exclusive C100 capture from the helper, and logs to stdout plus the log file.
        While `run` is active, normal C100 keystrokes are suppressed and assigned keys navigate Codex tasks.
        HID writes are volatile; SaveLedConf is never sent.
        """)
    }
}

do {
    try C100StatusCLI.run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("c100-status: \(error)\n".utf8))
    Darwin.exit(1)
}
