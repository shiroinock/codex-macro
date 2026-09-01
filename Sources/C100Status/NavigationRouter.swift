import Foundation

/// Dispatches a key-press's navigation intent to the appropriate
/// source-specific navigator.
///
/// M0 only wires up `.codexThread`, routed to the existing `CodexNavigator`
/// unchanged (its double-tap launch-confirmation logic stays exactly as it
/// was). The remaining cases are reserved for herdr (M2), Ghostty-direct
/// (M3), and Claude Desktop (M4).
final class NavigationRouter {
    private let codexNavigator: CodexNavigator
    private let log: (StatusLogger.Level, String) -> Void

    init(codexNavigator: CodexNavigator, log: @escaping (StatusLogger.Level, String) -> Void = { _, _ in }) {
        self.codexNavigator = codexNavigator
        self.log = log
    }

    @discardableResult
    func handleTap(keyIndex: Int, sessionID: String, target: NavigationTarget, now: Date = Date()) -> Bool {
        switch target {
        case .codexThread:
            return codexNavigator.handleTap(keyIndex: keyIndex, sessionID: sessionID, now: now)
        case .herdrPane, .ghosttyTab, .claudeDesktop:
            // Herdr/Ghostty/Claude Desktop focus dispatch lands in M2-M4.
            // Until then, log the intent so a key-press is observable in the
            // daemon log instead of silently doing nothing.
            log(.info, "input key=\(keyIndex) session=\(sessionID) action=navigation_not_implemented target=\(target)")
            return false
        }
    }
}
