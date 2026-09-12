import Foundation

/// Semantic action IDs, with app-specific bindings kept out of the layout UI.
/// Existing Codex IDs remain stable for saved layouts.
enum DesktopActionCatalog {
    static let catalog: [CodexAction] = CodexAction.catalog.map { action in
        var result = action
        if action.id == "archiveThread" { result.title = "タスクをアーカイブ" }
        if action.id == "newTask" { result.title = "新しいタスク" }
        return result
    } + ClaudeDesktopAction.catalog.filter { $0.codexAction == nil }.map {
        CodexAction(id: "desktop." + $0.id, title: $0.title)
    }

    static func claudeKey(for id: String?) -> String? {
        guard let id else { return nil }
        return ClaudeDesktopAction.equivalent(to: id)?.accelerator
            ?? ClaudeDesktopAction.catalog.first { "desktop." + $0.id == id }?.accelerator
    }

    static func supportsCodex(_ id: String?) -> Bool {
        CodexAction.catalog.contains { $0.id == id }
    }

    static func supportLabel(_ id: String?) -> String {
        let codex = supportsCodex(id), claude = claudeKey(for: id) != nil
        if codex && claude { return "Codex · Claude Desktop（Code）" }
        if codex { return "Codex 対応 · Claude は送信方法未対応" }
        return "Claude Desktop（Code）対応 · Codex は送信方法未対応"
    }
}
