import Darwin
import Foundation

/// Installs/uninstalls a per-user `LaunchAgent` under
/// `~/Library/LaunchAgents/<label>.plist` that runs `c100-status run` as the
/// logged-in user, keyed off `gui/<uid>` via `launchctl bootstrap`/`bootout`.
/// Driven by `c100-status install-agent` (main.swift).
///
/// This is the user-space counterpart to `HelperInstaller`, which installs
/// the root-owned `LaunchDaemon` for the privileged grabber helper
/// (`com.kotainaba.c100-status.grabber`). The label chosen here,
/// `com.kotainaba.c100-status.run`, mirrors that naming scheme: same
/// reverse-DNS prefix, suffixed with the CLI subcommand each plist launches
/// (`grabber-service` vs. `run`) rather than a generic "agent"/"status" name.
///
/// Design notes, mirroring `ClaudeHooksInstaller`'s conventions:
/// - **Idempotent.** Re-running with the same `--binary`/`--location`/
///   `--label` is a no-op write (the plist file is byte-identical) but still
///   restarts the job via `bootout` + `bootstrap` (there is no portable
///   "reload config" launchctl verb), reported as `.restarted` rather than
///   `.installed`/`.updated` so the caller can tell nothing on disk changed.
/// - **`--dry-run` has zero side effects.** It neither writes the plist file
///   nor shells out to `launchctl`; it only computes and prints what would
///   happen.
/// - **Root is refused**, matching `run`'s own posture: this manages a
///   *per-user* GUI launchd domain (`gui/<uid>`), which does not make sense
///   for `root`/`sudo`.
enum AgentInstaller {
    static let defaultLabel = "com.kotainaba.c100-status.run"

    enum Status: String {
        case installed, updated, restarted, uninstalled
    }

    struct RunResult {
        let label: String
        let plistPath: String
        let status: Status
        let message: String
        /// Set only when `dryRun` is true: the plist contents and the
        /// `launchctl` command lines that would have been run for real.
        let dryRunPreview: String?
    }

    // MARK: - Label / path validation

