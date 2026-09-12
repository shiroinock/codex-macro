import AppKit
import SwiftUI

@MainActor
final class LayoutEditorModel: ObservableObject {
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
        _ = assign(at: key, kind: kind, source: source, direction: direction, action: kind == .action ? DesktopActionCatalog.catalog[0].id : nil)
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
    @State private var assignmentKey: AssignmentKey?
    @State private var choosingAction = false
    @State private var dragOrigin: (String, Int, Int)?
    private let cell: CGFloat = 46
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
                        Menu("パーツを追加") {
                            Button("タスクエリア") { model.add(.tasks) }
                            Menu("スクロール") { ForEach(["up","down","left","right"], id: \.self) { dir in
                                Button(["up":"↑ 上","down":"↓ 下","left":"← 左","right":"→ 右"][dir]!) { model.add(.scroll, direction: dir) }
                            } }
                            Button("サービス切り替え") { model.add(.source) }
                            Button("アクション") { model.add(.action) }
                        }.disabled(model.busy || !model.loaded)
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<100, id: \.self) { key in
                            Button { assignmentKey = AssignmentKey(key: key) } label: {
                                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045))
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
                                    assignmentKey = AssignmentKey(key: (part.y + y) * 10 + part.x + x)
                                })
                                .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                                    if dragOrigin?.0 != part.id { dragOrigin = (part.id, part.x, part.y); model.selected = part.id }
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("配置したパーツ").font(.headline)
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(model.layout.parts) { part in
                                Button { model.selected = part.id } label: {
                                    HStack {
                                        Circle().fill(part.enabled ? tint(part) : .gray).frame(width: 7, height: 7)
                                        Text(part.title).lineLimit(1)
                                        Spacer()
                                        Text(part.enabled ? "\(part.y + 1),\(part.x + 1)" : "OFF").font(.caption).foregroundStyle(.secondary)
                                    }.padding(7).contentShape(Rectangle())
                                        .background(model.selected == part.id ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 150)
                    Divider()
                    ScrollView { if let part = model.layout.parts.first(where: { $0.id == model.selected }) { inspector(part).frame(maxWidth: .infinity, alignment: .leading) } }
                    Spacer(minLength: 0)
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
        .sheet(item: $assignmentKey) { target in
            KeyAssignmentView(model: model, key: target.key)
        }
        .sheet(isPresented: $choosingAction) {
            CodexActionChooser(selected: model.layout.parts.first { $0.id == model.selected }?.action) { action in
                model.update { if $0.action != action { $0.claudeShortcut = nil }; $0.action = action }; choosingAction = false
            }
        }
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
                Button { choosingAction = true } label: {
                    Label("操作を検索・変更…", systemImage: "magnifyingglass")
                }
                Text("前面のアプリに応じて、同じ操作の送信キーを自動選択します。").font(.caption).foregroundStyle(.secondary)
                Text(DesktopActionCatalog.supportLabel(part.action)).font(.caption)
                GroupBox("Claude Desktop に送信するキー") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let key = part.claudeShortcut ?? DesktopActionCatalog.claudeKey(for: part.action) {
                            Text(ActionShortcutDisplay(accelerator: key, dedicated: false).label).font(.title2.monospaced().bold())
                            Text(part.claudeShortcut == nil ? "Code タブ用の内蔵対応" : "以前に保存した手動設定").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("送信方法は未対応です。このアプリが前面のときは実行しません。").font(.caption).foregroundStyle(.secondary)
                        }
                        if part.claudeShortcut != nil {
                            Button("内蔵の対応に戻す") { model.update { $0.claudeShortcut = nil } }.font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Codex に送信するキー") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = model.shortcutError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        } else if let shortcut = model.shortcuts[part.action ?? ""] {
                            Text(shortcut.label).font(.system(.title2, design: .monospaced).bold()).textSelection(.enabled)
                            Text(shortcut.dedicated ? "C100 専用ショートカット" : "Codex の既存ショートカット").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(DesktopActionCatalog.supportsCodex(part.action) ? "送信キーが未設定です。「保存して反映」で割り当てます。" : "この操作の送信方法は未対応です。").font(.caption)
                        }
                        Button("送信キーを再確認") { model.refreshShortcuts() }.font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                Text(model.hardwareKeyOutput ? "送信元: C100（USB キーボード）" : "送信元: macOS（アクセシビリティ）").font(.caption).foregroundStyle(.secondary)
                Text("キーには操作を1つだけ割り当てます。送信キーの表示は確認用です。その他のアプリには送信しません。").font(.caption).foregroundStyle(.secondary)
                if !model.hardwareKeyOutput { Button("アクセシビリティ設定を開く") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }.font(.caption) }
            }
            Button("パーツを削除", role: .destructive) { model.remove() }
        }
    }
}

