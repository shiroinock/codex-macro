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

    static func install(
        sourceExecutable: URL,
        ownerUID: uid_t,
        ownerGID: gid_t,
        locationID: Int
    ) throws {
        guard geteuid() == 0 else {
            throw CLIError.runtime("install-helper must be run once with sudo")
        }
        guard ownerUID != 0 else {
            throw CLIError.runtime("Could not identify the non-root user who should own the grabber lease socket")
        }
        guard FileManager.default.isExecutableFile(atPath: sourceExecutable.path) else {
            throw CLIError.runtime("Current c100-status executable is not readable/executable at \(sourceExecutable.path)")
        }

        let temporaryBundlePath = try makePrivateTemporaryBundleDirectory()
        var removeTemporaryBundle = true
        defer {
            if removeTemporaryBundle {
                try? FileManager.default.removeItem(atPath: temporaryBundlePath)
            }
        }
        try prepareBundle(at: temporaryBundlePath, sourceExecutable: sourceExecutable)
        _ = try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", temporaryBundlePath])
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", temporaryBundlePath])

        let socketPath = RuntimePaths.grabberSocket(uid: ownerUID)
        let plistData = Data(plist(ownerUID: ownerUID, ownerGID: ownerGID, locationID: locationID, socketPath: socketPath).utf8)
        let plistTemporaryPath = try writeRootOwnedTemporaryFile(
            contents: plistData,
            nextTo: plistPath,
            mode: S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        var removeTemporaryPlist = true
        defer {
            if removeTemporaryPlist {
                Darwin.unlink(plistTemporaryPath)
            }
        }

        _ = try? launchctl(["bootout", "system/\(label)"])
        try replaceBundleAtomically(with: temporaryBundlePath)
        removeTemporaryBundle = false
        guard Darwin.rename(plistTemporaryPath, plistPath) == 0 else {
            throw CLIError.runtime("Could not install LaunchDaemon plist: \(String(cString: strerror(errno)))")
        }
        removeTemporaryPlist = false
        _ = try launchctl(["bootstrap", "system", plistPath])
        _ = try launchctl(["enable", "system/\(label)"])
        _ = try launchctl(["kickstart", "-k", "system/\(label)"])

        // The previous installer used a bare executable that macOS's Input
        // Monitoring picker could not select. It is no longer launched.
        try? FileManager.default.removeItem(atPath: legacyExecutablePath)
    }

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

    private static func makePrivateTemporaryBundleDirectory() throws -> String {
        var template = Array("/Applications/.c100-status-grabber-install.XXXXXX".utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
            guard let result = Darwin.mkdtemp(buffer.baseAddress) else { return nil }
            return String(cString: result)
        }) else {
            throw CLIError.runtime("Could not create private helper staging directory: \(String(cString: strerror(errno)))")
        }
        guard Darwin.chown(path, 0, 0) == 0,
              Darwin.chmod(path, S_IRWXU) == 0 else {
            try? FileManager.default.removeItem(atPath: path)
            throw CLIError.runtime("Could not secure helper staging directory: \(String(cString: strerror(errno)))")
        }
        return path
    }

    private static func prepareBundle(at bundlePath: String, sourceExecutable: URL) throws {
        let contentsPath = "\(bundlePath)/Contents"
        let macOSPath = "\(contentsPath)/MacOS"
        try FileManager.default.createDirectory(atPath: macOSPath, withIntermediateDirectories: true)
        for path in [contentsPath, macOSPath] {
            guard Darwin.chown(path, 0, 0) == 0,
                  Darwin.chmod(path, S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0 else {
                throw CLIError.runtime("Could not secure helper bundle directory: \(String(cString: strerror(errno)))")
            }
        }

        let stagedExecutable = "\(macOSPath)/c100-status-grabber"
        try copyRegularFileSecurely(from: sourceExecutable.path, to: stagedExecutable)

        let stagedInfoPlist = "\(contentsPath)/Info.plist"
        try Data(appInfoPlist().utf8).write(to: URL(fileURLWithPath: stagedInfoPlist), options: .withoutOverwriting)
        guard Darwin.chown(stagedInfoPlist, 0, 0) == 0,
              Darwin.chmod(stagedInfoPlist, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH) == 0,
              Darwin.chmod(bundlePath, S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0 else {
            throw CLIError.runtime("Could not secure helper bundle metadata: \(String(cString: strerror(errno)))")
        }
    }

    private static func copyRegularFileSecurely(from sourcePath: String, to destinationPath: String) throws {
        let sourceDescriptor = Darwin.open(sourcePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            throw CLIError.runtime("Could not securely open helper source: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(sourceDescriptor) }

        var metadata = stat()
        guard Darwin.fstat(sourceDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw CLIError.runtime("Helper source must be a regular file")
        }

        let destinationDescriptor = Darwin.open(
            destinationPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRWXU
        )
        guard destinationDescriptor >= 0 else {
            throw CLIError.runtime("Could not create staged helper executable: \(String(cString: strerror(errno)))")
        }
        let source = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false)
        let destination = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
        do {
            while let chunk = try source.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                try destination.write(contentsOf: chunk)
            }
            try destination.synchronize()
            guard Darwin.fchown(destinationDescriptor, 0, 0) == 0,
                  Darwin.fchmod(
                    destinationDescriptor,
                    S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH
                  ) == 0 else {
                throw CLIError.runtime("Could not secure staged helper executable: \(String(cString: strerror(errno)))")
            }
            try destination.close()
        } catch {
            try? destination.close()
            throw error
        }
    }

    private static func writeRootOwnedTemporaryFile(contents: Data, nextTo destinationPath: String, mode: mode_t) throws -> String {
        var template = Array("\(destinationPath).install.XXXXXX".utf8CString)
        var descriptor: Int32 = -1
        guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
            descriptor = Darwin.mkstemp(buffer.baseAddress)
            guard descriptor >= 0 else { return nil }
            return String(cString: buffer.baseAddress!)
        }) else {
            throw CLIError.runtime("Could not create LaunchDaemon staging file: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: contents)
            try handle.synchronize()
            guard Darwin.fchown(descriptor, 0, 0) == 0,
                  Darwin.fchmod(descriptor, mode) == 0 else {
                throw CLIError.runtime("Could not secure LaunchDaemon staging file: \(String(cString: strerror(errno)))")
            }
            try handle.close()
            return path
        } catch {
            try? handle.close()
            Darwin.unlink(path)
            throw error
        }
    }

    private static func replaceBundleAtomically(with stagedBundlePath: String) throws {
        let backupPath = "/Applications/.c100-status-grabber-old-\(UUID().uuidString)"
        var movedExistingBundle = false
        if FileManager.default.fileExists(atPath: appBundlePath) || isSymbolicLink(appBundlePath) {
            guard Darwin.rename(appBundlePath, backupPath) == 0 else {
                throw CLIError.runtime("Could not move the existing helper bundle aside: \(String(cString: strerror(errno)))")
            }
            movedExistingBundle = true
        }
        guard Darwin.rename(stagedBundlePath, appBundlePath) == 0 else {
            if movedExistingBundle {
                _ = Darwin.rename(backupPath, appBundlePath)
            }
            throw CLIError.runtime("Could not install the prepared helper bundle: \(String(cString: strerror(errno)))")
        }
        if movedExistingBundle {
            try FileManager.default.removeItem(atPath: backupPath)
        }
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var metadata = stat()
        return Darwin.lstat(path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }

    static func appInfoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleDevelopmentRegion</key>
          <string>en</string>
          <key>CFBundleDisplayName</key>
          <string>C100 Status Grabber</string>
          <key>CFBundleExecutable</key>
          <string>c100-status-grabber</string>
          <key>CFBundleIdentifier</key>
          <string>\(label)</string>
          <key>CFBundleInfoDictionaryVersion</key>
          <string>6.0</string>
          <key>CFBundleName</key>
          <string>C100 Status Grabber</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleShortVersionString</key>
          <string>0.1.0</string>
          <key>CFBundleVersion</key>
          <string>1</string>
          <key>LSBackgroundOnly</key>
          <true/>
          <key>NSInputMonitoringUsageDescription</key>
          <string>Suppress input from the selected Keychron C100 while the user daemon maps its physical keys to Codex tasks.</string>
        </dict>
        </plist>
        """
    }

    static func plist(ownerUID: uid_t, ownerGID: gid_t, locationID: Int, socketPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(executablePath)</string>
            <string>grabber-service</string>
            <string>--location</string>
            <string>\(locationID)</string>
            <string>--owner-uid</string>
            <string>\(ownerUID)</string>
            <string>--owner-gid</string>
            <string>\(ownerGID)</string>
            <string>--grabber-socket</string>
            <string>\(socketPath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>ThrottleInterval</key>
          <integer>5</integer>
          <key>StandardOutPath</key>
          <string>\(logPath)</string>
          <key>StandardErrorPath</key>
          <string>\(logPath)</string>
        </dict>
        </plist>
        """
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