    static func validateLabel(_ label: String) throws {
        guard !label.isEmpty,
              label.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw CLIError.usage("--label must be a non-empty identifier of letters, digits, '.', '_', '-' (got \"\(label)\")")
        }
    }

    static func validateBinaryPath(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw CLIError.usage("--binary must be an absolute path (got \"\(path)\")")
        }
    }

    static func plistPath(label: String, homeDirectory: String = NSHomeDirectory()) -> String {
        "\(homeDirectory)/Library/LaunchAgents/\(label).plist"
    }

    // MARK: - plist generation

    static func plist(label: String, binaryPath: String, locationID: Int?) -> String {
        var argumentStrings = [binaryPath, "run"]
        if let locationID {
            argumentStrings.append("--location")
            argumentStrings.append("0x\(String(locationID, radix: 16))")
        }
        let argumentsXML = argumentStrings
            .map { "    <string>\(xmlEscape($0))</string>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(xmlEscape(label))</string>
          <key>ProgramArguments</key>
          <array>
        \(argumentsXML)
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>StandardOutPath</key>
          <string>/dev/null</string>
          <key>StandardErrorPath</key>
          <string>/dev/null</string>
        </dict>
        </plist>
        """
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Parses plist XML back into a dictionary for content-equality checks
    /// (rather than comparing raw bytes, which would treat cosmetic
    /// formatting differences as a real change).
    private static func parsedPlist(_ xml: String) -> [String: Any]? {
        guard let data = xml.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return object as? [String: Any]
    }

    // MARK: - launchctl

    typealias LaunchctlRunner = (_ arguments: [String]) throws -> String

    static func defaultLaunchctlRunner(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw CLIError.runtime("launchctl \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text
    }

    // MARK: - install / uninstall

    /// Installs (or updates/restarts) the LaunchAgent, or with
    /// `uninstall: true`, removes it. `dryRun` never touches disk or shells
    /// out to `launchctl`.
    static func run(
        label: String,
        binaryPath: String,
        locationID: Int?,
        dryRun: Bool,
        uninstall: Bool,
        homeDirectory: String = NSHomeDirectory(),
        uid: uid_t = getuid(),
        launchctl: LaunchctlRunner = defaultLaunchctlRunner
    ) throws -> RunResult {
        guard geteuid() != 0 else {
            throw CLIError.runtime(
                "install-agent must be run as the logged-in user, not root -- it manages a per-user (gui/<uid>) LaunchAgent."
            )
        }
        try validateLabel(label)
        let path = plistPath(label: label, homeDirectory: homeDirectory)
        let domainTarget = "gui/\(uid)"
        let serviceTarget = "gui/\(uid)/\(label)"

        if uninstall {
            let commands = [["bootout", serviceTarget]]
            if dryRun {
                return RunResult(
                    label: label, plistPath: path, status: .uninstalled,
                    message: "dry-run, not applied",
                    dryRunPreview: dryRunPreviewText(plistContents: nil, commands: commands)
                )
            }
            // Best-effort: it is not an error for the job to already be
            // unloaded (e.g. a previous uninstall was interrupted after
            // bootout but before removing the plist).
            _ = try? launchctl(["bootout", serviceTarget])
            let existed = FileManager.default.fileExists(atPath: path)
            if existed {
                try FileManager.default.removeItem(atPath: path)
            }
            return RunResult(
                label: label, plistPath: path, status: .uninstalled,
                message: existed ? "unloaded and plist removed" : "was not installed; unload attempted, nothing to remove",
                dryRunPreview: nil
            )
        }

        try validateBinaryPath(binaryPath)
        let newContents = plist(label: label, binaryPath: binaryPath, locationID: locationID)
        let newParsed = parsedPlist(newContents)

        let existingContents = FileManager.default.fileExists(atPath: path)
            ? try? String(contentsOfFile: path, encoding: .utf8)
            : nil
        let unchanged: Bool
        if let existingContents, let existingParsed = parsedPlist(existingContents), let newParsed {
            unchanged = (existingParsed as NSDictionary).isEqual(to: newParsed)
        } else {
            unchanged = false
        }
        let status: Status = existingContents == nil ? .installed : (unchanged ? .restarted : .updated)

        // Reload commands: an in-place plist edit is not picked up by a
        // running job, so every path (install/update/restart) re-registers
        // via bootout (best-effort -- the job may not be loaded yet) then
        // bootstrap. This is the practical equivalent of `kickstart -k` for
        // a job whose on-disk definition may also have just changed.
        let commands = [["bootout", serviceTarget], ["bootstrap", domainTarget, path]]

        if dryRun {
            return RunResult(
                label: label, plistPath: path, status: status,
                message: "dry-run, not applied",
                dryRunPreview: dryRunPreviewText(plistContents: newContents, commands: commands)
            )
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(newContents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = try? launchctl(["bootout", serviceTarget])
        _ = try launchctl(["bootstrap", domainTarget, path])

        let message: String
        switch status {
        case .installed: message = "plist written, loaded via launchctl bootstrap"
        case .updated: message = "plist changed, reloaded via launchctl bootout+bootstrap"
        case .restarted: message = "plist unchanged, restarted via launchctl bootout+bootstrap"
        case .uninstalled: message = "" // unreachable in this branch
        }
        return RunResult(label: label, plistPath: path, status: status, message: message, dryRunPreview: nil)
    }

    private static func dryRunPreviewText(plistContents: String?, commands: [[String]]) -> String {
        var lines: [String] = []
        if let plistContents {
            lines.append(plistContents)
            lines.append("")
        }
        lines.append("planned launchctl commands:")
        for command in commands {
            lines.append("  launchctl \(command.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }
}
