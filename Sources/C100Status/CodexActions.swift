import AppKit
import Foundation

struct CodexAction: Identifiable {
    let id: String
    var title: String
    var defaults: [String] = []
    var titleKey: String? = nil
    // IDs and defaults verified against the installed desktop command catalog.
    // Use dedicated shortcuts rather than Enter/Escape to keep approval and send distinct.
    static let installed = CodexCommandCatalog.installed()
    static let catalog: [Self] = installed.isEmpty ? fallback : installed
    static let fallback: [Self] = [
        .init(id: "composer.toggleFastMode", title: "Fast 切り替え"),
        .init(id: "approval.approve", title: "承認", defaults: ["Enter"]),
        .init(id: "approval.decline", title: "拒否", defaults: ["Escape"]),
        .init(id: "forkThread", title: "フォーク"),
        .init(id: "composer.startDictation", title: "音声入力", defaults: ["Ctrl+Shift+D"]),
        .init(id: "composer.submit", title: "送信"),
        .init(id: "composer.togglePlanMode", title: "Plan 切り替え"),
        .init(id: "composer.increaseReasoningEffort", title: "推論を上げる"),
        .init(id: "composer.decreaseReasoningEffort", title: "推論を下げる"),
        .init(id: "composer.openModelPicker", title: "モデル選択", defaults: ["Ctrl+Shift+M"]),
        .init(id: "composer.startVoiceMode", title: "音声チャット", defaults: ["Ctrl+Shift+V"]),
        .init(id: "realtimeVoice.toggleMicrophoneMute", title: "マイク切り替え"),
        .init(id: "realtimeVoice.endCall", title: "音声チャット終了"),
        .init(id: "newTask", title: "新しいタスク", defaults: ["CmdOrCtrl+N", "CmdOrCtrl+Shift+O"]),
        .init(id: "newProjectlessTask", title: "プロジェクトなしのタスク", defaults: ["CmdOrCtrl+Alt+O"]),
        .init(id: "archiveThread", title: "アーカイブ", defaults: ["CmdOrCtrl+Shift+A"]),
        .init(id: "toggleThreadPin", title: "ピン切り替え", defaults: ["CmdOrCtrl+Alt+P"]),
        .init(id: "markThreadUnread", title: "未読にする", defaults: ["CmdOrCtrl+Shift+U"]),
        .init(id: "nextThreadNeedingAttention", title: "応答待ちへ", defaults: ["CmdOrCtrl+Alt+A"]),
        .init(id: "composer.addFiles", title: "ファイル添付"),
        .init(id: "composer.addPhotos", title: "写真添付"),
        .init(id: "composer.clear", title: "入力をクリア"),
        .init(id: "composer.queue", title: "キューに追加"),
        .init(id: "composer.steer", title: "実行中に指示"),
        .init(id: "composer.toggleWorktreeMode", title: "Worktree 切り替え"),
        .init(id: "git.commit", title: "コミット"),
        .init(id: "git.createPullRequest", title: "PR を作成"),
        .init(id: "git.createDraftPullRequest", title: "Draft PR を作成"),
        .init(id: "git.createBranch", title: "ブランチ作成"),
        .init(id: "git.openPullRequest", title: "PR を開く"),
        .init(id: "git.mergePullRequest", title: "PR をマージ"),
        .init(id: "openBrowserTab", title: "ブラウザを開く", defaults: ["CmdOrCtrl+T"]),
        .init(id: "openReviewTab", title: "レビューを開く", defaults: ["Ctrl+Shift+G"]),
        .init(id: "openSkills", title: "スキルを開く"),
        .init(id: "manageTasks", title: "スケジュールを開く"),
        .init(id: "settings", title: "設定", defaults: ["CmdOrCtrl+,"]),
        .init(id: "toggleSidebar", title: "サイドバー切り替え", defaults: ["CmdOrCtrl+B"]),
        .init(id: "toggleTerminal", title: "ターミナル切り替え", defaults: ["Control+`"]),
        .init(id: "navigateBack", title: "履歴を戻る", defaults: ["CmdOrCtrl+[", "MouseBack"]),
        .init(id: "navigateForward", title: "履歴を進む", defaults: ["CmdOrCtrl+]", "MouseForward"]),
        .init(id: "mcpSettings", title: "連携の設定"),
    ]
}

