import AppKit
import Foundation

/// Read command metadata only; never execute or modify desktop application code.
/// The asar adapter is deliberately isolated: unknown versions fall back to the
/// small verified catalog, and existing layouts still validate against that set.
enum CodexCommandCatalog {
    static func installed() -> [CodexAction] {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexNavigator.bundleIdentifier),
              let archive = try? Archive(url: app.appendingPathComponent("Contents/Resources/app.asar")) else { return [] }
        let candidates = archive.entries.keys.filter { $0.hasPrefix(".vite/build/src-") && $0.hasSuffix(".js") }.sorted()
        var actions: [CodexAction] = []
        for path in candidates {
            guard let source = archive.text(path), source.contains("id:`newTask`") else { continue }
            actions = parse(source)
            if !actions.isEmpty { break }
        }
        guard actions.count > 20 else { return [] }
        if let path = archive.entries.keys.sorted().first(where: { $0.hasPrefix("webview/assets/ja-JP-") && $0.hasSuffix(".js") }),
           let locale = archive.text(path) {
            let names = captures(#""(codex\.command\.[^"]+)":`([^`]+)`"#, in: locale)
            let localized = Dictionary(names.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
            actions = actions.map { action in
                var action = action
                if let title = localized[action.titleKey ?? ""] { action.title = title }
                return action
            }
        }
        return actions
    }

    static func parse(_ source: String) -> [CodexAction] {
        guard let regex = try? NSRegularExpression(pattern: #"\{id:[`"]([^`"$]+)[`"],titleIntlId:[`"](codex\.command\.[^`"]+)[`"]"#) else { return [] }
        let ns = source as NSString
        var found: [String: CodexAction] = [:]
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1)), titleKey = ns.substring(with: match.range(at: 2))
            guard let range = Range(NSRange(location: match.range.location, length: 1), in: source),
                  let body = object(in: source, start: range.lowerBound) else { continue }
            // Native/global hotkeys have a separate press/release controller.
            // They cannot be appended as an app-scoped alias without changing
            // the user's global shortcut, so do not advertise them as assignable.
            if body.contains("shortcutScope:`os-global`") || body.contains("shortcutConfigurable:!1") { continue }
            if let platforms = captures(#"availableIn:\[([^\]]+)\]"#, in: body).first?.first,
               !platforms.contains("electron") { continue }
            let electron = member("electron", in: body) ?? ""
            let platform = member("platformDefaultKeybindings", in: electron)
            let platformKeys = platform.flatMap { captures(#"macOS:\[([^\]]*)\]"#, in: $0).first?.first }
            let defaults = platformKeys ?? captures(#"defaultKeybindings:\[([^\]]*)\]"#, in: electron).first?.first ?? ""
            let keys = captures(#"key:[`"]([^`"]+)[`"]"#, in: defaults).map { $0[0] }
            let title = captures(#"menuTitle:[`"]([^`"]+)[`"]"#, in: electron).first?.first ?? id
            found[id] = CodexAction(id: id, title: title, defaults: keys, titleKey: titleKey)
        }
        return found.values.sorted { $0.id < $1.id }
    }
    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
        }
    }
    private static func member(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: name + ":{") else { return nil }
        return object(in: text, start: text.index(before: range.upperBound))
    }
    private static func object(in text: String, start: String.Index) -> String? {
        var depth = 0, quote: Character?, escaped = false, cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if let delimiter = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == delimiter { quote = nil }
            } else if character == "`" || character == "\"" || character == "'" { quote = character }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...cursor]) }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private struct Archive {
        let data: Data
        let payloadOffset: Int
        var entries: [String: (offset: Int, size: Int)] = [:]
        init(url: URL) throws {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            self.data = data
            guard data.count >= 16 else { throw CLIError.runtime("Invalid asar header") }
            func uint(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | (Int(data[at + $1]) << (8 * $1)) } }
            let headerSize = uint(4), jsonSize = uint(12)
            guard jsonSize > 0, jsonSize < 16_000_000, 16 + jsonSize <= data.count, 8 + headerSize <= data.count else { throw CLIError.runtime("Invalid asar size") }
            payloadOffset = 8 + headerSize
            let root = try JSONSerialization.jsonObject(with: data.subdata(in: 16..<(16 + jsonSize))) as? [String: Any] ?? [:]
            func walk(_ node: [String: Any], _ path: String) {
                for (name, value) in node["files"] as? [String: [String: Any]] ?? [:] {
                    let path = path.isEmpty ? name : path + "/" + name
                    if value["files"] != nil { walk(value, path) }
                    else if let offset = value["offset"] as? String, let offset = Int(offset), let size = value["size"] as? Int {
                        entries[path] = (offset, size)
                    }
                }
            }
            walk(root, "")
        }
        func text(_ path: String) -> String? {
            guard let entry = entries[path], entry.offset >= 0, entry.size >= 0, entry.size < 32_000_000,
                  entry.offset <= data.count - payloadOffset, entry.size <= data.count - payloadOffset - entry.offset else { return nil }
            return String(data: data.subdata(in: (payloadOffset + entry.offset)..<(payloadOffset + entry.offset + entry.size)), encoding: .utf8)
        }
    }
}
