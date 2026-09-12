import Foundation

/// Product-specific database formats stay in their adapters; filesystem locations
/// are injected together so catalog, fork, approval and rollout reads agree.
struct CodexPaths {
    let home: String
    let catalogDatabase: String
    let stateDatabase: String
    let sidebarState: String

    init(homeDirectory: String = NSHomeDirectory(), home: String? = nil,
         catalogDatabase: String? = nil, stateDatabase: String? = nil, sidebarState: String? = nil) {
        self.home = home ?? homeDirectory + "/.codex"
        self.catalogDatabase = catalogDatabase ?? self.home + "/sqlite/codex-dev.db"
        self.stateDatabase = stateDatabase ?? self.home + "/state_5.sqlite"
        self.sidebarState = sidebarState ?? self.home + "/.codex-global-state.json"
    }
}

struct Configuration: Codable {
    var schemaVersion: Int? = 1
    var layoutPath: String?
    var backend: String?
    var locationID: String?
    var claudeConfigDirs: [String]?
    var claudeDesktopSessionsDir: String?
    var claudeDesktopConfigDir: String?
    var codexHome: String?
    var codexCatalogDatabase: String?
    var codexStateDatabase: String?
    var codexSidebarState: String?
    var herdrBinary: String?
    var defaultLayer: String?
    var socketPath: String?
    var logPath: String?
    var grabberSocketPath: String?

    static let keys: Set<String> = [
        "schemaVersion", "layoutPath", "backend", "locationID", "claudeConfigDirs",
        "claudeDesktopSessionsDir", "claudeDesktopConfigDir", "codexHome",
        "codexCatalogDatabase", "codexStateDatabase", "codexSidebarState",
        "herdrBinary", "defaultLayer", "socketPath", "logPath", "grabberSocketPath"
    ]

    static func path(_ raw: String, relativeTo base: String, home: String = NSHomeDirectory()) throws -> String {
        guard !raw.isEmpty, !raw.contains("\0") else {
            throw CLIError.usage("Configuration paths must be nonempty file/directory paths")
        }
        let expanded: String
        if raw == "~" { expanded = home }
        else if raw.hasPrefix("~/") { expanded = home + String(raw.dropFirst()) }
        else if raw.hasPrefix("~") { throw CLIError.usage("Use ~/path or an absolute path; ~other-user is unsupported") }
        else { expanded = raw }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardizedFileURL.path
    }

    static func defaultPath(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        (environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config") + "/c100-status/config.json"
    }

    static func load(explicitPath: String?, allowMissing: Bool = false,
                     home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                     cwd: String = FileManager.default.currentDirectoryPath) throws -> (Configuration, String?, String) {
        let requested = explicitPath ?? environment["C100_STATUS_CONFIG"]
        let target = try path(requested ?? defaultPath(home: home, environment: environment), relativeTo: cwd, home: home)
        guard FileManager.default.fileExists(atPath: target) else {
            if requested != nil && !allowMissing { throw CLIError.usage("Configuration file not found: \(target)") }
            return (Configuration(), nil, target)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: target).resolvingSymlinksInPath().path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 65536 else {
            throw CLIError.usage("Configuration must be a regular JSON file of at most 64 KiB: \(target)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: target))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.usage("Configuration must be a JSON object: \(target)")
        }
        let unknown = Set(object.keys).subtracting(keys)
        guard unknown.isEmpty else { throw CLIError.usage("Unknown configuration keys: \(unknown.sorted().joined(separator: ", "))") }
        guard !object.values.contains(where: { $0 is NSNull }) else {
            throw CLIError.usage("Omit unset configuration keys instead of using null")
        }
        var document = try JSONDecoder().decode(Configuration.self, from: data)
        try document.validate()
        let base = URL(fileURLWithPath: target).deletingLastPathComponent().path
        try document.normalizePaths(relativeTo: base, home: home)
        return (document, target, target)
    }

    mutating func normalizePaths(relativeTo base: String, home: String = NSHomeDirectory()) throws {
        if let dirs = claudeConfigDirs {
            claudeConfigDirs = try Self.uniquePaths(dirs, relativeTo: base, home: home)
        }
        for key in [\Configuration.layoutPath, \.claudeDesktopSessionsDir, \.claudeDesktopConfigDir, \.codexHome,
                    \.codexCatalogDatabase, \.codexStateDatabase, \.codexSidebarState, \.herdrBinary,
                    \.socketPath, \.logPath, \.grabberSocketPath] {
            if let value = self[keyPath: key] { self[keyPath: key] = try Self.path(value, relativeTo: base, home: home) }
        }
    }

    static func uniquePaths(_ paths: [String], relativeTo base: String, home: String = NSHomeDirectory()) throws -> [String] {
        var seen = Set<String>()
        return try paths.map { try path($0, relativeTo: base, home: home) }.filter { seen.insert($0).inserted }
    }

    func validate() throws {
        guard schemaVersion == nil || schemaVersion == 1 else { throw CLIError.usage("Unsupported configuration schemaVersion; expected 1") }
        if let backend, !["stock", "companion"].contains(backend) { throw CLIError.usage("backend must be stock or companion") }
        if let defaultLayer, SessionSourceKind(rawValue: defaultLayer) == nil { throw CLIError.usage("Unknown defaultLayer: \(defaultLayer)") }
        if let locationID { _ = try Self.location(locationID) }
    }

    static func location(_ raw: String) throws -> Int? {
        if raw == "auto" { return nil }
        let value = raw.lowercased().hasPrefix("0x") ? UInt32(raw.dropFirst(2), radix: 16) : UInt32(raw)
        guard let value else { throw CLIError.usage("locationID must be auto or a 32-bit decimal/0x-prefixed integer") }
        return Int(value)
    }

    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self); data.append(10); return data
    }

