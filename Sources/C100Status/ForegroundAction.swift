import AppKit

/// Resolve at the physical press, independently of the displayed service layer.
struct ForegroundAction {
    let bundleIdentifier: String
    let shortcut: CodexKeyboardShortcut

    static func resolve(_ part: LayoutPart, foreground: String?, enabledServices: Set<SessionSourceKind> = Set(SessionSourceKind.allCases), bindings: () throws -> [[String: Any]]) throws -> Self {
        if foreground == NavigationRouter.claudeDesktopBundleIdentifier {
            guard enabledServices.contains(.claudeDesktop) else { throw CLIError.runtime("Claude Desktop はサービス設定で無効です") }
            guard let key = part.claudeShortcut ?? DesktopActionCatalog.claudeKey(for: part.action) else {
                throw CLIError.runtime("この操作の Claude Desktop 向け送信方法は未対応です")
            }
            guard let shortcut = CodexKeyboardShortcut.parse(key, allowUnmodified: true) else {
                throw CLIError.runtime("Claude Desktop の送信キーが不正です")
            }
            return Self(bundleIdentifier: NavigationRouter.claudeDesktopBundleIdentifier, shortcut: shortcut)
        }
        guard foreground == CodexNavigator.bundleIdentifier else {
            throw CLIError.runtime("Codex または Claude Desktop を前面にしてください")
        }
        guard enabledServices.contains(.codex) else { throw CLIError.runtime("Codex はサービス設定で無効です") }
        guard DesktopActionCatalog.supportsCodex(part.action) else {
            throw CLIError.runtime("この操作の Codex 向け送信方法は未対応です")
        }
        guard let id = part.action, let shortcut = CodexKeyboardShortcut.forCommand(id, bindings: try bindings()) else {
            throw CLIError.runtime("Codex の送信キーが未設定です。レイアウトを再適用してください")
        }
        return Self(bundleIdentifier: CodexNavigator.bundleIdentifier, shortcut: shortcut)
    }

    func post(to processID: pid_t) throws {
        guard AXIsProcessTrusted() else { throw CLIError.runtime("C100 Companion にアクセシビリティ権限が必要です") }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else {
            throw CLIError.runtime("キーイベントを作成できませんでした")
        }
        down.flags = shortcut.flags; up.flags = shortcut.flags
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == processID, app.bundleIdentifier == bundleIdentifier else {
            throw CLIError.runtime("前面アプリが変わったため送信を中止しました")
        }
        down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
    }
}
