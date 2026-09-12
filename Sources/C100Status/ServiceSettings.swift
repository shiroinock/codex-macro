import AppKit
import SwiftUI

@MainActor
final class ServiceSettingsModel: ObservableObject {
    @Published var configuration = Configuration() {
        didSet { onServicesChanged(Set(configuration.enabledServices ?? [])) }
    }
    var onServicesChanged: (Set<SessionSourceKind>) -> Void = { _ in }
    @Published var message = "読み込み中…"
    @Published var busy = false
    @Published var loaded = false
    private var saved = Configuration()
    private let execute: ([String]) async throws -> String
    init(execute: @escaping ([String]) async throws -> String) { self.execute = execute }
    var dirty: Bool { (try? configuration.json()) != (try? saved.json()) }
    func load() {
        guard !busy, !dirty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let text = try await execute(["config", "show"])
                var config = try JSONDecoder().decode(Configuration.self, from: Data(text.utf8))
                if config.enabledServices == nil {
                    // Preserve the old service selection on the first visit.
                    let text = try await execute(["layout", "show"])
                    let layout = try JSONDecoder().decode(KeyboardLayout.self, from: Data(text.utf8))
                    let sources = layout.enabledSources
                    config.enabledServices = sources.isEmpty ? [SessionSourceKind(rawValue: config.defaultLayer ?? "codex") ?? .codex] : SessionSourceKind.allCases.filter { sources.contains($0) }
                    if !config.enabledServices!.contains(where: { $0.rawValue == config.defaultLayer }) { config.defaultLayer = config.enabledServices!.first!.rawValue }
                }
                configuration = config; saved = config; loaded = true; message = "サービス設定はレイアウトから独立して保存します"
            } catch { message = String(describing: error) }
        }
    }
    func revert() { configuration = saved }
    func setEnabled(_ source: SessionSourceKind, _ enabled: Bool) {
        var sources = configuration.enabledServices ?? []
        sources.removeAll { $0 == source }
        if enabled { sources.append(source) }
        configuration.enabledServices = SessionSourceKind.allCases.filter { sources.contains($0) }
        if !sources.contains(where: { $0.rawValue == configuration.defaultLayer }) { configuration.defaultLayer = sources.first?.rawValue }
    }
    func save() {
        guard loaded, !busy else { return }
        let snapshot = configuration
        do { try snapshot.validate() } catch { message = String(describing: error); return }
        busy = true
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("c100-services-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url); busy = false }
            do {
                try snapshot.json().write(to: url, options: .atomic)
                _ = try await execute(["config", "save", url.path])
                saved = snapshot
                message = "保存済み。デーモンを再起動しています…"
                let result = try await execute(["install-agent"])
                message = result.trimmingCharacters(in: .whitespacesAndNewlines) == "daemon-paused"
                    ? "保存済み。デーモン再開時に反映します"
                    : "保存してデーモンに反映しました"
            } catch { message = "\(dirty ? "保存できませんでした" : "保存済み・再起動が必要です"): \(error)" }
        }
    }
}

struct ServiceSettingsView: View {
    @ObservedObject var model: ServiceSettingsModel
    private func path(_ title: String, _ key: WritableKeyPath<Configuration, String?>) -> some View {
        TextField(title, text: Binding(get: { model.configuration[keyPath: key] ?? "" }, set: { model.configuration[keyPath: key] = $0.isEmpty ? nil : $0 }))
            .textFieldStyle(.roundedBorder)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("サービス").font(.title2.bold())
            Text("使用サービスと接続先を設定します。切り替えパーツを置かなくても利用できます。").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ForEach(SessionSourceKind.allCases, id: \.rawValue) { source in
                            Toggle(source.displayName, isOn: Binding(get: { model.configuration.enabledServices?.contains(source) == true }, set: { model.setEnabled(source, $0) }))
                        }
                    }
                    Picker("初期表示サービス", selection: Binding(get: { model.configuration.defaultLayer ?? "" }, set: { model.configuration.defaultLayer = $0 })) {
                        ForEach(model.configuration.enabledServices ?? [], id: \.rawValue) { source in Text(source.displayName).tag(source.rawValue) }
                    }
                    Text("複数サービスを使う場合は、キーボードの切り替えパーツやメニューバーから表示を切り替えられます。").font(.caption).foregroundStyle(.secondary)
                    GroupBox("Codex") {
                        VStack(alignment: .leading) {
                            path("ホームディレクトリ", \.codexHome)
                            Text("独自の DB パスを指定していなければ、ホーム変更時に以下を空欄にすると新しいホームから自動設定します。").font(.caption)
                            path("カタログ DB（空欄で自動）", \.codexCatalogDatabase)
                            path("ステータス DB（空欄で自動）", \.codexStateDatabase)
                            path("サイドバー設定（空欄で自動）", \.codexSidebarState)
                        }.padding(4)
                    }
                    GroupBox("Claude CLI · 複数プロファイル") {
                        VStack(alignment: .leading) {
                            Text("設定ディレクトリを1行に1つ登録します（例: ~/.claude）。").font(.caption)
                            TextEditor(text: Binding(get: { (model.configuration.claudeConfigDirs ?? []).joined(separator: "\n") }, set: { model.configuration.claudeConfigDirs = $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                                .font(.system(.body, design: .monospaced)).frame(height: 70)
                        }.padding(4)
                    }
                    GroupBox("Claude Desktop / herdr") {
                        VStack {
                            path("Desktop セッションディレクトリ", \.claudeDesktopSessionsDir)
                            path("Desktop 設定ディレクトリ", \.claudeDesktopConfigDir)
                            path("herdr 実行ファイル（空欄で自動検出）", \.herdrBinary)
                        }.padding(4)
                    }
                }
            }
            HStack {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取り消す") { model.revert() }.disabled(!model.dirty || model.busy)
                Button("保存して反映") { model.save() }.buttonStyle(.borderedProminent).disabled(!model.loaded || model.busy)
            }
        }.padding(20).disabled(model.busy).onAppear { if !model.loaded { model.load() } }
    }
}
