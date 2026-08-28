import Darwin
import Foundation
import IOKit.hid

private let inputReportCallback: IOHIDReportCallback = {
    context, result, _, _, _, report, reportLength in
    guard result == kIOReturnSuccess, let context else { return }
    let connection = Unmanaged<C100Connection>.fromOpaque(context).takeUnretainedValue()
    connection.receive(Array(UnsafeBufferPointer(start: report, count: reportLength)))
}

struct C100Descriptor {
    let product: String
    let vendorID: Int
    let productID: Int
    let locationID: Int
    let registryEntryID: UInt64
}

final class C100Connection {
    static let vendorID = 0x3434
    static let productID = 0x042C
    static let usagePage = 0xFF60
    static let usage = 0x61

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private var responses: [[UInt8]] = []
    private var isOpen = false
    private var reportObserver: (([UInt8]) -> Void)?

    var locationID: Int {
        Self.propertyInt(device, key: kIOHIDLocationIDKey)
    }

    private init(manager: IOHIDManager, device: IOHIDDevice) {
        self.manager = manager
        self.device = device
        inputBuffer = .allocate(capacity: 64)
        inputBuffer.initialize(repeating: 0, count: 64)
    }

    deinit {
        if isOpen {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deinitialize(count: 64)
        inputBuffer.deallocate()
    }

    static func descriptors() throws -> [C100Descriptor] {
        let (manager, devices) = try matchingDevices()
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        return devices.map(descriptor).sorted { $0.locationID < $1.locationID }
    }

    static func connect(locationID: Int? = nil) throws -> C100Connection {
        let (manager, devices) = try matchingDevices()
        let candidates = locationID.map { wanted in
            devices.filter { propertyInt($0, key: kIOHIDLocationIDKey) == wanted }
        } ?? devices
        guard let device = candidates.first else {
            throw CLIError.runtime("Keychron C100 8K vendor HID was not found")
        }
        if candidates.count > 1 && locationID == nil {
            throw CLIError.runtime("Multiple C100 devices found; pass --location with a value from `list`")
        }
        let connection = C100Connection(manager: manager, device: device)
        try connection.open()
        return connection
    }

    func apply(status: AgentStatus) throws {
        try apply(color: status.color)
    }

    func apply(color: HSVColor) throws {
        if color == LEDColorName.off.color {
            try turnOff()
            return
        }
        let ledCount = try preparePerKeyMode()
        for report in KeychronProtocol.setColorReports(ledCount: ledCount, color: color) {
            try transact(report, expecting: .setLEDColor)
        }
    }

    func apply(color: HSVColor, at index: Int) throws {
        let ledCount = try ledCount()
        guard index >= 0 && index < ledCount else {
            throw CLIError.runtime("Key index \(index) is outside the device LED range 0...\(ledCount - 1)")
        }
        try transact(KeychronProtocol.setColorReport(index: index, color: color), expecting: .setLEDColor)
    }

    func apply(colorsByIndex: [Int: HSVColor], defaultColor: HSVColor) throws {
        // Keychron's PER_KEY_RGB solid renderer deliberately overwrites each
        // stored HSV value with the global brightness, so V=0 cannot turn an
        // individual LED off. MIXED_RGB solves that without firmware changes:
        // region 0 renders assigned keys with PER_KEY_RGB; region 1 has no
        // effect and remains black after the temporary global-off transition.
        try turnOff()
        let ledCount = try ledCount()
        var colors = [HSVColor](repeating: defaultColor, count: ledCount)
        for (index, color) in colorsByIndex {
            guard index >= 0 && index < ledCount else {
                throw CLIError.runtime("Key index \(index) is outside the device LED range 0...\(ledCount - 1)")
            }
            colors[index] = color
        }
        for report in KeychronProtocol.setColorReports(colors: colors) {
            try transact(report, expecting: .setLEDColor)
        }
        let assignedIndexes = Set(colorsByIndex.keys)
        for report in KeychronProtocol.setRegionsReports(
            assignedIndexes: assignedIndexes,
            ledCount: ledCount
        ) {
            try transact(report, expecting: .setRegions)
        }
        for report in KeychronProtocol.mixedEffectListReports() {
            try transact(report, expecting: .setEffectList)
        }
        try send(KeychronProtocol.setEffectReport(KeychronProtocol.mixedEffect))
    }

    func currentLayer() throws -> Int {
        let response = try transact(
            KeychronProtocol.currentLayerReport(),
            matching: { $0.count >= 3 && $0[0] == KeychronProtocol.getCurrentLayer }
        )
        // Byte 1 is the default layer. Newer Keychron firmware may additionally
        // expose the currently active layer in byte 2.
        return response[2] == 0xFF ? Int(response[1]) : Int(response[2])
    }

    func protocolVersion() throws -> Int {
        let response = try transact(
            KeychronProtocol.protocolVersionReport(),
            matching: { $0.count >= 3 && $0[0] == KeychronProtocol.getProtocolVersion }
        )
        return Int(response[2])
    }

    func keyboardMatrixReport() throws -> [UInt8] {
        try transact(
            KeychronProtocol.keyboardMatrixReport(),
            matching: {
                $0.count >= 2
                    && $0[0] == KeychronProtocol.getKeyboardValue
                    && $0[1] == KeychronProtocol.getKeyboardMatrixValue
            }
        )
    }

    func pressedKeyIndexes(protocolVersion: Int) throws -> Set<Int> {
        let report = try keyboardMatrixReport()
        let payloadStart = protocolVersion >= 12 ? 3 : 2
        let rows = 10
        let columns = 10
        let bytesPerRow = (columns + 7) / 8
        guard report.count >= payloadStart + rows * bytesPerRow else {
            throw CLIError.runtime("C100 returned a short keyboard-matrix response")
        }

        var pressed: Set<Int> = []
        for row in 0..<rows {
            let rowStart = payloadStart + row * bytesPerRow
            for column in 0..<columns {
                // Keychron Launcher reverses both the row bytes and the bits in
                // each byte before assigning visual columns.
                let sourceByte = bytesPerRow - 1 - column / 8
                let bit = column % 8
                if report[rowStart + sourceByte] & UInt8(1 << bit) != 0 {
                    pressed.insert(row * columns + column)
                }
            }
        }
        return pressed
    }

    func keymap(layer: Int, keyCount: Int = KeychronProtocol.keyCount) throws -> [UInt16] {
        guard layer >= 0 && layer <= 255 else {
            throw CLIError.runtime("Invalid C100 keymap layer: \(layer)")
        }
        var keycodes: [UInt16] = []
        var keyOffset = 0
        let layerByteOffset = layer * keyCount * 2

        while keyOffset < keyCount {
            let count = min(KeychronProtocol.keycodesPerBufferReport, keyCount - keyOffset)
            let byteOffset = layerByteOffset + keyOffset * 2
            let report = KeychronProtocol.keymapBufferReport(offset: byteOffset, keyCount: count)
            let response = try transact(
                report,
                matching: {
                    $0.count >= 4
                        && $0[0] == KeychronProtocol.dynamicKeymapGetBuffer
                        && $0[1] == UInt8((byteOffset >> 8) & 0xFF)
                        && $0[2] == UInt8(byteOffset & 0xFF)
                }
            )
            guard response.count >= 4 + count * 2 else {
                throw CLIError.runtime("C100 returned a short keymap response at offset \(byteOffset)")
            }
            for index in 0..<count {
                let high = UInt16(response[4 + index * 2])
                let low = UInt16(response[5 + index * 2])
                keycodes.append((high << 8) | low)
            }
            keyOffset += count
        }
        return keycodes
    }

    func receive(_ report: [UInt8]) {
        responses.append(report)
        reportObserver?(report)
    }

    func watchReports(seconds: TimeInterval) {
        reportObserver = { report in
            let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("vendor-input \(hex)")
        }
        defer { reportObserver = nil }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
    }

    func watchMatrix(seconds: TimeInterval) throws {
        let version = try protocolVersion()
        print("protocol-version \(version)")
        var previous: [UInt8] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let report = try keyboardMatrixReport()
            if report != previous {
                let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("matrix \(hex)")
                previous = report
            }
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
    }

    private func open() throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw CLIError.runtime("Could not open C100 HID (IOReturn \(result)). Close Keychron Launcher and try again")
        }
        isOpen = true
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            64,
            inputReportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func preparePerKeyMode() throws -> Int {
        try send(KeychronProtocol.setEffectReport())
        return try ledCount()
    }

