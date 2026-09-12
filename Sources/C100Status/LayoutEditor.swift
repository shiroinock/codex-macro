import AppKit
import SwiftUI

@MainActor
final class LayoutEditorModel: ObservableObject {
    @Published var layout = KeyboardLayout.standard
    @Published var selected: String? = "tasks"
    @Published var message = "読み込み中…"
    @Published var busy = false
    @Published var loaded = false
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
        if let source, let existing = layout.parts.first(where: { $0.source == source && $0.kind == .source }) { selected = existing.id; return }
        guard let key = (0..<100).first(where: { layout.part(at: $0) == nil }) else { message = "空きキーがありません。タスクエリアを縮めるか、パーツを無効にしてください"; return }
        let part = LayoutPart(kind: kind, x: key % 10, y: key / 10, direction: direction, source: source,
                              action: kind == .action ? CodexAction.catalog[0].id : nil)
        layout.parts.append(part); selected = part.id
    }
    func remove() { layout.parts.removeAll { $0.id == selected }; selected = layout.parts.first?.id }
    func revert() { layout = saved; selected = layout.parts.first?.id; message = "未保存の変更を取り消しました" }
}

struct LayoutEditorView: View {
    @ObservedObject var model: LayoutEditorModel
    @State private var actionSearch = ""
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
                            Menu("サービス") { ForEach(SessionSourceKind.allCases, id: \.rawValue) { source in
                                Button(source.displayName) { model.add(.source, source: source) }
                            } }
                            Button("Codex アクション") { model.add(.action) }
                        }.disabled(model.busy || !model.loaded)
                    }
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<100, id: \.self) { key in
                            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045))
                                .overlay(Text("\(key / 10 + 1)·\(key % 10 + 1)").font(.system(size: 9)).foregroundStyle(.tertiary))
                                .frame(width: cell - 4, height: cell - 4).offset(x: CGFloat(key % 10) * cell, y: CGFloat(key / 10) * cell)
                        }
                        ForEach(model.layout.parts.filter(\.enabled)) { part in
                            partView(part)
                                .frame(width: CGFloat(part.width) * cell - 4, height: CGFloat(part.height) * cell - 4)
                                .offset(x: CGFloat(part.x) * cell, y: CGFloat(part.y) * cell)
                                .onTapGesture { model.selected = part.id }
                                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
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
                    Text("ドラッグで移動 · 右側でサイズ変更 · 重なりは保存時にチェック")
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
                    }.frame(height: 190)
                    Divider()
                    if let part = model.layout.parts.first(where: { $0.id == model.selected }) { inspector(part) }
                    Spacer(minLength: 0)
                }.frame(width: 285)
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
                } else { Text(part.title).font(.system(size: part.kind == .scroll ? 24 : 10, weight: .semibold)).multilineTextAlignment(.center).padding(3).foregroundStyle(tint(part)) }
            }.accessibilityLabel("\(part.title)、\(part.y + 1)行\(part.x + 1)列")
    }
    private func integer(_ key: WritableKeyPath<LayoutPart, Int>, _ fallback: Int) -> Binding<Int> {
        Binding(get: { model.layout.parts.first { $0.id == model.selected }?[keyPath: key] ?? fallback }, set: { value in model.update { $0[keyPath: key] = value } })
    }
    private func inspector(_ part: LayoutPart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(part.title).font(.headline)
            Toggle(part.kind == .source ? "このサービスを使用する" : "有効", isOn: Binding(get: { part.enabled }, set: { v in model.update { $0.enabled = v } }))
            HStack {
                Stepper("列 \(part.x + 1)", value: integer(\.x, 0), in: 0...(10 - part.width))
                Stepper("行 \(part.y + 1)", value: integer(\.y, 0), in: 0...(10 - part.height))
            }
            if part.kind == .tasks {
                Stepper("幅 \(part.width) キー", value: integer(\.width, 1), in: 1...(10 - part.x))
                Stepper("高さ \(part.height) キー", value: integer(\.height, 1), in: 1...(10 - part.y))
                Toggle("プロジェクトとタスクの縦横を入れ替える", isOn: Binding(get: { part.transposed }, set: { v in model.update { $0.transposed = v } }))
            }
            if part.kind == .scroll {
                Picker("方向", selection: Binding(get: { part.direction ?? "up" }, set: { v in model.update { $0.direction = v } })) {
                    Text("↑").tag("up"); Text("↓").tag("down"); Text("←").tag("left"); Text("→").tag("right")
                }
                Text("長押しで連続移動。タスクエリア全体に作用します。").font(.caption).foregroundStyle(.secondary)
            }
            if part.kind == .source { Text("OFF にすると、このサービスのタスク取得・表示・切り替えを停止します。配置は保持されます。").font(.caption).foregroundStyle(.secondary) }
            if part.kind == .action {
                TextField("操作を検索", text: $actionSearch)
                Picker("操作", selection: Binding(get: { part.action ?? CodexAction.catalog[0].id }, set: { v in model.update { $0.action = v } })) {
                    ForEach(CodexAction.catalog.filter { actionSearch.isEmpty || $0.id == part.action || $0.title.localizedCaseInsensitiveContains(actionSearch) || $0.id.localizedCaseInsensitiveContains(actionSearch) }) { action in Text(action.title).tag(action.id) }
                }
                Text(CodexAction.installed.isEmpty ? "標準の操作一覧を使用中" : "Codex から読み込んだ \(CodexAction.catalog.count) 操作").font(.caption).foregroundStyle(.secondary)
                Text("保存時に Codex の専用ショートカットを追加します。Codex / ChatGPT が前面のとき、現在のタスクに実行します。").font(.caption).foregroundStyle(.secondary)
                Button("アクセシビリティ設定を開く") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }.font(.caption)
            }
            Button("パーツを削除", role: .destructive) { model.remove() }
        }
    }
}

@MainActor
final class LayoutEditorWindow: NSWindowController, NSWindowDelegate {
    let model: LayoutEditorModel
    init(execute: @escaping ([String]) async throws -> String) {
        model = LayoutEditorModel(execute: execute)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 870, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "C100 レイアウト"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LayoutEditorView(model: model))
        super.init(window: window)
        window.delegate = self; window.center(); model.load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.busy { return false }
        guard model.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "未保存の変更があります"; alert.addButton(withTitle: "編集を続ける"); alert.addButton(withTitle: "変更を破棄")
        if alert.runModal() == .alertSecondButtonReturn { model.revert(); return true }
        return false
    }
}

extension LayoutEditorWindow {
    static func render(_ layout: KeyboardLayout, path: String) throws {
        _ = NSApplication.shared
        let model = LayoutEditorModel(execute: { _ in "" })
        model.layout = layout; model.selected = layout.parts.first(where: { $0.kind == .action })?.id ?? layout.parts.first?.id; model.loaded = true; model.message = "パーツを選び、ドラッグで移動できます"
        let view = NSHostingView(rootView: LayoutEditorView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 870, height: 730)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CLIError.runtime("Cannot render layout") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CLIError.runtime("Cannot encode preview") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
