import Foundation

struct LayoutPart: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case tasks, scroll, source, action }
    var id = UUID().uuidString
    var kind: Kind
    var x: Int
    var y: Int
    var width = 1
    var height = 1
    var enabled = true
    var transposed = false
    var direction: String?
    var source: SessionSourceKind?
    var action: String?

    var title: String {
        switch kind {
        case .tasks: return "タスクエリア"
        case .scroll: return ["up": "↑", "down": "↓", "left": "←", "right": "→"][direction ?? ""] ?? "矢印"
        case .source: return source?.displayName ?? "サービス"
        case .action: return CodexAction.catalog.first { $0.id == action }?.title ?? "アクション"
        }
    }
    var keys: [Int] { (y..<(y + height)).flatMap { row in (x..<(x + width)).map { row * 10 + $0 } } }
}

extension SessionSourceKind {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeHerdr: "herdr"
        case .claudeTerminal: "Claude CLI"
        case .claudeDesktop: "Claude Desktop"
        }
    }
}

struct KeyboardLayout: Codable, Equatable {
    var schemaVersion = 1
    var parts: [LayoutPart]
    static var standard: Self {
        Self(parts: [LayoutPart(id: "tasks", kind: .tasks, x: 0, y: 0, width: 10, height: 8)]
             + SessionSourceKind.allCases.enumerated().map { LayoutPart(id: $0.element.rawValue, kind: .source, x: $0.offset, y: 9, source: $0.element) }
             + [(8,8,"up"),(7,9,"left"),(8,9,"down"),(9,9,"right")].map { LayoutPart(id: $0.2, kind: .scroll, x: $0.0, y: $0.1, direction: $0.2) })
    }
    var enabledSources: Set<SessionSourceKind> { Set(parts.filter { $0.enabled && $0.kind == .source }.compactMap(\.source)) }
    var taskArea: LayoutPart? { parts.first { $0.enabled && $0.kind == .tasks } }
    var arrows: [Int: String] { Dictionary(uniqueKeysWithValues: parts.filter { $0.enabled && $0.kind == .scroll }.map { ($0.y * 10 + $0.x, $0.direction!) }) }
    func part(at key: Int) -> LayoutPart? { parts.first { $0.enabled && $0.keys.contains(key) } }
    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw CLIError.usage(message) } }
        try require(schemaVersion == 1, "レイアウトのバージョンに対応していません")
        try require(parts.count <= 120 && Set(parts.map(\.id)).count == parts.count, "パーツ数または ID が不正です")
        var occupied = Set<Int>()
        var sources = Set<SessionSourceKind>()
        try require(parts.filter { $0.kind == .tasks }.count <= 1, "タスクエリアは1つまで配置できます")
        for part in parts {
            try require((0..<10).contains(part.x) && (0..<10).contains(part.y) && (1...10).contains(part.width) && (1...10).contains(part.height) && part.x + part.width <= 10 && part.y + part.height <= 10, "\(part.title): キーボードの範囲を超えています")
            try require(part.kind == .tasks || (part.width == 1 && part.height == 1), "ボタンは1キー分のサイズです")
            switch part.kind {
            case .tasks: break
            case .scroll: try require(["up", "down", "left", "right"].contains(part.direction ?? ""), "矢印の方向が不正です")
            case .source:
                guard let source = part.source else { throw CLIError.usage("サービスを選んでください") }
                try require(sources.insert(source).inserted, "同じサービスは1つまで配置できます")
            case .action: try require(CodexAction.catalog.contains { $0.id == part.action }, "アクションを選んでください")
            }
            if part.enabled {
                try require(occupied.isDisjoint(with: part.keys), "\(part.title): 他のパーツと重なっています")
                occupied.formUnion(part.keys)
            }
        }
    }
    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct LayoutStore {
    let path: String
    func load() throws -> KeyboardLayout {
        guard FileManager.default.fileExists(atPath: path) else { return .standard }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 131072 else { throw CLIError.usage("レイアウトファイルが大きすぎます") }
        let layout = try JSONDecoder().decode(KeyboardLayout.self, from: data)
        try layout.validate(); return layout
    }
    /// Both files remain unchanged if persistence fails before the live swap.
    func apply(_ layout: KeyboardLayout, bindings: CodexActionBindings) throws {
        try layout.validate()
        guard layout.parts.contains(where: { $0.enabled && $0.kind == .action }) else { try save(layout); return }
        let previousBindings = FileManager.default.fileExists(atPath: bindings.url.path) ? try Data(contentsOf: bindings.url) : nil
        try bindings.install(for: layout)
        do { try save(layout) }
        catch {
            if let previousBindings { try previousBindings.write(to: bindings.url, options: .atomic) }
            else if FileManager.default.fileExists(atPath: bindings.url.path) { try FileManager.default.removeItem(at: bindings.url) }
            throw error
        }
    }
    func save(_ layout: KeyboardLayout) throws {
        try layout.validate()
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try layout.json().write(to: url, options: .atomic)
    }
}
