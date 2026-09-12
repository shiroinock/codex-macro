import Foundation
import SQLite3

/// Integration fixtures exercise actual path consumers, not just JSON decoding.
enum ConfigurationTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c100-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("settings.json")
        func check(_ result: Bool, _ message: String) throws {
            guard result else { throw CLIError.runtime("Configuration self-test: " + message) }
        }
        func load(_ text: String) throws -> Configuration {
            try Data(text.utf8).write(to: config)
            return try Configuration.load(explicitPath: config.path, home: "/fixture/home", environment: [:]).0
        }
        let document = try load(#"{"schemaVersion":1,"backend":"companion","locationID":"0x2110000","claudeConfigDirs":["profiles/team a","profiles/team a","~/custom"],"codexHome":"data","codexCatalogDatabase":"catalog.db","codexStateDatabase":"state.db","codexSidebarState":"sidebar.json","claudeDesktopConfigDir":"desktop-profile","socketPath":"daemon.sock","defaultLayer":"claude-terminal"}"#)
        var options = Options()
        try options.apply(document, environment: ["CLAUDE_CONFIG_DIR": "/wrong", "CODEX_HOME": "/wrong"], home: "/fixture/home", cwd: "/")
        try check(options.claudeConfigDirs == [root.path + "/profiles/team a", "/fixture/home/custom"], "profiles must replace defaults and deduplicate")
        try check(options.companion && options.locationID == 0x2110000 && options.defaultLayer == .claudeTerminal, "device/default layer")
        try check(options.codexPaths.home == root.path + "/data" && options.socketPath == root.path + "/daemon.sock", "config-relative paths")
        options.providedFlags = ["--backend", "--claude-config-dirs", "--codex-home"]
        options.companion = false; options.claudeConfigDirs = ["cli-profile"]
        options.codexHome = "/cli-codex"
        try options.apply(document, environment: [:], home: "/fixture/home", cwd: root.path)
        try check(!options.companion && options.claudeConfigDirs == [root.path + "/cli-profile"] && options.codexPaths.home == "/cli-codex", "CLI precedence")
        var empty = Options(); try empty.apply(try load(#"{"claudeConfigDirs":[]}"#), environment: [:])
        try check(empty.claudeConfigDirs.isEmpty, "explicit empty profile list")
        var environmentOptions = Options()
        try environmentOptions.apply(Configuration(), environment: ["CLAUDE_CONFIG_DIR": "/env/claude", "CODEX_HOME": "/env/codex", "HERDR_BIN": "/env/herdr"], home: "/fixture/home")
        try check(environmentOptions.claudeConfigDirs == ["/env/claude"] && environmentOptions.codexPaths.home == "/env/codex" && environmentOptions.herdrBinaryPath == "/env/herdr", "environment fallback")
        for bad in [#"{"claudeConfigDir":[]}"#, #"{"schemaVersion":2}"#, #"{"backend":"typo"}"#, #"{"locationID":"-1"}"#, #"{"locationID":"0x100000000"}"#, #"{"defaultLayer":"typo"}"#, #"{"claudeConfigDirs":[""]}"#, #"{"claudeConfigDirs":null}"#, #"{"claudeConfigDirs":"x"}"#] {
            var rejected = false
            do { _ = try load(bad) } catch { rejected = true }
            try check(rejected, "reject invalid schema/value: " + bad)
        }
        var missingRejected = false
        do { _ = try Configuration.load(explicitPath: root.path + "/absent", environment: [:]) } catch { missingRejected = true }
        try check(missingRejected, "explicit missing file must fail")
        let (_, absent, target) = try Configuration.load(explicitPath: nil, home: root.path, environment: ["XDG_CONFIG_HOME": root.path])
        try check(absent == nil && target == root.path + "/c100-status/config.json", "optional XDG default")

        // launchd must keep the file reference and explicit overrides, not freeze
        // config-derived values such as backend/location on each installation.
        options.loadedConfigPath = config.path
        let args = options.launchArguments
        let plistData = AgentInstaller.plist(label: "fixture", binaryPath: "/tmp/c100-status", locationID: nil, additionalArguments: args, environment: ["PATH": "/fixture/a&b", "CODEX_HOME": "/fixture/codex"])
        let plist = try PropertyListSerialization.propertyList(from: Data(plistData.utf8), format: nil) as! [String: Any]
        try check(plist["EnvironmentVariables"] as? [String: String] == ["PATH": "/fixture/a&b", "CODEX_HOME": "/fixture/codex"], "launchd environment escaping")
        try check(plist["ProgramArguments"] as? [String] == ["/tmp/c100-status", "run"] + args, "launchd argv propagation")
        try check(args.contains(config.path) && !args.contains("--location") && args.suffix(2) == ["--backend", "stock"], "file reference plus CLI override")

        // Custom paths used by both the catalog and sidebar adapter.
        let paths = CodexPaths(home: root.path + "/data", catalogDatabase: root.path + "/catalog.db", stateDatabase: root.path + "/state.db", sidebarState: root.path + "/sidebar.json")
        var db: OpaquePointer?
        try check(sqlite3_open(paths.catalogDatabase, &db) == SQLITE_OK, "open fixture database")
        let sql = "CREATE TABLE local_thread_catalog(thread_id TEXT,cwd TEXT,project_id TEXT,source_recency_at REAL,source_created_at REAL,host_id TEXT,missing_candidate INTEGER); INSERT INTO local_thread_catalog VALUES('fixture-thread','/fixture/repo','fixture-project',1,1,'local',0);"
        let code = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db)
        try check(code == SQLITE_OK, "create fixture catalog")
        try Data(#"{"project-order":["empty","fixture-project"],"thread-project-assignments":{"fixture-thread":{"projectKind":"local","projectId":"fixture-project"}}}"#.utf8).write(to: URL(fileURLWithPath: paths.sidebarState))
        let layout = try CodexCatalog.layout(paths: paths)
        try check(layout.placements.first?.session.sessionID == "fixture-thread" && layout.placements.first?.row == 1, "configured catalog/sidebar reads")
        let provider = try CodexSourceProvider(paths: paths).snapshot()
        try check(provider.first?.sessionID == "fixture-thread", "configured provider path")
        try check(CodexCatalog.projectKey(sessionID: "fixture-thread", paths: paths) == "project:fixture-project", "configured project lookup")

        let rolloutDir = URL(fileURLWithPath: paths.home + "/sessions/1970/01/01")
        try FileManager.default.createDirectory(at: rolloutDir, withIntermediateDirectories: true)
        try Data((#"{"type":"event_msg","payload":{"type":"turn_aborted"}}"# + "\n").utf8).write(to: rolloutDir.appendingPathComponent("rollout-fixture-thread.jsonl"))
        let interrupted = CodexTurnMonitor().interruptedSessionIDs(in: layout.placements.map(\.session), paths: paths)
        try check(interrupted == ["fixture-thread"], "configured rollout discovery")

        let desktopRoot = root.appendingPathComponent("desktop/account/workspace")
        let desktopProfile = root.appendingPathComponent("desktop-profile")
        try FileManager.default.createDirectory(at: desktopRoot, withIntermediateDirectories: true)
        let transcript = URL(fileURLWithPath: ClaudeSessionsCatalog.transcriptPath(configDir: desktopProfile.path, cwd: "/fixture/repo", sessionID: "desktop-thread"))
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: transcript)
        try Data(#"{"sessionId":"local_fixture","cliSessionId":"desktop-thread","cwd":"/fixture/repo","isArchived":false}"#.utf8).write(to: desktopRoot.appendingPathComponent("local_fixture.json"))
        let desktop = try ClaudeDesktopCatalog(desktopSessionsDir: root.path + "/desktop", configDir: desktopProfile.path, isDesktopRunning: { true }).snapshot()
        try check(desktop.first?.sessionID == "desktop-thread", "configured Desktop transcript profile")

        let state = root.appendingPathComponent("review.jsonl")
        try Data(#"{"type":"turn_context","payload":{"approvals_reviewer":"user"}}"#.utf8).write(to: state)
        try check(sqlite3_open(paths.stateDatabase, &db) == SQLITE_OK, "open state fixture")
        let stateSQL = "CREATE TABLE threads(id TEXT, rollout_path TEXT); INSERT INTO threads VALUES('fixture-thread','\(state.path)');"
        let stateCode = sqlite3_exec(db, stateSQL, nil, nil, nil); sqlite3_close(db)
        try check(stateCode == SQLITE_OK, "create state fixture")
        let hook = try JSONDecoder().decode(HookInput.self, from: Data(#"{"session_id":"fixture-thread","hook_event_name":"PermissionRequest"}"#.utf8))
        try check(CodexApprovalRouting.displayRoute(for: hook, paths: paths) == .user(reason: "reviewer_user"), "configured approval database")

        // Installation uses only the supplied profiles and quotes paths containing
        // spaces/apostrophes. A profile is embedded for hooks without an env override.
        let profile = root.appendingPathComponent("profile one's")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("settings.json"))
        let result = ClaudeHooksInstaller.run(configDirs: [profile.path], binaryPath: "/tmp/tool path/c100-status", dryRun: false, uninstall: false, configPath: config.path, socketPath: root.path + "/my socket")
        try check(result.count == 1, "only explicit profiles installed")
        let installed = try String(contentsOf: profile.appendingPathComponent("settings.json"), encoding: .utf8)
        try check(installed.contains("--hook-profile-dir") && installed.contains("--config") && installed.contains("--socket"), "hook settings propagated")
        let payload = "one's folder $(printf unexpected)"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + ClaudeHooksInstaller.shellQuote(payload)]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try check(String(decoding: output, as: UTF8.self) == payload, "shell quoting")
        print("configuration self-test passed: precedence, validation, profile replacement, launchd, hooks, custom Codex paths")
    }
}
