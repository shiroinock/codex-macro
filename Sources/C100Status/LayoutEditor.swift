import AppKit
import SwiftUI

@MainActor
final class LayoutEditorModel: ObservableObject {
    @Published var enabledActionServices = Set(SessionSourceKind.allCases)
    var actionCandidates: [CodexAction] { DesktopActionCatalog.candidates(services: enabledActionServices) }
    @Published var layout = KeyboardLayout.standard
    @Published var selected: String? = "tasks"
    @Published var message = "読み込み中…"
    @Published var busy = false
    @Published var loaded = false
    @Published var shortcuts: [String: ActionShortcutDisplay] = [:]
    @Published var hardwareKeyOutput = false
    @Published var shortcutError: String? = "読み込み中…"
    private var refreshingShortcuts = false
    func refreshShortcuts() {
        guard !refreshingShortcuts else { return }
        refreshingShortcuts = true
        Task {
            defer { refreshingShortcuts = false }
            do {
                let text = try await execute(["layout", "shortcuts"])
                shortcuts = try JSONDecoder().decode([String: ActionShortcutDisplay].self, from: Data(text.utf8))
                shortcutError = nil
                if let status = try? await execute(["inspect"]), let data = status.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    hardwareKeyOutput = object["actionTransport"] as? String == "keyboard-hid"
                }
            } catch { shortcuts = [:]; shortcutError = "送信キーを確認できません: \(error)" }
        }
    }
    private var saved = KeyboardLayout.standard
    private let execute: ([String]) async throws -> String
    init(execute: @escaping ([String]) async throws -> String) { self.execute = execute }
    var dirty: Bool { layout != saved }
    var validation: String? { do { try layout.validate(); return nil } catch { return String(describing: error) } }
    func load() {
        busy = true
        Task {
            do {
                let data = try await execute(["layout", "show"])
                layout = try JSONDecoder().decode(KeyboardLayout.self, from: Data(data.utf8))
                layout.migrateParts()
                refreshShortcuts()
                saved = layout; selected = layout.parts.first?.id; loaded = true; message = "パーツを選び、ドラッグで移動できます"
            } catch { message = String(describing: error) }
            busy = false
        }
    }
    func save() {
        guard validation == nil && loaded else { return }
        busy = true
        let snapshot = layout
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("c100-layout-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: url); busy = false }
            do {
                try snapshot.json().write(to: url, options: .atomic)
                _ = try await execute(["layout", "apply", url.path])
                refreshShortcuts()
                saved = snapshot; message = "保存して C100 に反映しました"
            } catch { message = String(describing: error) }
        }
    }
    func update(_ body: (inout LayoutPart) -> Void) {
        guard let index = layout.parts.firstIndex(where: { $0.id == selected }) else { return }
        body(&layout.parts[index])
    }
    func add(_ kind: LayoutPart.Kind, source: SessionSourceKind? = nil, direction: String? = nil) {
        if kind == .tasks, let existing = layout.parts.first(where: { $0.kind == .tasks }) { selected = existing.id; return }
        if kind == .source, let existing = layout.parts.first(where: { $0.kind == .source }) { selected = existing.id; return }
        guard let key = (0..<100).first(where: { layout.part(at: $0) == nil }) else { message = "空きキーがありません。タスクエリアを縮めるか、パーツを無効にしてください"; return }
        _ = assign(at: key, kind: kind, source: source, direction: direction, action: kind == .action ? actionCandidates.first?.id : nil)
    }
    /// Commit a key assignment only after the candidate passes layout validation.
    func assign(at key: Int, kind: LayoutPart.Kind, source: SessionSourceKind?, direction: String?, action: String?, services: [SessionSourceKind] = SessionSourceKind.allCases) -> Bool {
        guard (0..<100).contains(key) else { return false }
        let target = layout.part(at: key)
        if let target, target.kind == .tasks, target.width * target.height > 1 {
            if kind == .tasks { selected = target.id; return true }
            message = "タスクエリアを先に縮めて、このキーを空けてください"
            return false
        }
        let existing = layout.parts.first { part in
            (kind == .tasks && part.kind == .tasks) || (kind == .source && part.kind == .source)
        }
        var candidate = layout
        candidate.parts.removeAll { $0.id == target?.id || $0.id == existing?.id }
        var part = existing ?? LayoutPart(kind: kind, x: key % 10, y: key / 10)
        if existing?.id != target?.id || existing == nil { part.x = key % 10; part.y = key / 10 }
        part.enabled = true
        part.source = nil; part.direction = direction; part.action = action
        if kind == .action, target?.action == action { part.claudeShortcut = target?.claudeShortcut }
        if kind == .source {
            part.services = services
            if part.width * part.height < max(1, services.count) {
                part.width = min(10 - part.x, max(1, services.count)); part.height = max(1, (services.count + part.width - 1) / part.width)
            }
        }
        candidate.parts.append(part)
        do { try candidate.validate() }
        catch { message = String(describing: error); return false }
        layout = candidate; selected = part.id; message = "割り当てを変更しました。「保存して反映」で適用します"
        return true
    }
    func remove() { layout.parts.removeAll { $0.id == selected }; selected = layout.parts.first?.id }
    func revert() { layout = saved; selected = layout.parts.first?.id; message = "未保存の変更を取り消しました" }
}

