import Foundation

/// Private, versioned protocol; never sent unless --companion is explicit.
enum CompanionProtocol {
    static let magic: [UInt8] = [0xC9, 0x43, 0x31, 0x30]
    static let hello: UInt8 = 1
    static let heartbeat: UInt8 = 2
    static let colors: UInt8 = 3
    static let commit: UInt8 = 4
    static let release: UInt8 = 5
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
