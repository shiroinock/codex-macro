import Darwin
import Foundation

enum RuntimePaths {
    static var ownerUID: uid_t {
        guard geteuid() == 0,
              let value = ProcessInfo.processInfo.environment["SUDO_UID"],
              let parsed = UInt32(value) else { return getuid() }
        return uid_t(parsed)
    }

    static var ownerGID: gid_t {
        guard geteuid() == 0,
              let value = ProcessInfo.processInfo.environment["SUDO_GID"],
              let parsed = UInt32(value) else { return getgid() }
        return gid_t(parsed)
    }

    static func socket(uid: uid_t = ownerUID) -> String {
        "/tmp/keychron-c100-status-\(uid).sock"
    }

    static func log(uid: uid_t = ownerUID) -> String {
        "/tmp/keychron-c100-status-\(uid).log"
    }

    static func grabberSocket(uid: uid_t = ownerUID) -> String {
        "/var/run/keychron-c100-grabber-\(uid).sock"
    }
}

struct DaemonRequest: Codable {
    enum Kind: String, Codable {
        case hook
        case manual
        case key
        case clear
        case ping
    }

    let kind: Kind
    let hook: HookInput?
    let status: AgentStatus?
    let keyIndex: Int?
    let color: HSVColor?

    static func hook(_ input: HookInput) -> Self {
        Self(kind: .hook, hook: input, status: nil, keyIndex: nil, color: nil)
    }

    static func manual(_ status: AgentStatus) -> Self {
        Self(kind: .manual, hook: nil, status: status, keyIndex: nil, color: nil)
    }

    static func key(index: Int, color: HSVColor) -> Self {
        Self(kind: .key, hook: nil, status: nil, keyIndex: index, color: color)
    }

    static let clear = Self(kind: .clear, hook: nil, status: nil, keyIndex: nil, color: nil)
    static let ping = Self(kind: .ping, hook: nil, status: nil, keyIndex: nil, color: nil)
}

struct DaemonResponse: Codable {
    let ok: Bool
    let message: String
    let status: AgentStatus?
}

final class DaemonInstanceLock {
    private let descriptor: Int32

    init(socketPath: String) throws {
        let path = "\(socketPath).lock"
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CLIError.runtime("Could not open daemon lock: \(String(cString: strerror(errno)))")
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            throw CLIError.runtime("Refusing unsafe daemon lock at \(path)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw CLIError.runtime("Another c100-status daemon is already using \(socketPath)")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

final class UnixSocketServer {
    private let descriptor: Int32
    let path: String

    init(path: String, ownerUID: uid_t? = nil, ownerGID: gid_t? = nil) throws {
        self.path = path
        guard path.utf8.count < 100 else {
            throw CLIError.runtime("Unix socket path is too long: \(path)")
        }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CLIError.runtime("Could not create Unix socket: \(Self.lastError())")
        }
        Self.disableSigPipe(descriptor)
        Darwin.unlink(path)
        let bindResult = Self.withAddress(path) { address, length in
            Darwin.bind(descriptor, address, length)
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw CLIError.runtime("Could not bind Unix socket at \(path): \(Self.lastError())")
        }
        guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            Darwin.unlink(path)
            throw CLIError.runtime("Could not secure Unix socket at \(path): \(Self.lastError())")
        }
        if let ownerUID {
            guard Darwin.chown(path, ownerUID, ownerGID ?? gid_t.max) == 0 else {
                Darwin.close(descriptor)
                Darwin.unlink(path)
                throw CLIError.runtime("Could not set Unix socket owner at \(path): \(Self.lastError())")
            }
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            Darwin.unlink(path)
            throw CLIError.runtime("Could not listen on Unix socket: \(Self.lastError())")
        }
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.unlink(path)
    }

    func accept(timeoutMilliseconds: Int32 = 250) throws -> Int32? {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        if pollResult == 0 { return nil }
        if pollResult < 0 {
            if errno == EINTR { return nil }
            throw CLIError.runtime("Unix socket poll failed: \(Self.lastError())")
        }
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else {
            if errno == EINTR { return nil }
            throw CLIError.runtime("Unix socket accept failed: \(Self.lastError())")
        }
        Self.disableSigPipe(client)
        return client
    }

    static func readRequest(
        from descriptor: Int32,
        maximumBytes: Int = 65_536,
        timeoutMilliseconds: Int32 = 500
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            if pollResult == 0 {
                throw CLIError.runtime("Unix socket request timed out after \(timeoutMilliseconds) ms")
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CLIError.runtime("Unix socket read poll failed: \(lastError())")
            }

            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CLIError.runtime("Unix socket read failed: \(lastError())")
            }
            result.append(buffer, count: count)
            guard result.count <= maximumBytes else {
                throw CLIError.runtime("Unix socket request exceeded \(maximumBytes) bytes")
            }
            if let newline = result.firstIndex(of: 0x0A) {
                return Data(result[..<newline])
            }
        }
        return result
    }

    static func write<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            guard var base = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, base, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CLIError.runtime("Unix socket write failed: \(lastError())")
                }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
    }

    static func send<T: Encodable, R: Decodable>(_ value: T, path: String, response: R.Type) throws -> R {
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else {
            throw CLIError.runtime("Could not create Unix socket client: \(lastError())")
        }
        defer { Darwin.close(client) }
        disableSigPipe(client)
        let connectResult = withAddress(path) { address, length in
            Darwin.connect(client, address, length)
        }
        guard connectResult == 0 else {
            throw CLIError.runtime("Could not connect to daemon at \(path): \(lastError())")
        }
        try write(value, to: client)
        Darwin.shutdown(client, SHUT_WR)
        let data = try readRequest(from: client)
        return try JSONDecoder().decode(R.self, from: data)
    }

    private static func withAddress<T>(_ path: String, body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, length)
            }
        }
    }

    private static func disableSigPipe(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}