struct LayoutEditorView: View {
    @ObservedObject var model: LayoutEditorModel
    @State private var selectedKey: Int?
    @State private var dragOrigin: (String, Int, Int)?
    private let cell: CGFloat = 46
    private var inspectorKey: Int? {
        guard let part = model.layout.parts.first(where: { $0.id == model.selected }) else { return selectedKey }
        if let selectedKey, part.keys.contains(selectedKey) { return selectedKey }
        return part.y * 10 + part.x
    }
    private func tint(_ part: LayoutPart) -> Color {
        switch part.kind { case .tasks: .indigo; case .scroll: .teal; case .source: .orange; case .action: .purple }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("C100 レイアウト").font(.title2.bold())
                    Text("パーツを置いて、自分のコントロール面をつくる").foregroundStyle(.secondary)
                }
                Spacer()
                Button("変更を取り消す") { model.revert() }.disabled(!model.dirty || model.busy)
                Button("保存して反映") { model.save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
                    .disabled(model.validation != nil || !model.loaded || model.busy || !model.dirty)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("10 × 10 キー").font(.headline)
                        Spacer()
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<100, id: \.self) { key in
                            Button { selectedKey = key; model.selected = model.layout.part(at: key)?.id } label: {
                                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selectedKey == key && model.selected == nil ? Color.accentColor : .clear, lineWidth: 2))
                                    .overlay(Text("\(key / 10 + 1)·\(key % 10 + 1)").font(.system(size: 9)).foregroundStyle(.tertiary))
                            }.buttonStyle(.plain).accessibilityLabel("\(key / 10 + 1)行\(key % 10 + 1)列に割り当て")
                                .frame(width: cell - 4, height: cell - 4).offset(x: CGFloat(key % 10) * cell, y: CGFloat(key / 10) * cell)
                        }
                        ForEach(model.layout.parts.filter(\.enabled)) { part in
                            partView(part)
                                .frame(width: CGFloat(part.width) * cell - 4, height: CGFloat(part.height) * cell - 4)
                                .offset(x: CGFloat(part.x) * cell, y: CGFloat(part.y) * cell)
                                .gesture(SpatialTapGesture().onEnded { value in
                                    model.selected = part.id
                                    let x = min(part.width - 1, max(0, Int(value.location.x / cell)))
                                    let y = min(part.height - 1, max(0, Int(value.location.y / cell)))
                                    selectedKey = (part.y + y) * 10 + part.x + x
                                })
                                .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                                    if dragOrigin?.0 != part.id { dragOrigin = (part.id, part.x, part.y); model.selected = part.id; selectedKey = nil }
                                    guard let origin = dragOrigin else { return }
                                    model.update { p in
                                        p.x = min(10 - p.width, max(0, origin.1 + Int((value.translation.width / cell).rounded())))
                                        p.y = min(10 - p.height, max(0, origin.2 + Int((value.translation.height / cell).rounded())))
                                    }
                                }.onEnded { _ in dragOrigin = nil })
                        }
                    }.frame(width: cell * 10, height: cell * 10, alignment: .topLeading)
                        .padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    Text("キーをクリックして割り当て · ドラッグで移動 · 右側でサイズ変更")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    if let key = inspectorKey {
                        InlineKeyEditor(model: model, key: key) { current in inspector(current) }
                            .id("\(key):\(model.selected ?? "empty")")
                    } else {
                        Text("左のキーをクリックして、機能を割り当ててください。").foregroundStyle(.secondary)
                    }
                }.frame(width: 285, height: 540)

            }.disabled(model.busy || !model.loaded)
            if let error = model.validation { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message).font(.callout).textSelection(.enabled)
                Spacer()
                Button("標準配置に戻す") { model.layout = .standard; model.selected = "tasks" }.disabled(model.busy || !model.loaded)
            }
        }.padding(24).frame(minWidth: 855, minHeight: 680).background(Color(nsColor: .windowBackgroundColor))
    }

    private func partView(_ part: LayoutPart) -> some View {
        RoundedRectangle(cornerRadius: 7).fill(tint(part).opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.selected == part.id ? tint(part) : tint(part).opacity(0.3), lineWidth: model.selected == part.id ? 3 : 1))
            .overlay {
                if part.kind == .tasks {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3.fill").font(.title2)
                        Text("タスクエリア").font(.headline)
                        Text("\(part.width) 列 × \(part.height) 行").font(.caption)
                        Text(part.transposed ? "列：プロジェクト ／ 行：タスク" : "行：プロジェクト ／ 列：タスク").font(.caption2)
                    }.foregroundStyle(tint(part)).padding(6).minimumScaleFactor(0.4)
                } else if part.kind == .source {
                    VStack(spacing: 3) { Text("サービス切り替え").font(.caption2.bold()); Text(part.selectedServices.map(\.displayName).joined(separator: " · ")).font(.system(size: 9)) }.padding(3).foregroundStyle(tint(part))
                } else { Text(part.title).font(.system(size: part.kind == .scroll ? 24 : 10, weight: .semibold)).multilineTextAlignment(.center).padding(3).foregroundStyle(tint(part)) }
            }.accessibilityLabel("\(part.title)、\(part.y + 1)行\(part.x + 1)列")
    }
    private func integer(_ key: WritableKeyPath<LayoutPart, Int>, _ fallback: Int) -> Binding<Int> {
        Binding(get: { model.layout.parts.first { $0.id == model.selected }?[keyPath: key] ?? fallback }, set: { value in model.update { $0[keyPath: key] = value } })
    }
    private func inspector(_ part: LayoutPart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(part.title).font(.headline)
            HStack {
                Stepper("列 \(part.x + 1)", value: integer(\.x, 0), in: 0...(10 - part.width))
                Stepper("行 \(part.y + 1)", value: integer(\.y, 0), in: 0...(10 - part.height))
            }
            if part.kind == .tasks || part.kind == .source {
                Stepper("幅 \(part.width) キー", value: integer(\.width, 1), in: 1...(10 - part.x))
                Stepper("高さ \(part.height) キー", value: integer(\.height, 1), in: 1...(10 - part.y))
            }
            if part.kind == .tasks {
                Toggle("プロジェクトとタスクの縦横を入れ替える", isOn: Binding(get: { part.transposed }, set: { v in model.update { $0.transposed = v } }))
            }
            if part.kind == .scroll {
                Picker("方向", selection: Binding(get: { part.direction ?? "up" }, set: { v in model.update { $0.direction = v } })) {
                    Text("↑").tag("up"); Text("↓").tag("down"); Text("←").tag("left"); Text("→").tag("right")
                }
                Text("長押しで連続移動。タスクエリア全体に作用します。").font(.caption).foregroundStyle(.secondary)
            }
            if part.kind == .source {
                Text("使用するサービス").font(.subheadline.bold())
                ForEach(SessionSourceKind.allCases, id: \.rawValue) { source in
                    Toggle(source.displayName, isOn: Binding(get: { part.selectedServices.contains(source) }, set: { enabled in
                        model.update { p in
                            var selected = Set(p.selectedServices)
                            if enabled { selected.insert(source) } else { selected.remove(source) }
                            p.services = SessionSourceKind.allCases.filter { selected.contains($0) }; p.source = nil
                        }
                    }))
                }
                Text("選んだサービスを左上から順に配置します。ここでは切り替え先を選びます。利用の ON/OFF は「サービス」タブで設定します。").font(.caption).foregroundStyle(.secondary)
            }
            if part.kind == .action {
                Text("有効なサービスのうち、前面のアプリに操作を送ります。送信キーは「アクション」タブで確認できます。").font(.caption).foregroundStyle(.secondary)
                if !model.actionCandidates.contains(where: { $0.id == part.action }) {
                    Text("現在のサービス設定では、この操作の送信先がありません。").font(.caption).foregroundStyle(.orange)
                }

            }
            Button("パーツを削除", role: .destructive) { model.remove() }
        }
    }
}

