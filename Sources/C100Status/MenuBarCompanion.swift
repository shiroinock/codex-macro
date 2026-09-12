import AppKit
import Foundation

/// The menu owns no HID handle. Every display operation goes through the daemon.
@MainActor
final class MenuBarCompanion: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var trackingMenu = false
    private var busy = false
    private var information: [String: Any] = [:]
    private var problem: String?
    private var configPath: String? = UserDefaults.standard.string(forKey: "companion.configPath")
    private let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    private let layerNames = [("codex", "Codex"), ("claude-herdr", "Claude · herdr"), ("claude-terminal", "Claude · Terminal"), ("claude-desktop", "Claude Desktop")]

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MenuBarCompanion()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "C100 Companion")
        item.button?.title = " C100"
        item.menu = menu
        menu.delegate = self
        rebuild()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { trackingMenu = true }
    func menuDidClose(_ menu: NSMenu) { trackingMenu = false }

    private func entry(_ title: String, action: Selector? = nil, value: Any? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = value
        return entry
    }

    private func rebuild() {
        menu.removeAllItems()
        let connected = information["connected"] as? Bool == true
        let title = problem != nil ? "デーモン応答待ち（未起動・接続待ち）" : (connected ? "C100 接続中" : "C100 未接続")
        menu.addItem(entry(title))
        if let problem { menu.addItem(entry(String(problem.prefix(120)))) }
        else { menu.addItem(entry("方式: \(information["backend"] as? String ?? "確認中")")) }
        menu.addItem(.separator())
        let layerMenu = NSMenu()
        for (key, title) in layerNames {
            let row = entry(title, action: #selector(selectLayer(_:)), value: key)
            row.state = information["layer"] as? String == key ? .on : .off
            row.isEnabled = !busy && problem == nil
            layerMenu.addItem(row)
        }
        layerMenu.autoenablesItems = false
        let layers = entry("表示レイヤー"); layers.submenu = layerMenu; menu.addItem(layers)
        let brightnessMenu = NSMenu()
        for value in [10, 25, 50, 75, 100, 150, 200] {
            let row = entry("\(value)%" + (value == 100 ? "（標準）" : ""), action: #selector(selectBrightness(_:)), value: value)
            row.state = information["brightness"] as? Int == value ? .on : .off
            row.isEnabled = !busy && problem == nil && information["backend"] as? String == "companion"
            brightnessMenu.addItem(row)
        }
        brightnessMenu.autoenablesItems = false
        let brightness = entry("LED の明るさ"); brightness.submenu = brightnessMenu; menu.addItem(brightness)
        menu.addItem(.separator())
        menu.addItem(entry("デーモンを再起動", action: #selector(restart)))
        menu.addItem(entry("ログを開く", action: #selector(openLog)))
        menu.addItem(entry("設定ファイルを開く", action: #selector(openConfig)))
        menu.addItem(entry("設定ファイルを選ぶ…", action: #selector(chooseConfig)))
        if configPath != nil { menu.addItem(entry("標準の設定ファイルに戻す", action: #selector(resetConfig))) }
        menu.addItem(.separator())
        menu.addItem(entry("C100 Companion を終了", action: #selector(quit)))
        item.button?.toolTip = title
    }

    /// Short CLI calls are bounded and executed off the main/UI thread.
    private func execute(_ arguments: [String]) async throws -> String {
        let executable = binary
        let args = arguments + (configPath.map { ["--config", $0] } ?? [])
        return try await Task.detached {
            let data = try HerdrProcessRunner.run(binary: executable, arguments: args, timeout: 5)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private func refresh() {
        guard !busy && !trackingMenu else { return }
        busy = true
        Task {
            do {
                let result = try await execute(["inspect"])
                information = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] ?? [:]
                problem = nil
            } catch { problem = String(describing: error); information = [:] }
            busy = false
            rebuild()
        }
    }

    private func change(_ args: [String]) {
        guard !busy else { return }
        busy = true
        Task {
            do { _ = try await execute(args) }
            catch { showError(error) }
            busy = false
            refresh()
        }
    }

    @objc private func selectLayer(_ sender: NSMenuItem) { if let value = sender.representedObject as? String { change(["layer", value]) } }
    @objc private func selectBrightness(_ sender: NSMenuItem) { if let value = sender.representedObject as? Int { change(["brightness", String(value)]) } }
    @objc private func restart() { change(["install-agent"]) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func resetConfig() { configPath = nil; UserDefaults.standard.removeObject(forKey: "companion.configPath"); refresh() }
    @objc private func chooseConfig() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "C100 の設定 JSON を選んでください"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Configuration.load(explicitPath: url.path)
            configPath = url.path
            UserDefaults.standard.set(url.path, forKey: "companion.configPath")
            refresh()
        } catch { showError(error) }
    }
    @objc private func openConfig() {
        do {
            let (_, _, path) = try Configuration.load(explicitPath: configPath)
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else { change(["config", "init"]) }
        } catch { showError(error) }
    }
    @objc private func openLog() {
        Task {
            do { let path = try await execute(["log-path"]); NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            catch { showError(error) }
        }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "操作を完了できませんでした"; alert.informativeText = String(describing: error)
        NSApplication.shared.activate(ignoringOtherApps: true); alert.runModal()
    }
}
