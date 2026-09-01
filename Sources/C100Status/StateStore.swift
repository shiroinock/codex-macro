import Darwin
import Foundation

final class OperationLock {
    private let lockURL: URL

    init(uid: uid_t = RuntimePaths.ownerUID) {
        lockURL = URL(fileURLWithPath: "/tmp/keychron-c100-status-\(uid)-operation.lock")
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CLIError.runtime("Could not open operation lock: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CLIError.runtime("Could not acquire operation lock: \(String(cString: strerror(errno)))")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// A single session's slot in the grid. M5 adds `source`: with 4 independent
/// per-layer grids sharing the same physical keys 0-89, `row`/`column` alone
/// are no longer globally unique -- a herdr session at row 2 col 0 and a
/// Codex session at row 2 col 0 are both valid, simultaneous placements that
/// just happen to occupy the same *physical* key at different times (when
/// their layer is active). `source` is what `StateStore` uses to keep every
/// per-layer read/write (`update`, `reconcile`, `assignment(at:source:)`,
/// ...) scoped to the right namespace.
struct SessionSlot: Codable, Equatable {
    let projectKey: String
    let source: SessionSourceKind
    let row: Int
    let column: Int
    var status: AgentStatus

    var keyIndex: Int { row * 10 + column }
}

/// The full grid: all 4 layers' sessions and per-layer project-row
/// assignments, keyed by `SessionSourceKind.rawValue` so a session's actual
/// display key is only ever resolved by additionally filtering on `source`
/// (the daemon's active layer). This "one GridState holding everything,
/// filtered for display" shape (rather than 4 separate `GridState`s) was
/// chosen because `StateStore.reconcile` already needs to read/carry-forward
/// existing per-session status across a resync, and a single `sessions`
/// dictionary keyed by session id makes that trivial (`previous.sessions[id]?
/// .status`) regardless of which layer(s) changed that sync -- 4 separate
/// dictionaries would need the same cross-referencing anyway for hook
/// updates on non-active-layer sessions, with no benefit. `GridState` is
/// also entirely rebuilt (`StatusDaemon.run()` calls `stateStore.clear()`
/// before ever reading it) on every daemon start, so changing this schema
/// carries no cross-restart JSON-compatibility burden -- unlike
/// `LayerSelectionStore`'s file, which does need to survive a restart and is
/// therefore kept as its own small, independently-versioned file.
struct GridState: Codable, Equatable {
    /// Grid rows 0-8 are available to session placement; row 9 (keys
    /// 90-99) is reserved for the layer switch bar (see `LayerKeyColorLogic`).
    static let rowCapacity = 9
    static let columnCapacity = 10

    /// `source.rawValue` -> project key -> row, scoped per layer.
    var projectRows: [String: [String: Int]] = [:]
    var sessions: [String: SessionSlot] = [:]

    mutating func update(
        sessionID: String,
        projectKey: String,
        source: SessionSourceKind,
        status: AgentStatus?,
        remove: Bool = false
    ) throws -> SessionMutation {
        let previous = sessions[sessionID]
        if remove {
            sessions.removeValue(forKey: sessionID)
        } else if let status {
            if var slot = previous, slot.source == source {
                slot.status = status
                sessions[sessionID] = slot
            } else {
                var rowsForSource = projectRows[source.rawValue] ?? [:]
                let row: Int
                if let assignedRow = rowsForSource[projectKey] {
                    row = assignedRow
                } else {
                    let usedRows = Set(rowsForSource.values)
                    guard let freeRow = (0..<Self.rowCapacity).first(where: { !usedRows.contains($0) }) else {
                        throw CLIError.runtime("No unassigned C100 project rows remain for layer \(source.rawValue)")
                    }
                    row = freeRow
                    rowsForSource[projectKey] = row
                    projectRows[source.rawValue] = rowsForSource
                }

                let usedColumns = Set(
                    sessions.values.filter { $0.source == source && $0.row == row }.map(\.column)
                )
                guard let column = (0..<Self.columnCapacity).first(where: { !usedColumns.contains($0) }) else {
                    throw CLIError.runtime("No unassigned C100 session columns remain for project \(projectKey)")
                }
                sessions[sessionID] = SessionSlot(
                    projectKey: projectKey,
                    source: source,
                    row: row,
                    column: column,
                    status: status
                )
            }
        }
        return SessionMutation(
            sessionID: sessionID,
            slot: sessions[sessionID],
            previousSlot: previous
        )
    }

    mutating func assignIfNeeded(
        sessionID: String,
        projectKey: String,
        source: SessionSourceKind,
        initialStatus: AgentStatus = .idle
    ) throws -> SessionMutation {
        if let existing = sessions[sessionID], existing.source == source {
            return SessionMutation(sessionID: sessionID, slot: existing, previousSlot: existing)
        }
        return try update(sessionID: sessionID, projectKey: projectKey, source: source, status: initialStatus)
    }
}

struct SessionMutation {
    let sessionID: String
    let slot: SessionSlot?
    let previousSlot: SessionSlot?

    var changed: Bool { slot != previousSlot }
}

/// `previous`/`current` are scoped to a single layer's slice of the grid
/// (see `StateStore.reconcile(source:...)`) -- comparing/iterating them is
/// exactly the pre-M5 whole-grid behavior, just narrowed to one
/// `SessionSourceKind` per call so a resync of one layer never reports
/// another layer's untouched sessions as "changed".
struct GridReconciliation {
    let previous: GridState
    let current: GridState

    var changed: Bool { previous != current }
}

final class StateStore {
    private let stateURL: URL
    private let legacyEndedSessionsURL: URL
    private let lockURL: URL

    init(
        uid: uid_t = RuntimePaths.ownerUID,
        runtimeDirectory: URL = URL(fileURLWithPath: "/tmp")
    ) {
        let base = "keychron-c100-status-\(uid)"
        stateURL = runtimeDirectory.appendingPathComponent("\(base).json")
        legacyEndedSessionsURL = runtimeDirectory.appendingPathComponent("\(base)-ended-sessions.json")
        lockURL = runtimeDirectory.appendingPathComponent("\(base).lock")
    }

    func update(
        sessionID: String,
        projectKey: String,
        source: SessionSourceKind,
        status: AgentStatus?,
        remove: Bool = false
    ) throws -> SessionMutation {
        try withLock {
            var state = try read()
            let mutation = try state.update(
                sessionID: sessionID,
                projectKey: projectKey,
                source: source,
                status: status,
                remove: remove
            )
            if mutation.changed {
                try write(state)
            }
            return mutation
        }
    }

    func assignIfNeeded(sessionID: String, projectKey: String, source: SessionSourceKind) throws -> SessionMutation {
        try withLock {
            var state = try read()
            let mutation = try state.assignIfNeeded(sessionID: sessionID, projectKey: projectKey, source: source)
            if mutation.changed {
                try write(state)
            }
            return mutation
        }
    }

    /// Looks up whichever session (if any) `source`'s layer currently has
    /// placed at `keyIndex`. Scoped to `source` because the same physical
    /// key index can simultaneously hold a different session in each of the
    /// 4 layers -- only the active layer's occupant is reachable by a key
    /// press.
    func assignment(at keyIndex: Int, source: SessionSourceKind) throws -> (sessionID: String, slot: SessionSlot)? {
        try withLock {
            try read().sessions
                .first(where: { $0.value.source == source && $0.value.keyIndex == keyIndex })
                .map { (sessionID: $0.key, slot: $0.value) }
        }
    }

    /// All sessions across every layer, unfiltered -- used where the
    /// consumer cares about session status regardless of which layer is
    /// currently displayed (e.g. the manual all-keys status override, or
    /// looking up a specific known session id's status).
    func assignments() throws -> [(sessionID: String, slot: SessionSlot)] {
        try withLock {
            try read().sessions
                .map { (sessionID: $0.key, slot: $0.value) }
                .sorted { $0.slot.keyIndex < $1.slot.keyIndex }
        }
    }

    /// Only `source`'s layer's sessions -- what should actually be painted
    /// onto keys 0-89 while that layer is active.
    func assignments(source: SessionSourceKind) throws -> [(sessionID: String, slot: SessionSlot)] {
        try withLock {
            try read().sessions
                .filter { $0.value.source == source }
                .map { (sessionID: $0.key, slot: $0.value) }
                .sorted { $0.slot.keyIndex < $1.slot.keyIndex }
        }
    }

    /// Replaces `source`'s layer's placements wholesale (mirroring the pre-M5
    /// whole-grid `reconcile`), carrying forward each session's existing
    /// status, while leaving every other layer's sessions/`projectRows`
    /// completely untouched.
    func reconcile(
        source: SessionSourceKind,
        projectRows: [String: Int],
        placements: [(sessionID: String, projectKey: String, row: Int, column: Int)]
    ) throws -> GridReconciliation {
        try withLock {
            let previousState = try read()
            let previousForSource = previousState.sessions.filter { $0.value.source == source }

            var newSessionsForSource: [String: SessionSlot] = [:]
            for placement in placements {
                newSessionsForSource[placement.sessionID] = SessionSlot(
                    projectKey: placement.projectKey,
                    source: source,
                    row: placement.row,
                    column: placement.column,
                    status: previousState.sessions[placement.sessionID]?.status ?? .idle
                )
            }

            var currentState = previousState
            currentState.sessions = previousState.sessions.filter { $0.value.source != source }
            for (sessionID, slot) in newSessionsForSource {
                currentState.sessions[sessionID] = slot
            }
            currentState.projectRows[source.rawValue] = projectRows

            if currentState != previousState {
                try write(currentState)
            }

            var previousView = GridState()
            previousView.sessions = previousForSource
            previousView.projectRows = [source.rawValue: previousState.projectRows[source.rawValue] ?? [:]]
            var currentView = GridState()
            currentView.sessions = newSessionsForSource
            currentView.projectRows = [source.rawValue: projectRows]
            return GridReconciliation(previous: previousView, current: currentView)
        }
    }

    func discardLegacyEndedSessions() throws {
        try withLock {
            guard FileManager.default.fileExists(atPath: legacyEndedSessionsURL.path) else { return }
            try FileManager.default.removeItem(at: legacyEndedSessionsURL)
        }
    }

    @discardableResult
    func clear() throws -> [SessionSlot] {
        try withLock {
            let previous = (try? read()) ?? GridState()
            try? FileManager.default.removeItem(at: stateURL)
            return Array(previous.sessions.values)
        }
    }

    private func read() throws -> GridState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return GridState() }
        return try JSONDecoder().decode(GridState.self, from: Data(contentsOf: stateURL))
    }

    private func write(_ state: GridState) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        Darwin.chmod(stateURL.path, S_IRUSR | S_IWUSR)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CLIError.runtime("Could not open state lock: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CLIError.runtime("Could not acquire state lock: \(String(cString: strerror(errno)))")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
