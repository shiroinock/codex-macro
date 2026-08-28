import Foundation

enum CodexTurnSignal: Equatable {
    case started
    case completed
    case aborted
}

final class CodexTurnMonitor {
    private struct Cursor {
        let url: URL
        var offset: UInt64
        var carry = Data()
    }

    private var cursors: [String: Cursor] = [:]
    private let initialReadLimit: UInt64 = 64 * 1024

    func interruptedSessionIDs(
        in sessions: [CatalogSession],
        homeDirectory: String = NSHomeDirectory()
    ) -> Set<String> {
        let activeSessionIDs = Set(sessions.map(\.sessionID))
        cursors = cursors.filter { activeSessionIDs.contains($0.key) }

        var interrupted: Set<String> = []
        for session in sessions {
            guard let url = rolloutURL(for: session, homeDirectory: homeDirectory),
                  let fileSize = fileSize(at: url) else { continue }

            var cursor: Cursor
            var discardInitialPartialLine = false
            if let existing = cursors[session.sessionID],
               existing.url == url,
               existing.offset <= fileSize {
                cursor = existing
            } else {
                let offset = fileSize > initialReadLimit ? fileSize - initialReadLimit : 0
                cursor = Cursor(url: url, offset: offset)
                discardInitialPartialLine = offset > 0
            }

            guard fileSize > cursor.offset,
                  let appended = read(url: url, from: cursor.offset) else {
                cursors[session.sessionID] = cursor
                continue
            }
            cursor.offset = fileSize

            var data = cursor.carry
            data.append(appended)
            if discardInitialPartialLine,
               let firstNewline = data.firstIndex(of: 0x0A) {
                data = Data(data[data.index(after: firstNewline)...])
            }

            let hasTrailingNewline = data.last == 0x0A
            var lines = String(decoding: data, as: UTF8.self).split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            if hasTrailingNewline {
                cursor.carry = Data()
                if lines.last?.isEmpty == true { lines.removeLast() }
            } else if let partial = lines.popLast() {
                cursor.carry = Data(partial.utf8)
            }

            let signal = Self.latestTurnSignal(in: lines.map(String.init))
            if signal == .aborted {
                interrupted.insert(session.sessionID)
            }
            cursors[session.sessionID] = cursor
        }
        return interrupted
    }

    static func latestTurnSignal(in lines: [String]) -> CodexTurnSignal? {
        var signal: CodexTurnSignal?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  let event = payload["type"] as? String else { continue }
            switch event {
            case "task_started": signal = .started
            case "task_complete": signal = .completed
            case "turn_aborted": signal = .aborted
            default: continue
            }
        }
        return signal
    }

    private func rolloutURL(for session: CatalogSession, homeDirectory: String) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: session.createdAt)
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }

        let codexHome = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex")
        let directory = codexHome
            .appendingPathComponent("sessions")
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ), let match = files.first(where: { $0.lastPathComponent.hasSuffix("-\(session.sessionID).jsonl") }) {
            return match
        }

        let archived = codexHome.appendingPathComponent("archived_sessions")
        return (try? FileManager.default.contentsOfDirectory(
            at: archived,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.lastPathComponent.hasSuffix("-\(session.sessionID).jsonl") })
    }

    private func fileSize(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    private func read(url: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }
}
