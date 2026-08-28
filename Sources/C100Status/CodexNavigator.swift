import AppKit
import Foundation

final class CodexNavigator {
    static let bundleIdentifier = "com.openai.codex"
    static let doubleTapInterval: TimeInterval = 0.350

    private var pendingTap: (keyIndex: Int, time: Date)?
    private let log: (StatusLogger.Level, String) -> Void

    init(log: @escaping (StatusLogger.Level, String) -> Void) {
        self.log = log
    }

    @discardableResult
    func handleTap(keyIndex: Int, sessionID: String, now: Date = Date()) -> Bool {
        if isCodexRunning {
            pendingTap = nil
            return navigate(sessionID: sessionID, keyIndex: keyIndex, launchReason: "single_tap_running")
        }

        if let pendingTap,
           pendingTap.keyIndex == keyIndex,
           now.timeIntervalSince(pendingTap.time) <= Self.doubleTapInterval {
            self.pendingTap = nil
            return navigate(sessionID: sessionID, keyIndex: keyIndex, launchReason: "double_tap_launch")
        } else {
            pendingTap = (keyIndex, now)
            log(.info, "input key=\(keyIndex) codex=not_running action=await_second_tap window_ms=350")
            return false
        }
    }

    private var isCodexRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    private func navigate(sessionID: String, keyIndex: Int, launchReason: String) -> Bool {
        guard UUID(uuidString: sessionID) != nil,
              let url = URL(string: "codex://threads/\(sessionID)") else {
            log(.error, "input key=\(keyIndex) action=navigate_failed invalid_session_id=\(sessionID)")
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        log(
            opened ? .info : .error,
            "input key=\(keyIndex) session=\(String(sessionID.prefix(8))) action=navigate reason=\(launchReason) opened=\(opened)"
        )
        return opened
    }
}
