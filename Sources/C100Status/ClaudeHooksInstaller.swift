import Foundation

/// Installs/uninstalls the `c100-status hook --source claude` entries into
/// each Claude Code profile's `settings.json` (see `hooks.claude.example.json`
/// for the canonical event/matcher/timeout/async shape this mirrors). Driven
/// by `c100-status install-claude-hooks` (main.swift).
///
/// Design notes:
/// - **Idempotent.** An existing array entry is considered "c100-managed" if
///   any of its `hooks[].command` strings contain `" hook --source claude"`
///   (see `c100Marker`). On install, all c100-managed entries for an event
///   are dropped and replaced with the canonical set built from the current
///   `binaryPath`; this both re-installs cleanly and picks up a binary path
///   change. Non-c100 entries (herdr's `hooks/herdr-agent-state.sh`, or
///   anything else already present) are left completely untouched and kept
///   in their original array position.
/// - **Never destroys unrelated data.** Only the `hooks` key is rewritten;
///   every other top-level key in `settings.json` round-trips unchanged
///   (modulo `JSONSerialization`'s key ordering, which is not guaranteed).
///   A malformed `settings.json` (parse failure, or a `hooks`/event value
///   that isn't the expected object/array shape) is left on disk untouched
///   and reported as an error for that config dir, never partially written.
/// - **Atomic write with a backup.** Before writing, the original file is
///   copied to `settings.json.c100-backup-<epoch-ms>`; the new content is
///   written with `Data.write(options: .atomic)` (temp file + rename, same
///   pattern as the rest of the codebase's install paths) and the original
///   POSIX permissions are restored afterwards.
enum ClaudeHooksInstaller {
    /// Any hook command containing this substring is treated as owned by
    /// this installer (matches both the plain and
    /// `--notification-matcher ...`-suffixed Notification variants).
    static let c100Marker = " hook --source claude"

