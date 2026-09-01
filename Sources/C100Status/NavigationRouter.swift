import AppKit
import Foundation

/// Dispatches a key-press's navigation intent to the appropriate
/// source-specific navigator.
///
/// M0 wired up `.codexThread`, routed to the existing `CodexNavigator`
/// unchanged (its double-tap launch-confirmation logic stays exactly as it
/// was). M2 adds `.herdrPane`: `herdr agent focus <pane_id>` (best-effort,
/// short timeout) followed by activating Ghostty, since herdr itself has no
/// window-foregrounding capability. `.ghosttyTab` and `.claudeDesktop`
/// remain reserved for M3/M4.
final class NavigationRouter {
    static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    private static let herdrFocusTimeout: TimeInterval = 0.2

    private let codexNavigator: CodexNavigator
    private let herdrBinaryPath: String?
    private let log: (StatusLogger.Level, String) -> Void

    init(
        codexNavigator: CodexNavigator,
        herdrBinaryPath: String? = nil,
        log: @escaping (StatusLogger.Level, String) -> Void = { _, _ in }
    ) {
        self.codexNavigator = codexNavigator
        self.herdrBinaryPath = herdrBinaryPath
        self.log = log
    }

    @discardableResult
    func handleTap(keyIndex: Int, sessionID: String, target: NavigationTarget, now: Date = Date()) -> Bool {
        switch target {
        case .codexThread:
            return codexNavigator.handleTap(keyIndex: keyIndex, sessionID: sessionID, now: now)
        case let .herdrPane(paneID):
            return navigateHerdr(paneID: paneID, sessionID: sessionID, keyIndex: keyIndex)
        case let .ghosttyTab(_, cwd, _):
            return navigateGhostty(cwd: cwd, sessionID: sessionID, keyIndex: keyIndex)
        case .claudeDesktop:
            // Claude Desktop focus dispatch lands in M4. Until then, log the
            // intent so a key-press is observable in the daemon log instead
            // of silently doing nothing.
            log(.info, "input key=\(keyIndex) session=\(sessionID) action=navigation_not_implemented target=\(target)")
            return false
        }
    }

    /// Ghostty direct-launch navigation (M3): locate the tab whose terminal
    /// `working directory` matches this session's cwd via AppleScript, bring
    /// it to the front, then fall back to just activating Ghostty (matching
    /// herdr's own no-tab-precision fallback above) if the tab can't be
    /// found, Automation permission hasn't been granted, or the script
    /// otherwise fails/times out.
    private func navigateGhostty(cwd: String, sessionID: String, keyIndex: Int) -> Bool {
        let shortSession = String(sessionID.prefix(8))
        let result = GhosttyNavigator.focusTab(cwd: cwd)
        switch result {
        case .focused:
            log(.info, "input key=\(keyIndex) session=\(shortSession) action=navigate_ghostty result=focused cwd=\(cwd)")
            return true
        case .notFound:
            log(.warning, "input key=\(keyIndex) session=\(shortSession) action=navigate_ghostty result=tab_not_found cwd=\(cwd)")
        case .permissionDenied:
            log(.warning, "input key=\(keyIndex) session=\(shortSession) action=navigate_ghostty result=automation_permission_denied cwd=\(cwd)")
        case let .failed(reason):
            log(.warning, "input key=\(keyIndex) session=\(shortSession) action=navigate_ghostty result=failed reason=\(reason) cwd=\(cwd)")
        }
        let activated = activateGhostty()
        log(
            activated ? .info : .warning,
            "input key=\(keyIndex) session=\(shortSession) action=navigate_ghostty_fallback ghostty_activated=\(activated)"
        )
        return activated
    }

    private func navigateHerdr(paneID: String, sessionID: String, keyIndex: Int) -> Bool {
        let shortSession = String(sessionID.prefix(8))
        if let herdrBinaryPath {
            do {
                _ = try HerdrProcessRunner.run(
                    binary: herdrBinaryPath,
                    arguments: ["agent", "focus", paneID],
                    timeout: Self.herdrFocusTimeout
                )
            } catch {
                // Best-effort: a failed/timed-out focus still lets us try to
                // bring Ghostty itself forward below.
                log(.warning, "input key=\(keyIndex) session=\(shortSession) action=herdr_focus_failed pane=\(paneID) error=\(error)")
            }
        } else {
            log(.warning, "input key=\(keyIndex) session=\(shortSession) action=herdr_focus_skipped reason=binary_unresolved pane=\(paneID)")
        }

        let activated = activateGhostty()
        log(
            activated ? .info : .warning,
            "input key=\(keyIndex) session=\(shortSession) action=navigate_herdr pane=\(paneID) ghostty_activated=\(activated)"
        )
        return activated
    }

