import Darwin
import Foundation

final class StatusLogger {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private let formatter = ISO8601DateFormatter()
    private let fileHandle: FileHandle
    let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let descriptor = Darwin.open(
            fileURL.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CLIError.runtime("Could not securely open log file at \(fileURL.path): \(String(cString: strerror(errno)))")
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw CLIError.runtime("Refusing unsafe log file at \(fileURL.path): \(reason)")
        }
        fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? fileHandle.close()
    }

    func log(_ level: Level, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level.rawValue) \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardOutput.write(data)
        do {
            try fileHandle.write(contentsOf: data)
            try fileHandle.synchronize()
        } catch {
            FileHandle.standardError.write(Data("c100-status: log write failed: \(error)\n".utf8))
        }
    }
}
