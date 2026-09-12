import Foundation

/// Private, versioned protocol; never sent unless --companion is explicit.
enum CompanionProtocol {
    static let magic: [UInt8] = [0xC9, 0x43, 0x31, 0x30]
    static let hello: UInt8 = 1
    static let heartbeat: UInt8 = 2
    static let colors: UInt8 = 3
    static let commit: UInt8 = 4
    static let release: UInt8 = 5
    static let shortcut: UInt8 = 6
    static let tap: UInt8 = 7
    static let cancelOutput: UInt8 = 8
    static let state: UInt8 = 0x40

    static func report(_ command: UInt8, sequence: UInt8, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= 24)
        return magic + [1, command, sequence, 0] + payload + Array(repeating: 0, count: 24 - payload.count)
    }

    static func isPacket(_ bytes: [UInt8]) -> Bool {
        bytes.count == 32 && Array(bytes.prefix(4)) == magic && bytes[4] == 1
    }

    static func pressedKeys(_ payload: ArraySlice<UInt8>) throws -> Set<Int> {
        let bytes = Array(payload)
        guard bytes.count >= 13, bytes[12] & 0xF0 == 0 else {
            throw CLIError.runtime("Invalid companion key bitmap")
        }
        return Set((0..<100).filter { bytes[$0 / 8] & (1 << ($0 % 8)) != 0 })
    }

    static func colorPayloads(_ colors: [HSVColor]) -> [[UInt8]] {
        precondition(colors.count == 100)
        return stride(from: 0, to: 100, by: 7).map { start in
            let count = min(7, 100 - start)
            return [UInt8(start), UInt8(count)] + colors[start..<(start + count)].flatMap { [$0.hue, $0.saturation, $0.value] }
        }
    }

    static func selfTest() throws {
        let packet = report(hello, sequence: 255)
        let frame = [HSVColor](repeating: HSVColor(hue: 17, saturation: 29, value: 0), count: 100)
        let chunks = colorPayloads(frame)
        var bitmap = [UInt8](repeating: 0, count: 13)
        bitmap[0] = 1; bitmap[12] = 8
        guard isPacket(packet), !isPacket(Array(packet.dropLast())),
              !isPacket([0] + packet.dropFirst()),
              try pressedKeys(bitmap[...]) == [0, 99], chunks.count == 15,
              chunks.last == [98, 2, 17, 29, 0, 17, 29, 0],
              chunks.allSatisfy({ $0.count <= 24 }) else {
            throw CLIError.runtime("Companion protocol self-test failed")
        }
        let xml = AgentInstaller.plist(label: "test", binaryPath: "/tmp/c100-status", locationID: 42, companion: true)
        let plist = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
        guard plist?["ProgramArguments"] as? [String] == ["/tmp/c100-status", "run", "--companion", "--location", "0x2a"] else {
            throw CLIError.runtime("Companion LaunchAgent self-test failed")
        }
        bitmap[12] = 0x80
        do {
            _ = try pressedKeys(bitmap[...])
        } catch { return }
        throw CLIError.runtime("Companion accepted an invalid bitmap")
    }
}


struct USBShortcut: Equatable {
    let modifiers: UInt8
    let usage: UInt8
    init?(_ shortcut: CodexKeyboardShortcut) {
        // macOS virtual key codes -> USB HID Keyboard/Keypad usage IDs.
        let usages: [UInt16: UInt8] = [
            0:4, 11:5, 8:6, 2:7, 14:8, 3:9, 5:10, 4:11, 34:12,
            38:13, 40:14, 37:15, 46:16, 45:17, 31:18, 35:19, 12:20,
            15:21, 1:22, 17:23, 32:24, 9:25, 13:26, 7:27, 16:28, 6:29,
            18:30, 19:31, 20:32, 21:33, 23:34, 22:35, 26:36, 28:37, 25:38, 29:39,
            36:40, 53:41, 51:42, 48:43, 49:44, 27:45, 24:46, 33:47, 30:48,
            42:49, 41:51, 39:52, 50:53, 43:54, 47:55, 44:56,
            122:58, 120:59, 99:60, 118:61, 96:62, 97:63, 98:64, 100:65,
            101:66, 109:67, 103:68, 111:69, 124:79, 123:80, 125:81, 126:82,
            105:104, 107:105, 113:106, 106:107, 64:108, 79:109, 80:110, 90:111
        ]
        guard let usage = usages[shortcut.keyCode] else { return nil }
        self.usage = usage
        var modifiers: UInt8 = 0
        if shortcut.flags.contains(.maskControl) { modifiers |= 1 }
        if shortcut.flags.contains(.maskShift) { modifiers |= 2 }
        if shortcut.flags.contains(.maskAlternate) { modifiers |= 4 }
        if shortcut.flags.contains(.maskCommand) { modifiers |= 8 }
        self.modifiers = modifiers
    }
}