    private func activateGhostty() -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ghosttyBundleIdentifier).first {
            return running.activate(options: [.activateAllWindows])
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.ghosttyBundleIdentifier) else {
            log(.warning, "ghostty not found bundle_id=\(Self.ghosttyBundleIdentifier) action=activate_skipped")
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var activationError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            activationError = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
        if let activationError {
            log(.warning, "ghostty activation failed error=\(activationError)")
        }
        return true
    }
}

/// Runs `/usr/bin/osascript` with a hard wall-clock timeout, mirroring
/// `HerdrProcessRunner`'s never-block-the-daemon posture (Apple Events can
/// hang indefinitely if the target app is unresponsive or a permission
/// dialog is silently waiting).
enum OsascriptRunner {
    enum RunError: Error, CustomStringConvertible {
        case timedOut(seconds: TimeInterval)
        case nonZeroExit(status: Int32, stderr: String)

        var description: String {
            switch self {
            case let .timedOut(seconds):
                "osascript timed out after \(seconds)s"
            case let .nonZeroExit(status, stderr):
                "osascript exited \(status): \(stderr)"
            }
        }
    }

    static let executablePath = "/usr/bin/osascript"

    static func run(arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw RunError.timedOut(seconds: timeout)
        }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw RunError.nonZeroExit(status: process.terminationStatus, stderr: errorText)
        }
        return data
    }
}

/// Ghostty-direct tab lookup/focus via AppleScript (M3).
///
/// **Investigated and confirmed at implementation time** (read-only
/// `osascript` probing against a real running Ghostty, no permission dialog
/// appeared): despite the implementation plan's hope that a terminal's
/// `environment variables` property could be read back to match a session
/// precisely, Ghostty's AppleScript dictionary (`sdef`) only exposes
/// `environment variables` as a *write-only* field of the `surface
/// configuration` record used when *creating* a new terminal -- `get
/// environment variables of terminal ...` fails with "can't get ..." (-1728)
/// against an existing terminal. The only readable identifying property on
/// an existing `terminal` is `working directory` (plus `id`/`name`, neither
/// of which carries the Claude session id). So this matches on **cwd only**;
/// if more than one open tab shares the same cwd, the first match wins and
/// the mismatch is not otherwise detectable through this API. `pid` (also
/// carried by `NavigationTarget.ghosttyTab`) can't help either: no Ghostty
/// AppleScript object exposes a terminal's underlying process id.
///
/// The `cwd` value is passed as an `osascript` positional argument bound to
/// `on run argv`, never interpolated into the script text, so it cannot
/// break out of an AppleScript string literal regardless of its contents.
enum GhosttyNavigator {
    static let scriptTimeout: TimeInterval = 1.0

    enum FocusResult: Equatable {
        case focused
        case notFound
        case permissionDenied
        case failed(String)
    }

    /// `on run argv` receives `cwd` as `item 1 of argv`; matches the first
    /// terminal (across all windows/tabs) whose `working directory` equals
    /// it exactly, then `activate`s its window, `select`s its tab, and
    /// `focus`es the terminal itself (the three verbs the plan called out
    /// from Ghostty's `sdef`).
    private static let focusTabScript = """
    on run argv
        set targetCWD to item 1 of argv
        tell application "Ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        set wd to ""
                        try
                            set wd to working directory of term
                        end try
                        if wd is equal to targetCWD then
                            activate w
                            select t
                            focus term
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not_found"
    end run
    """

    static func focusTab(cwd: String, timeout: TimeInterval = scriptTimeout) -> FocusResult {
        do {
            let output = try OsascriptRunner.run(arguments: ["-e", focusTabScript, cwd], timeout: timeout)
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text == "focused" ? .focused : .notFound
        } catch let error as OsascriptRunner.RunError {
            switch error {
            case .timedOut:
                return .failed("timed out")
            case let .nonZeroExit(status, stderr):
                // -1743 is macOS's "not authorized to send Apple events"
                // error, i.e. Automation permission was never granted or was
                // revoked in System Settings > Privacy & Security >
                // Automation.
                if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
                    return .permissionDenied
                }
                return .failed("exit \(status): \(stderr)")
            }
        } catch {
            return .failed(String(describing: error))
        }
    }
}