    static var example: Configuration {
        var example = Configuration()
        example.backend = "stock"; example.locationID = "auto"
        example.claudeConfigDirs = ["~/.claude"]
        example.codexHome = "~/.codex"; example.defaultLayer = "codex"
        return example
    }
}

extension Options {
    mutating func apply(_ configuration: Configuration, environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: String = NSHomeDirectory(), cwd: String = FileManager.default.currentDirectoryPath) throws {
        if !providedFlags.contains("--companion") && !providedFlags.contains("--backend") { companion = configuration.backend == "companion" }
        if !providedFlags.contains("--location"), let location = configuration.locationID { locationID = try Configuration.location(location) }
        if !providedFlags.contains("--claude-config-dirs") {
            claudeConfigDirs = configuration.claudeConfigDirs ?? [environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"]
        }
        claudeConfigDirs = try Configuration.uniquePaths(claudeConfigDirs, relativeTo: cwd, home: home)
        installClaudeHooksConfigDirs = try Configuration.uniquePaths(installClaudeHooksConfigDirs, relativeTo: cwd, home: home)
        if !providedFlags.contains("--claude-desktop-dir") { claudeDesktopDir = configuration.claudeDesktopSessionsDir ?? ClaudeDesktopCatalog.defaultSessionsDir(homeDirectory: home) }
        if !providedFlags.contains("--claude-desktop-config-dir") { claudeDesktopConfigDir = configuration.claudeDesktopConfigDir ?? home + "/.claude" }
        if !providedFlags.contains("--herdr-bin") { herdrBinaryPath = configuration.herdrBinary ?? environment["HERDR_BIN"] }
        if !providedFlags.contains("--codex-home") { codexHome = configuration.codexHome ?? environment["CODEX_HOME"] ?? home + "/.codex" }
        if !providedFlags.contains("--default-layer") { defaultLayer = SessionSourceKind(rawValue: configuration.defaultLayer ?? "codex")! }
        if !providedFlags.contains("--socket"), let path = configuration.socketPath { socketPath = path }
        if !providedFlags.contains("--log-file"), let path = configuration.logPath { logPath = path }
        if !providedFlags.contains("--grabber-socket"), let path = configuration.grabberSocketPath { grabberSocketPath = path }
        if let hookProfileDir { self.hookProfileDir = try Configuration.path(hookProfileDir, relativeTo: cwd, home: home) }
        layoutPath = configuration.layoutPath ?? URL(fileURLWithPath: configTargetPath ?? Configuration.defaultPath(home: home, environment: environment)).deletingLastPathComponent().appendingPathComponent("layout.json").path
        codexPaths = CodexPaths(home: try Configuration.path(codexHome!, relativeTo: cwd, home: home),
                               catalogDatabase: configuration.codexCatalogDatabase,
                               stateDatabase: configuration.codexStateDatabase, sidebarState: configuration.codexSidebarState)
        claudeDesktopDir = try Configuration.path(claudeDesktopDir!, relativeTo: cwd, home: home)
        claudeDesktopConfigDir = try Configuration.path(claudeDesktopConfigDir, relativeTo: cwd, home: home)
        if let binary = herdrBinaryPath { herdrBinaryPath = try Configuration.path(binary, relativeTo: cwd, home: home) }
        socketPath = try Configuration.path(socketPath, relativeTo: cwd, home: home)
        logPath = try Configuration.path(logPath, relativeTo: cwd, home: home)
        grabberSocketPath = try Configuration.path(grabberSocketPath, relativeTo: cwd, home: home)
    }

    func effectiveConfiguration() -> Configuration {
        var c = Configuration()
        c.layoutPath = layoutPath
        c.backend = companion ? "companion" : "stock"
        c.locationID = locationID.map { "0x" + String($0, radix: 16) } ?? "auto"
        c.claudeConfigDirs = claudeConfigDirs; c.claudeDesktopSessionsDir = claudeDesktopDir
        c.claudeDesktopConfigDir = claudeDesktopConfigDir; c.herdrBinary = herdrBinaryPath
        c.codexHome = codexPaths.home; c.codexCatalogDatabase = codexPaths.catalogDatabase
        c.codexStateDatabase = codexPaths.stateDatabase; c.codexSidebarState = codexPaths.sidebarState
        c.defaultLayer = defaultLayer.rawValue
        c.socketPath = socketPath; c.logPath = logPath; c.grabberSocketPath = grabberSocketPath
        return c
    }

    /// Preserve the file reference, not a stale snapshot of its values. Explicit
    /// CLI overrides are persisted so launchd reproduces this invocation.
    var launchArguments: [String] {
        var args: [String] = []
        if let loadedConfigPath { args += ["--config", loadedConfigPath] }
        for (flag, value) in [("--socket", socketPath), ("--log-file", logPath), ("--grabber-socket", grabberSocketPath),
                              ("--herdr-bin", herdrBinaryPath), ("--claude-desktop-dir", claudeDesktopDir),
                              ("--claude-desktop-config-dir", claudeDesktopConfigDir), ("--codex-home", codexPaths.home),
                              ("--default-layer", defaultLayer.rawValue)] {
            if providedFlags.contains(flag), let value { args += [flag, value] }
        }
        if providedFlags.contains("--claude-config-dirs") { args += ["--claude-config-dirs", claudeConfigDirs.joined(separator: ",")] }
        if providedFlags.contains("--location") { args += ["--location", locationID.map { "0x" + String($0, radix: 16) } ?? "auto"] }
        if providedFlags.contains("--companion") || providedFlags.contains("--backend") { args += ["--backend", companion ? "companion" : "stock"] }
        return args
    }
}
