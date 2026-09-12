import Foundation

@MainActor
enum LayoutEditorTests {
    static func run() throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw CLIError.runtime("Editor self-test: " + message) } }
        let services = ServiceSettingsModel(execute: { _ in "" })
        services.setEnabled(.codex, true)
        services.setEnabled(.claudeTerminal, true)
        services.setEnabled(.codex, false)
        try check(services.configuration.enabledServices == [.claudeTerminal] && services.configuration.defaultLayer == "claude-terminal", "disabling the selected service selects an available default")
        try services.configuration.validate()
        let model = LayoutEditorModel(execute: { _ in "" })
        try check(model.assign(at: 80, kind: .action, source: nil, direction: nil, action: "toggleSidebar"), "assign clicked empty key")
        try check(model.assign(at: 81, kind: .action, source: nil, direction: nil, action: "toggleSidebar"), "duplicate action on another key")
        try check(model.layout.part(at: 80)?.action == "toggleSidebar" && model.layout.part(at: 81)?.action == "toggleSidebar", "exact clicked positions")
        try check(model.assign(at: 80, kind: .scroll, source: nil, direction: "left", action: nil), "replace existing button type")
        let before = model.layout
        try check(!model.assign(at: 25, kind: .action, source: nil, direction: nil, action: "toggleSidebar") && model.layout == before, "task area is never silently removed")
        try check(model.assign(at: 84, kind: .source, source: nil, direction: nil, action: nil, services: [.codex, .claudeDesktop]), "relocate service group")
        let group = model.layout.part(at: 84)!
        try check(group.serviceAssignments.map(\.key) == [84,85] && model.layout.enabledSources == [.codex, .claudeDesktop], "group toggles determine keys and enabled providers")
        try check(model.assign(at: 85, kind: .source, source: nil, direction: nil, action: nil, services: [.codex]) && model.layout.part(at: 84)?.id == group.id, "editing an interior service key keeps the group anchor")
        let after = model.layout
        try check(!model.assign(at: 86, kind: .tasks, source: nil, direction: nil, action: nil) && model.layout == after, "out of bounds candidate does not mutate layout")
        let actions = [CodexAction(id: "git.commit", title: "コミット"), CodexAction(id: "toggleSidebar", title: "サイドバー切り替え")]
        try check(CodexActionChooser.search("  GIT commit ", in: actions).map(\.id) == ["git.commit"], "case-insensitive multiword search")
        try check(CodexActionChooser.search("サイドバー", in: actions).map(\.id) == ["toggleSidebar"], "Japanese name search")
        try check(CodexActionChooser.search("missing", in: actions).isEmpty && CodexActionChooser.search("", in: actions).count == 2, "empty and no-match search")
        print("editor self-test passed: clicked-key assignment, duplicate actions, replacement, group choices, non-destructive validation, searchable commands")
    }
}
