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

struct SessionSlot: Codable, Equatable {
    let projectKey: String
    let row: Int
    let column: Int
    var status: AgentStatus

    var keyIndex: Int { row * 10 + column }
}

struct GridState: Codable, Equatable {
    var projectRows: [String: Int] = [:]
    var sessions: [String: SessionSlot] = [:]

    mutating func update(
        sessionID: String,
        projectKey: String,
        status: AgentStatus?,
        remove: Bool = false
    ) throws -> SessionMutation {
        let previous = sessions[sessionID]
        if remove {
            sessions.removeValue(forKey: sessionID)
        } else if let status {
            if var slot = previous {
                slot.status = status
                sessions[sessionID] = slot
            } else {
                let row: Int
                if let assignedRow = projectRows[projectKey] {
                    row = assignedRow
                } else {
                    let usedRows = Set(projectRows.values)
                    guard let freeRow = (0..<10).first(where: { !usedRows.contains($0) }) else {
                        throw CLIError.runtime("No unassigned C100 project rows remain")
                    }
                    row = freeRow
                    projectRows[projectKey] = row
                }

                let usedColumns = Set(sessions.values.filter { $0.row == row }.map(\.column))
                guard let column = (0..<10).first(where: { !usedColumns.contains($0) }) else {
                    throw CLIError.runtime("No unassigned C100 session columns remain for project \(projectKey)")
                }
                sessions[sessionID] = SessionSlot(
                    projectKey: projectKey,
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
        initialStatus: AgentStatus = .idle
    ) throws -> SessionMutation {
        if let existing = sessions[sessionID] {
            return SessionMutation(sessionID: sessionID, slot: existing, previousSlot: existing)
        }
        return try update(sessionID: sessionID, projectKey: projectKey, status: initialStatus)
    }
}

struct SessionMutation {
    let sessionID: String
    let slot: SessionSlot?
    let previousSlot: SessionSlot?

    var changed: Bool { slot != previousSlot }
}

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
        status: AgentStatus?,
        remove: Bool = false
    ) throws -> SessionMutation {
        try withLock {
            var state = try read()
            let mutation = try state.update(
                sessionID: sessionID,
                projectKey: projectKey,
                status: status,
                remove: remove
            )
            if mutation.changed {
                try write(state)
            }
            return mutation
        }
    }

    func assignIfNeeded(sessionID: String, projectKey: String) throws -> SessionMutation {
        try withLock {
            var state = try read()
            let mutation = try state.assignIfNeeded(sessionID: sessionID, projectKey: projectKey)
            if mutation.changed {
                try write(state)
            }
            return mutation
        }
    }

    func assignment(at keyIndex: Int) throws -> (sessionID: String, slot: SessionSlot)? {
        try withLock {
            try read().sessions
                .first(where: { $0.value.keyIndex == keyIndex })
                .map { (sessionID: $0.key, slot: $0.value) }
        }
    }

    func assignments() throws -> [(sessionID: String, slot: SessionSlot)] {
        try withLock {
            try read().sessions
                .map { (sessionID: $0.key, slot: $0.value) }
                .sorted { $0.slot.keyIndex < $1.slot.keyIndex }
        }
    }

    func reconcile(
        projectRows: [String: Int],
        placements: [(sessionID: String, projectKey: String, row: Int, column: Int)]
    ) throws -> GridReconciliation {
        try withLock {
            let previous = try read()
            var sessions: [String: SessionSlot] = [:]
            for placement in placements {
                sessions[placement.sessionID] = SessionSlot(
                    projectKey: placement.projectKey,
                    row: placement.row,
                    column: placement.column,
                    status: previous.sessions[placement.sessionID]?.status ?? .idle
                )
            }
            let current = GridState(projectRows: projectRows, sessions: sessions)
            if previous != current {
                try write(current)
            }
            return GridReconciliation(previous: previous, current: current)
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
