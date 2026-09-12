import Foundation

/// Logical session coordinates are unlimited; only this projection owns HID keys.
struct GridViewport {
    static let rows = 8
    static let columns = 10
    static let arrows = [88: "up", 97: "left", 98: "down", 99: "right"]
    var topRow = 0
    var selectedRow = 0
    var columnOffsets: [String: Int] = [:]

    mutating func normalize(projects: [String: Int], slots: [SessionSlot]) {
        topRow = min(max(0, topRow), max(0, (projects.values.max() ?? -1) + 1 - Self.rows))
        columnOffsets = columnOffsets.filter { projects[$0.key] != nil }
        for (project, offset) in columnOffsets {
            let length = (slots.filter { $0.projectKey == project }.map(\.column).max() ?? -1) + 1
            columnOffsets[project] = min(max(0, offset), max(0, length - Self.columns))
        }
    }

    func key(for slot: SessionSlot) -> Int? {
        let row = slot.row - topRow
        let column = slot.column - (columnOffsets[slot.projectKey] ?? 0)
        guard (0..<Self.rows).contains(row), (0..<Self.columns).contains(column) else { return nil }
        return row * Self.columns + column
    }

    mutating func move(_ direction: String, projects: [String: Int], slots: [SessionSlot]) {
        normalize(projects: projects, slots: slots)
        if direction == "up" { topRow -= 1 }
        if direction == "down" { topRow += 1 }
        if let project = projects.first(where: { $0.value == topRow + selectedRow })?.key {
            if direction == "left" { columnOffsets[project, default: 0] -= 1 }
            if direction == "right" { columnOffsets[project, default: 0] += 1 }
        }
        normalize(projects: projects, slots: slots)
    }

    func utilityColors(projects: [String: Int], slots: [SessionSlot]) -> [Int: HSVColor] {
        var colors: [Int: HSVColor] = [:]
        for row in 0..<Self.rows {
            let exists = projects.values.contains(topRow + row)
            colors[80 + row] = HSVColor(hue: 128, saturation: 180, value: exists ? (row == selectedRow ? 160 : 36) : 0)
        }
        for (key, direction) in Self.arrows {
            var next = self
            next.move(direction, projects: projects, slots: slots)
            let enabled = next.topRow != topRow || next.columnOffsets.values.reduce(0, +) != columnOffsets.values.reduce(0, +)
            colors[key] = HSVColor(hue: 0, saturation: 0, value: enabled ? 112 : 18)
        }
        return colors
    }
}