    private func ledCount() throws -> Int {
        let countResponse = try transact(KeychronProtocol.ledCountReport(), expecting: .ledCount)
        guard countResponse.count > 3 else {
            throw CLIError.runtime("C100 returned an invalid LED-count response")
        }
        let ledCount = Int(countResponse[3])
        guard ledCount > 0 else {
            throw CLIError.runtime("C100 reported zero addressable LEDs")
        }
        return ledCount
    }

    private func turnOff() throws {
        try send(KeychronProtocol.setEffectReport(0))
        // Give the keyboard's RGB task time to render and flush its all-black
        // frame before MIXED_RGB starts drawing only the assigned region.
        Darwin.usleep(50_000)
    }

    @discardableResult
    private func transact(
        _ report: [UInt8],
        expecting command: KeychronProtocol.RGBCommand,
        timeout: TimeInterval = 1.0
    ) throws -> [UInt8] {
        responses.removeAll(keepingCapacity: true)
        try send(report)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = responses.firstIndex(where: { KeychronProtocol.isResponse($0, to: command) }) {
                return responses.remove(at: index)
            }
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        throw CLIError.runtime("Timed out waiting for C100 response to command \(command.rawValue)")
    }

    @discardableResult
    private func transact(
        _ report: [UInt8],
        matching predicate: ([UInt8]) -> Bool,
        timeout: TimeInterval = 1.0
    ) throws -> [UInt8] {
        responses.removeAll(keepingCapacity: true)
        try send(report)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = responses.firstIndex(where: predicate) {
                return responses.remove(at: index)
            }
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        throw CLIError.runtime("Timed out waiting for C100 response to report \(report[0])")
    }

    private func send(_ report: [UInt8]) throws {
        var mutableReport = report
        let reportLength = mutableReport.count
        let result = mutableReport.withUnsafeMutableBytes { pointer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                0,
                pointer.bindMemory(to: UInt8.self).baseAddress!,
                reportLength
            )
        }
        guard result == kIOReturnSuccess else {
            throw CLIError.runtime("C100 HID write failed (IOReturn \(result))")
        }
    }

    private static func matchingDevices() throws -> (IOHIDManager, [IOHIDDevice]) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
            kIOHIDPrimaryUsagePageKey as String: usagePage,
            kIOHIDPrimaryUsageKey as String: usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw CLIError.runtime("Could not open IOHIDManager (IOReturn \(result))")
        }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []
        return (manager, devices)
    }

    private static func descriptor(_ device: IOHIDDevice) -> C100Descriptor {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Keychron C100 8K"
        var registryEntryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryEntryID)
        return C100Descriptor(
            product: product,
            vendorID: propertyInt(device, key: kIOHIDVendorIDKey),
            productID: propertyInt(device, key: kIOHIDProductIDKey),
            locationID: propertyInt(device, key: kIOHIDLocationIDKey),
            registryEntryID: registryEntryID
        )
    }

    private static func propertyInt(_ device: IOHIDDevice, key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }
}