struct CodexActionChooser: View {
    var selected: String?
    var enabledServices = Set(SessionSourceKind.allCases)
    var choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var results: [CodexAction] { Self.search(query, in: DesktopActionCatalog.candidates(services: enabledServices)) }
    static func search(_ query: String, in actions: [CodexAction]) -> [CodexAction] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return actions.filter { action in words.allSatisfy { action.title.localizedCaseInsensitiveContains($0) || action.id.localizedCaseInsensitiveContains($0) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("アクションを選択").font(.title3.bold()); Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
            TextField("操作名やキーワードで検索（例：サイドバー、git、音声）", text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { if let first = results.first { choose(first.id) } }
            Text("\(results.count) 件").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(results) { action in
                        Button { choose(action.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(action.title).font(.body)
                                    Text(SessionSourceKind.allCases.filter { enabledServices.contains($0) && DesktopActionCatalog.supports(action.id, service: $0) }.map(\.displayName).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if action.id == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .background(action.id == selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    if results.isEmpty { Text("一致する操作がありません").foregroundStyle(.secondary).padding(30) }
                }
            }.frame(height: 350)
            Text("同じ操作を複数のボタンに割り当てられます").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 540).onAppear { searchFocused = true }
    }
}

private struct InlineKeyEditor<Inspector: View>: View {
    @ObservedObject var model: LayoutEditorModel
    let key: Int
    @ViewBuilder var inspector: (LayoutPart) -> Inspector
    @State private var kind: LayoutPart.Kind = .action
    @State private var query = ""
    @State private var direction = "up"
    @State private var services = Set(SessionSourceKind.allCases)
    private var occupied: LayoutPart? { model.layout.part(at: key) }
    private var blockedByArea: Bool { occupied.map { $0.kind == .tasks && $0.width * $0.height > 1 && kind != .tasks } ?? false }
    private func assign(action: String? = nil) {
        _ = model.assign(at: key, kind: kind, source: nil, direction: kind == .scroll ? direction : nil, action: action, services: SessionSourceKind.allCases.filter { services.contains($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(key / 10 + 1) 行 · \(key % 10 + 1) 列").font(.headline)
            Picker("機能", selection: $kind) {
                Text("アクション").tag(LayoutPart.Kind.action)
                Text("矢印").tag(LayoutPart.Kind.scroll)
                Text("サービス切り替え").tag(LayoutPart.Kind.source)
                Text("タスクエリア").tag(LayoutPart.Kind.tasks)
            }.pickerStyle(.menu)
            if blockedByArea {
                Text("タスクエリアを縮めて、このキーを空けてから割り当ててください。").font(.caption).foregroundStyle(.orange)
            } else if kind == .action {
                if let occupied { Text(occupied.title).font(.subheadline.bold()) }
                TextField("操作を検索", text: $query).textFieldStyle(.roundedBorder)
                let actions = CodexActionChooser.search(query, in: model.actionCandidates)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(actions) { action in
                            Button { assign(action: action.id) } label: {
                                HStack {
                                    Text(action.title).multilineTextAlignment(.leading)
                                    Spacer()
                                    if occupied?.action == action.id { Image(systemName: "checkmark") }
                                }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .background(occupied?.action == action.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                        }
                        if actions.isEmpty { Text("候補がありません。サービス設定と検索条件を確認してください。").font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(height: 190)
            } else if occupied?.kind != kind {
                if kind == .scroll {
                    Picker("方向", selection: $direction) {
                        Text("↑ 上").tag("up"); Text("↓ 下").tag("down")
                        Text("← 左").tag("left"); Text("→ 右").tag("right")
                    }
                }
                if kind == .source {
                    ForEach(SessionSourceKind.allCases, id: \.rawValue) { source in
                        Toggle(source.displayName, isOn: Binding(get: { services.contains(source) }, set: { on in
                            if on { services.insert(source) } else { services.remove(source) }
                        }))
                    }
                }
                Button("このキーに割り当て") { assign() }.buttonStyle(.borderedProminent)
            }
            if let occupied {
                Divider()
                inspector(occupied)
            } else {
                Text("操作を選ぶとプレビューに反映します。「保存して反映」で実機に適用します。").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                if let occupied { kind = occupied.kind; direction = occupied.direction ?? "up"; services = Set(occupied.selectedServices) }
            }
    }
}

@MainActor
final class LayoutEditorWindow: NSWindowController, NSWindowDelegate {
    let model: LayoutEditorModel
    let services: ServiceSettingsModel
    init(execute: @escaping ([String]) async throws -> String) {
        model = LayoutEditorModel(execute: execute)
        services = ServiceSettingsModel(execute: execute)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 870, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "C100 設定"; window.isReleasedWhenClosed = false
        let layoutModel = model, serviceModel = services
        model.enabledActionServices = []
        services.onServicesChanged = { [weak layoutModel] sources in layoutModel?.enabledActionServices = sources }
        window.contentView = NSHostingView(rootView: TabView {
            LayoutEditorView(model: layoutModel).tabItem { Text("レイアウト") }
            ActionSettingsView(model: layoutModel).tabItem { Text("アクション") }
            ServiceSettingsView(model: serviceModel).tabItem { Text("サービス") }
        })
        super.init(window: window)
        window.delegate = self; window.center(); model.load(); services.load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy || services.busy { return false }
        guard model.dirty || services.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "未保存の変更があります"; alert.addButton(withTitle: "編集を続ける"); alert.addButton(withTitle: "変更を破棄")
        if alert.runModal() == .alertSecondButtonReturn { model.revert(); services.revert(); return true }
        return false
    }
}

extension LayoutEditorWindow {
    static func render(_ layout: KeyboardLayout, path: String, mode: String = "layout", codexHome: String = CodexPaths().home) throws {
        _ = NSApplication.shared
        let model = LayoutEditorModel(execute: { _ in "" })
        model.shortcuts = try ActionShortcutDisplay.read(home: codexHome); model.shortcutError = nil
        model.layout = layout; model.selected = layout.parts.first(where: { $0.kind == .action })?.id ?? layout.parts.first?.id; model.loaded = true; model.message = "パーツを選び、ドラッグで移動できます"
        if mode == "services" { model.selected = layout.parts.first { $0.kind == .source }?.id }
        let content: AnyView
        switch mode {
        case "actions": content = AnyView(ActionSettingsView(model: model))
        case "service-settings":
            let services = ServiceSettingsModel(execute: { _ in "" })
            services.loaded = true; services.configuration = Configuration.example
            services.configuration.enabledServices = [.codex]
            services.message = "サービス設定はレイアウトから独立して保存します"
            content = AnyView(ServiceSettingsView(model: services))
        case "search": content = AnyView(CodexActionChooser(selected: nil, choose: { _ in }))
        case "assignment": content = AnyView(InlineKeyEditor(model: model, key: 80) { part in Text(part.title) })
        default: content = AnyView(LayoutEditorView(model: model))
        }
        let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(x: 0, y: 0, width: mode == "search" ? 584 : mode == "assignment" ? 608 : 870, height: mode == "search" ? 540 : mode == "assignment" ? 350 : 730)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CLIError.runtime("Cannot render layout") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CLIError.runtime("Cannot encode preview") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
