import Foundation

struct HSVColor: Codable, Equatable {
    let hue: UInt8
    let saturation: UInt8
    let value: UInt8
}

enum KeychronProtocol {
    static let reportLength = 32
    static let keychronRGB: UInt8 = 0xA8
    static let backlightConfigurationSetValue: UInt8 = 7
    static let backlightGroup: UInt8 = 3
    static let backlightEffectValue: UInt8 = 2
    static let perKeyEffect: UInt8 = 23
    static let mixedEffect: UInt8 = 24
    static let maximumColorsPerReport = 9
    static let dynamicKeymapGetBuffer: UInt8 = 18
    static let getCurrentLayer: UInt8 = 0xA3
    static let getProtocolVersion: UInt8 = 1
    static let getKeyboardValue: UInt8 = 2
    static let getKeyboardMatrixValue: UInt8 = 3
    static let keyCount = 100
    static let keycodesPerBufferReport = 14

    enum RGBCommand: UInt8 {
        case version = 1
        case save = 2
        case ledCount = 5
        case getEffect = 7
        case setEffect = 8
        case getLEDColor = 9
        case setLEDColor = 10
        case setRegions = 13
        case setEffectList = 15
    }

    static func report(command: RGBCommand, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= reportLength - 2)
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = keychronRGB
        bytes[1] = command.rawValue
        bytes.replaceSubrange(2..<(2 + payload.count), with: payload)
        return bytes
    }

    static func setEffectReport(_ effect: UInt8 = perKeyEffect) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = backlightConfigurationSetValue
        bytes[1] = backlightGroup
        bytes[2] = backlightEffectValue
        bytes[3] = effect
        return bytes
    }

    static func ledCountReport() -> [UInt8] {
        report(command: .ledCount)
    }

    static func currentLayerReport() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = getCurrentLayer
        bytes[2] = 0xFF
        return bytes
    }

    static func protocolVersionReport() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = getProtocolVersion
        return bytes
    }

    static func keyboardMatrixReport() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = getKeyboardValue
        bytes[1] = getKeyboardMatrixValue
        return bytes
    }

    static func keymapBufferReport(offset: Int, keyCount: Int) -> [UInt8] {
        precondition(offset >= 0 && offset <= 0xFFFF)
        precondition(keyCount > 0 && keyCount <= keycodesPerBufferReport)
        var bytes = [UInt8](repeating: 0, count: reportLength)
        bytes[0] = dynamicKeymapGetBuffer
        bytes[1] = UInt8((offset >> 8) & 0xFF)
        bytes[2] = UInt8(offset & 0xFF)
        bytes[3] = UInt8(keyCount * 2)
        return bytes
    }

    static func setColorReport(index: Int, color: HSVColor) -> [UInt8] {
        precondition(index >= 0 && index <= 255)
        return report(
            command: .setLEDColor,
            payload: [UInt8(index), 1, color.hue, color.saturation, color.value]
        )
    }

    static func setColorReports(ledCount: Int, color: HSVColor) -> [[UInt8]] {
        precondition(ledCount >= 0 && ledCount <= 255)
        return setColorReports(colors: [HSVColor](repeating: color, count: ledCount))
    }

    static func setColorReports(colors: [HSVColor]) -> [[UInt8]] {
        precondition(colors.count <= 255)
        var reports: [[UInt8]] = []
        var start = 0
        while start < colors.count {
            let count = min(maximumColorsPerReport, colors.count - start)
            var payload = [UInt8(start), UInt8(count)]
            for color in colors[start..<(start + count)] {
                payload.append(contentsOf: [color.hue, color.saturation, color.value])
            }
            reports.append(report(command: .setLEDColor, payload: payload))
            start += count
        }
        return reports
    }

    static func setRegionsReports(assignedIndexes: Set<Int>, ledCount: Int) -> [[UInt8]] {
        precondition(ledCount >= 0 && ledCount <= 255)
        let maximumRegionsPerReport = reportLength - 4
        var reports: [[UInt8]] = []
        var start = 0
        while start < ledCount {
            let count = min(maximumRegionsPerReport, ledCount - start)
            // MIXED_RGB returns only the final region's render-continuation
            // value. It renders region 1 first and region 0 last, so assigned
            // keys must be region 0; otherwise rendering stops after the first
            // RGB_MATRIX_LED_PROCESS_LIMIT chunk (20 LEDs on this board).
            let regions = (start..<(start + count)).map { assignedIndexes.contains($0) ? UInt8(0) : UInt8(1) }
            reports.append(report(command: .setRegions, payload: [UInt8(start), UInt8(count)] + regions))
            start += count
        }
        return reports
    }

    static func mixedEffectListReports() -> [[UInt8]] {
        let empty = [UInt8](repeating: 0, count: 8)
        let assigned = [perKeyEffect, 0, 0, 0, 0, 0, 0, 0]

        func effectListReport(region: UInt8, start: UInt8, effects: [[UInt8]]) -> [UInt8] {
            report(
                command: .setEffectList,
                payload: [region, start, UInt8(effects.count)] + effects.flatMap { $0 }
            )
        }

        return [
            effectListReport(region: 0, start: 0, effects: [assigned, empty, empty]),
            effectListReport(region: 0, start: 3, effects: [empty, empty]),
            effectListReport(region: 1, start: 0, effects: [empty, empty, empty]),
            effectListReport(region: 1, start: 3, effects: [empty, empty]),
        ]
    }

    static func isResponse(_ bytes: [UInt8], to command: RGBCommand) -> Bool {
        bytes.count >= 2 && bytes[0] == keychronRGB && bytes[1] == command.rawValue
    }
}