struct ActionShortcut {
    let slot: Int
    static let count = 120
    var accelerator: String {
        let bank = slot / 8 + 1
        return (bank & 1 != 0 ? "Control+" : "") + (bank & 2 != 0 ? "Option+" : "") + (bank & 4 != 0 ? "Shift+" : "") + (bank & 8 != 0 ? "Command+" : "") + "F\(13 + slot % 8)"
    }
    var keyCode: CGKeyCode { [105,107,113,106,64,79,80,90][slot % 8] }
    var flags: CGEventFlags {
        let bank = slot / 8 + 1
        var flags: CGEventFlags = []
        if bank & 1 != 0 { flags.insert(.maskControl) }
        if bank & 2 != 0 { flags.insert(.maskAlternate) }
        if bank & 4 != 0 { flags.insert(.maskShift) }
        if bank & 8 != 0 { flags.insert(.maskCommand) }
        return flags
    }
    static func forCommand(_ id: String, bindings: [[String: Any]]) -> Self? {
        guard !bindings.contains(where: { $0["command"] as? String == id && $0["key"] is NSNull }) else { return nil }
        return (0..<count).map { Self(slot: $0) }.first { shortcut in
            let owners = bindings.filter { ($0["key"] as? String).map(CodexActionBindings.normalized) == CodexActionBindings.normalized(shortcut.accelerator) }
            return !owners.isEmpty && owners.allSatisfy { $0["command"] as? String == id }
        }
    }
}

struct CodexActionBindings {
    let home: String
    var url: URL { URL(fileURLWithPath: home).appendingPathComponent("keybindings.json") }
    func read() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let bindings = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]],
              bindings.allSatisfy({ $0["command"] is String && ($0["key"] is String || $0["key"] is NSNull) }) else {
            throw CLIError.usage("Codex の keybindings.json を読み取れません。既存ファイルを保持しました")
        }
        return bindings
    }
    static func normalized(_ key: String) -> String {
        let aliases = ["cmdorctrl": "command", "cmd": "command", "meta": "command", "super": "command", "ctrl": "control", "alt": "option"]
        return key.lowercased().split(separator: "+").map { aliases[String($0)] ?? String($0) }.sorted().joined(separator: "+")
    }
    func prepared(_ layout: KeyboardLayout) throws -> [[String: Any]] {
        var bindings = try read()
        for part in layout.parts where part.enabled && part.kind == .action {
            guard let action = CodexAction.catalog.first(where: { $0.id == part.action }) else { continue }
            if ActionShortcut.forCommand(action.id, bindings: bindings) != nil { continue }
            let reserved = Set(bindings.compactMap { ($0["key"] as? String).map(Self.normalized) }
                + CodexAction.catalog.flatMap(\.defaults).map(Self.normalized))
            guard let shortcut = (0..<ActionShortcut.count).map({ ActionShortcut(slot: $0) }).first(where: { !reserved.contains(Self.normalized($0.accelerator)) }) else {
                throw CLIError.usage("C100 用の空きショートカットがありません")
            }
            let existing = bindings.filter { $0["command"] as? String == action.id }
            // Null disables every binding for this command in Codex. Remove
            // that sentinel when explicitly adding a button, but do not restore
            // any of its disabled default shortcuts.
            bindings.removeAll { $0["command"] as? String == action.id && $0["key"] is NSNull }
            if existing.isEmpty { bindings += action.defaults.map { ["command": action.id, "key": $0] } }
            bindings.append(["command": action.id, "key": shortcut.accelerator])
        }
        return bindings
    }
    func install(for layout: KeyboardLayout) throws {
        guard layout.parts.contains(where: { $0.enabled && $0.kind == .action }) else { return }
        let bindings = try prepared(layout)
        let data = try JSONSerialization.data(withJSONObject: bindings, options: [.prettyPrinted, .sortedKeys])
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try Data(contentsOf: url)
            if old == data { return }
            // Keep the first pre-integration keymap, never overwrite that backup.
            let backup = url.appendingPathExtension("c100-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try old.write(to: backup, options: .atomic) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func execute(_ id: String) throws {
        guard let action = CodexAction.catalog.first(where: { $0.id == id }) else { throw CLIError.usage("Unknown action") }
        let bindings = try read()
        guard let shortcut = ActionShortcut.forCommand(action.id, bindings: bindings) else { throw CLIError.runtime("レイアウトを再適用してください") }
        let key = Self.normalized(shortcut.accelerator)
        let owners = bindings.filter { ($0["key"] as? String).map(Self.normalized) == key }
        guard !owners.isEmpty && owners.allSatisfy({ $0["command"] as? String == id }) else {
            throw CLIError.runtime("Codex のショートカット設定が変更されています。レイアウトを再適用してください")
        }
        guard AXIsProcessTrusted() else { throw CLIError.runtime("C100 Companion にアクセシビリティ権限が必要です") }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == CodexNavigator.bundleIdentifier else {
            throw CLIError.runtime("アクションを実行するには Codex / ChatGPT を前面にしてください")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else { throw CLIError.runtime("キーイベントを作成できませんでした") }
        down.flags = shortcut.flags; up.flags = shortcut.flags
        down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
    }
}
