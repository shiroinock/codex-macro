import SwiftUI

struct ActionSettingsView: View {
    @ObservedObject var model: LayoutEditorModel
    @State private var query = ""
    private var services: [SessionSourceKind] { SessionSourceKind.allCases.filter { model.enabledActionServices.contains($0) } }
    private var actions: [CodexAction] {
        let assigned = Set(model.layout.parts.filter { $0.kind == .action }.compactMap(\.action))
        let relevant = DesktopActionCatalog.catalog.filter { action in
            assigned.contains(action.id) || services.contains { DesktopActionCatalog.supports(action.id, service: $0) }
        }
        return CodexActionChooser.search(query, in: relevant)
    }
    @ViewBuilder
    private func shortcut(_ action: CodexAction, service: SessionSourceKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch service {
            case .codex:
                if !DesktopActionCatalog.supportsCodex(action.id) {
                    Text("未対応").foregroundStyle(.secondary)
                } else if let error = model.shortcutError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let key = model.shortcuts[action.id] {
                    Text(key.label).font(.body.monospaced())
                    Text(key.dedicated ? "C100 専用設定" : "Codex 設定から読み込み").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("未登録").foregroundStyle(.secondary)
                    Text("レイアウト保存時に登録").font(.caption).foregroundStyle(.secondary)
                }
            case .claudeDesktop:
                if let key = DesktopActionCatalog.claudeKey(for: action.id) {
                    Text(ActionShortcutDisplay(accelerator: key, dedicated: false).label).font(.body.monospaced())
                    Text("内蔵の既定値 · Code タブ用").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("未対応").foregroundStyle(.secondary)
                }
                ForEach(model.layout.parts.filter { $0.kind == .action && $0.action == action.id && $0.claudeShortcut != nil }) { part in
                    Text("キー \(part.y + 1)-\(part.x + 1): \(ActionShortcutDisplay(accelerator: part.claudeShortcut!, dedicated: false).label)（以前の手動設定）").font(.caption)
                    Button("このキーを内蔵対応に戻す") {
                        if let index = model.layout.parts.firstIndex(where: { $0.id == part.id }) { model.layout.parts[index].claudeShortcut = nil }
                    }.font(.caption)
                }
            case .claudeTerminal, .claudeHerdr:
                Text("キー送信未対応").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("アクションと送信キー").font(.title2.bold())
                Spacer()
                Button("設定を再読み込み") { model.refreshShortcuts() }
            }
            Text("「サービス」で選んだサービスだけが候補・送信先です。サービスの変更は保存後に実機へ反映されます。").font(.callout).foregroundStyle(.secondary)
            TextField("アクションを検索", text: $query).textFieldStyle(.roundedBorder)
            if services.isEmpty {
                Text("「サービス」タブで利用するサービスを選んでください。").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top) {
                    Text("アクション").font(.headline).frame(width: 210, alignment: .leading)
                    ForEach(services, id: \.rawValue) { service in
                        Text(service.displayName).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(actions) { action in
                            HStack(alignment: .top, spacing: 12) {
                                Text(action.title).frame(width: 210, alignment: .leading)
                                ForEach(services, id: \.rawValue) { service in shortcut(action, service: service) }
                            }
                            Divider()
                        }
                    }
                }
                Text("未対応の組み合わせではキーを送りません。Claude の現在の設定の読み取りは未対応で、内蔵値と区別しています。").font(.caption).foregroundStyle(.secondary)
            }
            if model.dirty {
                Button("レイアウトの変更を保存して反映") { model.save() }.disabled(model.busy || model.validation != nil)
            }
            Spacer(minLength: 0)
        }.padding(24).frame(minWidth: 855, minHeight: 680)
            .onAppear { model.refreshShortcuts() }
    }
}
