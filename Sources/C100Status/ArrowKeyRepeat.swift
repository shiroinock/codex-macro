import Foundation

/// Uses monotonic time and never catches up missed repeats in a burst.
struct ArrowKeyRepeat {
    private var deadlines: [Int: TimeInterval] = [:]
    private let initialDelay: TimeInterval = 0.35
    private let interval: TimeInterval = 0.08

    mutating func updateHeld(_ keys: Set<Int>, now: TimeInterval) {
        deadlines = deadlines.filter { keys.contains($0.key) }
        for key in keys where GridViewport.arrows[key] != nil && deadlines[key] == nil {
            deadlines[key] = now + initialDelay
        }
    }

    mutating func due(now: TimeInterval) -> [Int] {
        let keys = deadlines.keys.filter { deadlines[$0]! <= now }.sorted()
        for key in keys { deadlines[key] = now + interval }
        return keys
    }
}