private struct AssignmentKey: Identifiable {
    let key: Int
    var id: Int { key }
}

struct CodexActionChooser: View {
    var selected: String?
    var choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var results: [CodexAction] { Self.search(query, in: DesktopActionCatalog.catalog) }
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
                                    Text(DesktopActionCatalog.supportLabel(action.id)).font(.caption).foregroundStyle(.secondary)
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

private struct KeyAssignmentView: View {
    @ObservedObject var model: LayoutEditorModel
    let key: Int
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LayoutPart.Kind = .action
    @State private var services = Set(SessionSourceKind.allCases)
    @State private var direction = "up"
    @State private var action: String?
    @State private var searching = false
    private var occupied: LayoutPart? { model.layout.part(at: key) }
    private var blockedByArea: Bool { occupied.map { $0.kind == .tasks && $0.width * $0.height > 1 && kind != .tasks } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(key / 10 + 1) 行 · \(key % 10 + 1) 列の割り当て").font(.title3.bold())
                Spacer(); Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let occupied {
                HStack {
                    Text("現在：\(occupied.title)").foregroundStyle(.secondary)
                    Spacer()
                    Button("配置・サイズを編集") { model.selected = occupied.id; dismiss() }
                }
            }
            Text("どの機能を割り当てますか？").font(.headline)
            Picker("機能", selection: $kind) {
                Text("アクション").tag(LayoutPart.Kind.action)
                Text("矢印").tag(LayoutPart.Kind.scroll)
                Text("サービス切り替え").tag(LayoutPart.Kind.source)
                Text("タスクエリア").tag(LayoutPart.Kind.tasks)
            }.pickerStyle(.segmented).labelsHidden()
            switch kind {
            case .action:
                Button { searching = true } label: {
                    Label(action.flatMap { id in DesktopActionCatalog.catalog.first { $0.id == id }?.title } ?? "アクションを検索…", systemImage: "magnifyingglass")
                }
            case .scroll:
                Picker("方向", selection: $direction) {
                    Text("↑ 上").tag("up"); Text("↓ 下").tag("down"); Text("← 左").tag("left"); Text("→ 右").tag("right")
                }.pickerStyle(.segmented)
            case .source:
                Text("使用するサービス")
                ForEach(SessionSourceKind.allCases, id: \.rawValue) { source in
                    Toggle(source.displayName, isOn: Binding(get: { services.contains(source) }, set: { enabled in
                        if enabled { services.insert(source) } else { services.remove(source) }
                    }))
                }
                Text("選択したサービスを1つのパーツにまとめます。配置済みなら、このキーへ移動します。").font(.caption).foregroundStyle(.secondary)
            case .tasks:
                Text("タスクエリアは1つです。新規は1キーから作り、右側の設定で幅と高さを広げます。配置済みならそのエリアを移動・編集します。").font(.callout).foregroundStyle(.secondary)
            }
            if blockedByArea { Text("このキーはタスクエリア内です。「配置・サイズを編集」でエリアを縮めてから割り当ててください。").foregroundStyle(.orange) }
            HStack {
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                Button("割り当て") {
                    if model.assign(at: key, kind: kind, source: nil, direction: kind == .scroll ? direction : nil, action: kind == .action ? action : nil, services: SessionSourceKind.allCases.filter { services.contains($0) }) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(blockedByArea || (kind == .action && action == nil))
            }
        }.padding(24).frame(width: 560)
            .onAppear { if let occupied { kind = occupied.kind; services = Set(occupied.selectedServices); direction = occupied.direction ?? "up"; action = occupied.action } }
            .sheet(isPresented: $searching) { CodexActionChooser(selected: action) { action = $0; searching = false } }
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
        window.contentView = NSHostingView(rootView: TabView {
            LayoutEditorView(model: layoutModel).tabItem { Text("レイアウト") }
            ServiceSettingsView(model: serviceModel).tabItem { Text("サービス") }
        })
        super.init(window: window)
        window.delegate = self; window.center(); model.load()
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
        case "service-settings":
            let services = ServiceSettingsModel(execute: { _ in "" })
            services.loaded = true; services.configuration = Configuration.example
            services.configuration.enabledServices = [.codex]
            services.message = "サービス設定はレイアウトから独立して保存します"
            content = AnyView(ServiceSettingsView(model: services))
        case "search": content = AnyView(CodexActionChooser(selected: nil, choose: { _ in }))
        case "assignment": content = AnyView(KeyAssignmentView(model: model, key: 80))
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