    static let eventOrder = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd",
    ]

    enum Status: String {
        case installed, updated, unchanged, uninstalled, skipped, error
    }

    struct FileResult {
        let configDir: String
        let settingsPath: String
        let status: Status
        let message: String
    }

    private struct MalformedSettings: Error {
        let message: String
    }

    // MARK: - Default config dirs

    /// `~/.claude`, `~/.claude-config/max`, `~/.claude-config/enterprise`
    /// (matching `ClaudeConfigDirs.defaults`) plus any other immediate
    /// subdirectory of `~/.claude-config` (a "glob" over future profiles
    /// beyond max/enterprise), deduplicated. Directories that don't exist
    /// are still returned -- `run` reports them as `skipped` rather than
    /// silently omitting them, so the summary always accounts for the full
    /// default set.
    static func defaultInstallConfigDirs(homeDirectory: String = NSHomeDirectory()) -> [String] {
        var dirs = ClaudeConfigDirs.defaults(homeDirectory: homeDirectory)
        let profilesRoot = homeDirectory + "/.claude-config"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: profilesRoot) {
            for entry in entries.sorted() {
                let full = profilesRoot + "/" + entry
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                dirs.append(full)
            }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
    }

    // MARK: - Desired hook shape

    private static func hookCommand(_ command: String, timeout: Int, async: Bool?) -> [String: Any] {
        var dict: [String: Any] = ["type": "command", "command": command, "timeout": timeout]
        if let async {
            dict["async"] = async
        }
        return dict
    }

    private static func entry(matcher: String?, commands: [[String: Any]]) -> [String: Any] {
        var dict: [String: Any] = ["hooks": commands]
        if let matcher {
            dict["matcher"] = matcher
        }
        return dict
    }

    /// Builds the canonical per-event array of "desired" c100 entries for
    /// `binaryPath`, mirroring `hooks.claude.example.json` exactly (event
    /// list, matchers, timeouts, async flags -- including `SessionEnd`'s
    /// lack of an `async` key).
    static func desiredHooks(binaryPath: String) -> [String: [[String: Any]]] {
        let base = "\(binaryPath) hook --source claude"
        let standard = hookCommand(base, timeout: 3, async: true)
        let sessionEnd = hookCommand(base, timeout: 1, async: nil)
        func notification(_ matcher: String) -> [String: Any] {
            hookCommand("\(base) --notification-matcher \(matcher)", timeout: 3, async: true)
        }
        return [
            "SessionStart": [entry(matcher: "startup|resume|clear|compact|fork", commands: [standard])],
            "UserPromptSubmit": [entry(matcher: nil, commands: [standard])],
            "PreToolUse": [entry(matcher: nil, commands: [standard])],
            "PostToolUse": [entry(matcher: nil, commands: [standard])],
            "PermissionRequest": [entry(matcher: nil, commands: [standard])],
            "Notification": [
                entry(matcher: "permission_prompt", commands: [notification("permission_prompt")]),
                entry(matcher: "idle_prompt", commands: [notification("idle_prompt")]),
                entry(matcher: "agent_needs_input", commands: [notification("agent_needs_input")]),
                entry(matcher: "agent_completed", commands: [notification("agent_completed")]),
            ],
            "Stop": [entry(matcher: nil, commands: [standard])],
            "StopFailure": [entry(matcher: nil, commands: [standard])],
            "SessionEnd": [entry(matcher: nil, commands: [sessionEnd])],
        ]
    }

    private static func isC100Entry(_ entry: Any) -> Bool {
        guard let dict = entry as? [String: Any], let hooks = dict["hooks"] as? [Any] else { return false }
        return hooks.contains { hook in
            guard let hookDict = hook as? [String: Any], let command = hookDict["command"] as? String else { return false }
            return command.contains(c100Marker)
        }
    }

    /// Merges `desired` c100 entries for one event into `existing`, dropping
    /// any previous c100-managed entries first so re-running install (or a
    /// binary-path change) never leaves stale duplicates behind. Non-c100
    /// entries are kept, in their original relative order.
    private static func mergedEventArray(existing: [Any], desired: [[String: Any]], uninstall: Bool) -> [Any] {
        let others = existing.filter { !isC100Entry($0) }
        return uninstall ? others : others + desired
    }

    /// Computes the merged `hooks` object for one `settings.json`, and
    /// whether anything actually changed. Throws `MalformedSettings` (rather
    /// than silently dropping data) if `hooks` or one of its event keys
    /// isn't the shape Claude Code / this installer expects.
    private static func computeMergedHooks(
        existingHooksRaw: Any?,
        desired: [String: [[String: Any]]],
        uninstall: Bool
    ) throws -> (merged: [String: Any], changed: Bool, hadC100Before: Bool) {
        var hooks: [String: Any]
        if existingHooksRaw == nil {
            hooks = [:]
        } else if let dict = existingHooksRaw as? [String: Any] {
            hooks = dict
        } else {
            throw MalformedSettings(message: "\"hooks\" is not a JSON object")
        }

        var changed = false
        var hadC100Before = false
        for event in eventOrder {
            let existingRaw = hooks[event]
            let existingArray: [Any]
            if existingRaw == nil {
                existingArray = []
            } else if let array = existingRaw as? [Any] {
                existingArray = array
            } else {
                throw MalformedSettings(message: "\"hooks.\(event)\" is not a JSON array")
            }
            if existingArray.contains(where: isC100Entry) {
                hadC100Before = true
            }
            let newArray = mergedEventArray(existing: existingArray, desired: desired[event] ?? [], uninstall: uninstall)
            if !(existingArray as NSArray).isEqual(newArray as NSArray) {
                changed = true
            }
            if newArray.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = newArray
            }
        }
        return (hooks, changed, hadC100Before)
    }

    // MARK: - File I/O

    private static func backupAndWrite(root: [String: Any], settingsPath: String) throws {
        let originalPermissions = (try? FileManager.default.attributesOfItem(atPath: settingsPath)[.posixPermissions]) as? NSNumber
        let backupPath = "\(settingsPath).c100-backup-\(Int(Date().timeIntervalSince1970 * 1000))"
        try FileManager.default.copyItem(atPath: settingsPath, toPath: backupPath)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        if let originalPermissions {
            try? FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: settingsPath)
        }
    }

    /// Installs (or, with `uninstall: true`, removes) the c100 hook entries
    /// across every directory in `configDirs`. `dryRun` computes and reports
    /// what would change without touching disk. Returns one `FileResult` per
    /// config dir, in the same order as `configDirs`.
    static func run(configDirs: [String], binaryPath: String, dryRun: Bool, uninstall: Bool) -> [FileResult] {
        let desired = desiredHooks(binaryPath: binaryPath)
        var results: [FileResult] = []
        for configDir in configDirs {
            let settingsPath = (configDir as NSString).appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: settingsPath) else {
                results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: .skipped, message: "settings.json not found (WARN: not created automatically)"))
                continue
            }
            guard let data = FileManager.default.contents(atPath: settingsPath) else {
                results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: .error, message: "could not read file"))
                continue
            }
            guard let rootAny = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let root = rootAny as? [String: Any] else {
                results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: .error, message: "invalid JSON, left untouched"))
                continue
            }
            do {
                let (mergedHooks, changed, hadC100Before) = try computeMergedHooks(
                    existingHooksRaw: root["hooks"],
                    desired: desired,
                    uninstall: uninstall
                )
                guard changed else {
                    results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: .unchanged, message: "no change needed"))
                    continue
                }
                var newRoot = root
                newRoot["hooks"] = mergedHooks
                let status: Status = uninstall ? .uninstalled : (hadC100Before ? .updated : .installed)
                if dryRun {
                    results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: status, message: "dry-run, not written"))
                    continue
                }
                try backupAndWrite(root: newRoot, settingsPath: settingsPath)
                results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: status, message: "backup written alongside settings.json"))
            } catch let malformed as MalformedSettings {
                results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: .error, message: "\(malformed.message), left untouched"))
            } catch {
                results.append(FileResult(configDir: configDir, settingsPath: settingsPath, status: .error, message: "\(error)"))
            }
        }
        return results
    }

    static func summarize(_ results: [FileResult]) -> String {
        var counts: [Status: Int] = [:]
        for result in results {
            counts[result.status, default: 0] += 1
        }
        return [Status.installed, .updated, .unchanged, .skipped, .uninstalled, .error]
            .map { "\($0.rawValue)=\(counts[$0] ?? 0)" }
            .joined(separator: " ")
    }
}
