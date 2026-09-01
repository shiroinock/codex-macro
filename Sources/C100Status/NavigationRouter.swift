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

    init(codexNavigator: CodexNavigator) {
        self.codexNavigator = codexNavigator
    }

    @discardableResult
    func handleTap(keyIndex: Int, sessionID: String, target: NavigationTarget, now: Date = Date()) -> Bool {
        switch target {
        case .codexThread:
            return codexNavigator.handleTap(keyIndex: keyIndex, sessionID: sessionID, now: now)
        case .herdrPane, .ghosttyTab, .claudeDesktop:
            return false
        }
    }
}
