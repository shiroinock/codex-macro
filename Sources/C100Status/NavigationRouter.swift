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
        case .ghosttyTab, .claudeDesktop:
            // Ghostty-direct / Claude Desktop focus dispatch lands in M3/M4.
            // Until then, log the intent so a key-press is observable in the
            // daemon log instead of silently doing nothing.
            log(.info, "input key=\(keyIndex) session=\(sessionID) action=navigation_not_implemented target=\(target)")
            return false
        }
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
