import Foundation

/// Built-in macOS Code-tab bindings, verified against the official desktop docs.
/// https://code.claude.com/docs/en/desktop#keyboard-shortcuts
/// These are not Claude CLI bindings and do not imply Chat/Cowork support.
struct ClaudeDesktopAction: Identifiable {
    let id: String
    let title: String
    let accelerator: String
    var codexAction: String? = nil

    static let catalog: [Self] = [
        .init(id: "newSession", title: "新しいセッション", accelerator: "Command+N", codexAction: "newTask"),
        .init(id: "closeSession", title: "セッションを閉じる", accelerator: "Command+W"),
        .init(id: "nextSession", title: "次のセッション", accelerator: "Control+Tab"),
        .init(id: "previousSession", title: "前のセッション", accelerator: "Control+Shift+Tab"),
        .init(id: "stopResponse", title: "応答を停止", accelerator: "Escape"),
        .init(id: "toggleDiff", title: "差分ペイン切り替え", accelerator: "Command+Shift+D"),
        .init(id: "toggleBrowser", title: "ブラウザペイン切り替え", accelerator: "Command+Shift+B"),
        .init(id: "selectBrowserElement", title: "ブラウザの要素を選択", accelerator: "Command+Shift+S"),
        .init(id: "toggleTerminal", title: "ターミナル切り替え", accelerator: "Control+`", codexAction: "toggleTerminal"),
        .init(id: "closePane", title: "選択中のペインを閉じる", accelerator: "Command+\\"),
        .init(id: "sideChat", title: "サイドチャットを開く", accelerator: "Command+;"),
        .init(id: "cycleViewMode", title: "表示モード切り替え", accelerator: "Control+O"),
        .init(id: "permissionMenu", title: "権限モード選択", accelerator: "Command+Shift+M"),
        .init(id: "modelMenu", title: "モデル選択", accelerator: "Command+Shift+I", codexAction: "composer.openModelPicker"),
        .init(id: "effortMenu", title: "推論の強さを選択", accelerator: "Command+Shift+E"),
        .init(id: "shortcuts", title: "ショートカット一覧", accelerator: "Command+/"),
    ]

    static func equivalent(to codexID: String?) -> Self? {
        guard let codexID else { return nil }
        return catalog.first { $0.codexAction == codexID }
    }
}
