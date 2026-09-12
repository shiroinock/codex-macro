import Foundation

enum KeyboardLayoutTests {
    static func run() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw CLIError.runtime("Layout self-test: " + message) }
        }
        func rejects(_ layout: KeyboardLayout, _ message: String) throws {
            do { try layout.validate() } catch { return }
            throw CLIError.runtime("Layout self-test: accepted " + message)
        }
        var layout = KeyboardLayout.standard
        try layout.validate()
        try check(layout.arrows == GridViewport.arrows && layout.enabledSources.count == 4, "legacy default")
        layout.parts[0].width = 4; layout.parts[0].height = 3; layout.parts[0].x = 2; layout.parts[0].y = 4
        try layout.validate()
        var viewport = GridViewport(); viewport.area = layout.taskArea!; viewport.arrowKeys = [0: "right"]
        let slots = (0..<7).flatMap { row in (0..<9).map { col in SessionSlot(projectKey: "p\(row)", source: .codex, row: row, column: col, status: .idle) } }
        let projects = Dictionary(uniqueKeysWithValues: (0..<7).map { ("p\($0)", $0) })
        try check(slots.compactMap { viewport.key(for: $0) }.count == 12, "resized task count")
        try check(viewport.key(for: slots[0]) == 42 && viewport.key(for: slots[2 * 9 + 3]) == 65, "offset physical mapping")
        viewport.move("right", projects: projects, slots: slots)
        try check(viewport.key(for: slots[1]) == 42 && viewport.key(for: slots[0]) == nil, "scroll maps actual visible tasks")
        viewport.area.transposed = true; viewport.leftColumn = 0
        try check(viewport.key(for: slots[1 * 9 + 2]) == 63, "transposed placement")
        viewport.move("down", projects: projects, slots: slots)
        try check(viewport.leftColumn == 1 && viewport.topRow == 0, "down follows physical direction after transpose")
        viewport.move("right", projects: projects, slots: slots)
        try check(viewport.leftColumn == 1 && viewport.topRow == 1, "right scrolls projects after transpose")
        try check(viewport.utilityColors(projects: projects, slots: slots).keys.sorted() == [0], "relocated arrow LEDs")
        var repeater = ArrowKeyRepeat()
        repeater.updateHeld([0, 98], now: 0, arrows: [0])
        try check(repeater.due(now: 1) == [0], "only relocated arrow repeats; former arrow may now be a task")
        repeater.updateHeld([0], now: 2, arrows: [])
        try check(repeater.due(now: 3).isEmpty, "layout change clears stale repeat")
        layout.parts[1].enabled = false
        try check(!layout.enabledSources.contains(.codex) && layout.part(at: 90) == nil, "disabled source releases key")
        var collision = layout; collision.parts.append(LayoutPart(kind: .action, x: 2, y: 4, action: "composer.submit"))
        try rejects(collision, "overlap")
        collision.parts[collision.parts.count - 1].enabled = false; try collision.validate()
        var outside = layout; outside.parts[0].x = 9; try rejects(outside, "out of bounds")
        var duplicate = layout; duplicate.parts.append(layout.parts[0]); try rejects(duplicate, "duplicate IDs")
        var badAction = layout; badAction.parts.append(LayoutPart(kind: .action, x: 0, y: 0, action: "invented")); try rejects(badAction, "unknown command")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c100-layout-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(path: dir.appendingPathComponent("layout.json").path)
        try check(try store.load() == .standard, "missing file migrates defaults")
        try store.save(layout); try check(try store.load() == layout, "layout round trip")
        let before = try Data(contentsOf: URL(fileURLWithPath: store.path))
        do { try store.save(outside) } catch {}
        try check(try Data(contentsOf: URL(fileURLWithPath: store.path)) == before, "invalid save preserves file")
        let bindings = CodexActionBindings(home: dir.path)
        let existing: [[String: Any]] = [["command": "newTask", "key": "Command+Option+N"], ["command": "composer.submit", "key": NSNull()]]
        try JSONSerialization.data(withJSONObject: existing).write(to: bindings.url)
        layout.parts.append(LayoutPart(kind: .action, x: 0, y: 0, action: "newTask"))
        layout.parts.append(LayoutPart(kind: .action, x: 1, y: 0, action: "composer.submit"))
        layout.parts.append(LayoutPart(kind: .action, x: 2, y: 0, action: "approval.approve"))
        try bindings.install(for: layout)
        let installed = try bindings.read()
        try check(installed.contains { $0["key"] as? String == "Command+Option+N" }, "user binding preserved")
        try check(!installed.contains { $0["command"] as? String == "composer.submit" && $0["key"] is NSNull } && installed.filter { $0["command"] as? String == "composer.submit" }.count == 1, "disabled default stays absent while explicit C100 alias works")
        try check(installed.contains { $0["command"] as? String == "approval.approve" && $0["key"] as? String == "Enter" }, "default binding preserved")
        try check(ActionShortcut.forCommand("composer.submit", bindings: installed)?.slot != ActionShortcut.forCommand("approval.approve", bindings: installed)?.slot, "approve cannot turn into send")
        layout.parts.append(LayoutPart(kind: .action, x: 4, y: 0, action: "composer.submit"))
        try layout.validate()
        try bindings.install(for: layout)
        try check(try bindings.read().count == installed.count, "multiple buttons share one command alias; installation is idempotent")
        let backups = try JSONSerialization.jsonObject(with: Data(contentsOf: bindings.url.appendingPathExtension("c100-backup"))) as! [[String: Any]]
        try check(backups.count == existing.count, "original keymap backup retained")
        var conflict = installed
        conflict.append(["command": "other", "key": ActionShortcut(slot: 0).accelerator])
        try JSONSerialization.data(withJSONObject: conflict).write(to: bindings.url)
        layout.parts.append(LayoutPart(kind: .action, x: 3, y: 0, action: CodexAction.catalog[0].id))
        let resolved = try bindings.prepared(layout)
        try check(ActionShortcut.forCommand(CodexAction.catalog[0].id, bindings: resolved) != nil, "existing shortcut collision avoided")
        let beforeFailure = try Data(contentsOf: bindings.url)
        do { try LayoutStore(path: dir.path).apply(layout, bindings: bindings) } catch {}
        try check(try Data(contentsOf: bindings.url) == beforeFailure, "failed layout save rolls back keymap")
        let fixture = #"[{id:`newTask`,titleIntlId:`codex.command.newThread`,electron:{menuTitle:`New Chat`,defaultKeybindings:[{key:`CmdOrCtrl+N`}]}},{id:`voice`,titleIntlId:`codex.command.voice`,shortcutScope:`os-global`},{id:`unconfigurable`,titleIntlId:`codex.command.foo`,shortcutConfigurable:!1},{id:`mac`,titleIntlId:`codex.command.mac`,electron:{platformDefaultKeybindings:{macOS:[{key:`Command+Shift+Z`}],default:[{key:`Ctrl+Y`}]}}}]"#
        let parsed = CodexCommandCatalog.parse(fixture)
        try check(parsed.count == 2 && parsed.first { $0.id == "newTask" }?.defaults == ["CmdOrCtrl+N"] && parsed.first { $0.id == "mac" }?.defaults == ["Command+Shift+Z"], "desktop command metadata and platform defaults")
        print("layout self-test passed: movable/resizable/transposed area, remapped arrows/repeat, disabled sources, validation, persistence, command bindings and backups")
    }
}
