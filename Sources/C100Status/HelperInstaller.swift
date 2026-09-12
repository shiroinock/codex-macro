import Darwin
import Foundation

enum HelperInstaller {
    static let label = "com.kotainaba.c100-status.grabber"
    static let appBundlePath = "/Applications/C100 Status Grabber.app"
    static let executablePath = "\(appBundlePath)/Contents/MacOS/c100-status-grabber"
    static let infoPlistPath = "\(appBundlePath)/Contents/Info.plist"
    static let legacyExecutablePath = "/Library/PrivilegedHelperTools/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let logPath = "/var/log/\(label).log"

    static func uninstall() throws {
        guard geteuid() == 0 else {
            throw CLIError.runtime("uninstall-helper must be run with sudo")
        }
        _ = try? launchctl(["bootout", "system/\(label)"])
        for path in [plistPath, appBundlePath, legacyExecutablePath, logPath] {
            if FileManager.default.fileExists(atPath: path) || isSymbolicLink(path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func currentExecutableURL() -> URL {
        let value = CommandLine.arguments[0]
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func launchctl(_ arguments: [String]) throws -> String {
        try run("/bin/launchctl", arguments)
    }

    private static func run(_ executablePath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        defer {
            // The read end is ours and Foundation never closes it; leaving
            // it open leaks a PIPE fd per invocation (see HerdrProcessRunner
            // for the same fix applied to the daemon's hot path).
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw CLIError.runtime("\(executablePath) \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text
    }
}
