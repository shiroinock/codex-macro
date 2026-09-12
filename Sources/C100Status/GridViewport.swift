import Foundation

/// Logical session coordinates are unlimited; only this projection owns HID keys.
struct GridViewport {
    static let rows = 8
    static let columns = 10
    static let arrows = [88: "up", 97: "left", 98: "down", 99: "right"]
    var topRow = 0
    var leftColumn = 0

    mutating func normalize(projects: [String: Int], slots: [SessionSlot]) {
        topRow = min(max(0, topRow), max(0, (projects.values.max() ?? -1) + 1 - Self.rows))
        leftColumn = min(max(0, leftColumn), max(0, (slots.map(\.column).max() ?? -1) + 1 - Self.columns))
    }

    func key(for slot: SessionSlot) -> Int? {
        let row = slot.row - topRow
        let column = slot.column - leftColumn
        guard (0..<Self.rows).contains(row), (0..<Self.columns).contains(column) else { return nil }
        return row * Self.columns + column
    }

    mutating func move(_ direction: String, projects: [String: Int], slots: [SessionSlot]) {
        normalize(projects: projects, slots: slots)
        if direction == "up" { topRow -= 1 }
        if direction == "down" { topRow += 1 }
        if direction == "left" { leftColumn -= 1 }
        if direction == "right" { leftColumn += 1 }
        normalize(projects: projects, slots: slots)
    }

    func utilityColors(projects: [String: Int], slots: [SessionSlot]) -> [Int: HSVColor] {
        var colors: [Int: HSVColor] = [:]
        for (key, direction) in Self.arrows {
            var next = self
            next.move(direction, projects: projects, slots: slots)
            let enabled = next.topRow != topRow || next.leftColumn != leftColumn
            colors[key] = HSVColor(hue: 0, saturation: 0, value: enabled ? 112 : 18)
        }
        return colors
    }
}
