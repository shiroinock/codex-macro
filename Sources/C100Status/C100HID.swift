import Darwin
import Foundation
import IOKit.hid

private let inputReportCallback: IOHIDReportCallback = {
    context, result, _, _, _, report, reportLength in
    guard result == kIOReturnSuccess, let context else { return }
    let connection = Unmanaged<C100Connection>.fromOpaque(context).takeUnretainedValue()
    connection.receive(Array(UnsafeBufferPointer(start: report, count: reportLength)))
}

/// Distinguishes the two ways `C100Connection.connect` can fail to hand
/// back a device, so callers can decide *how* to react without resorting
/// to string-matching `CLIError.runtime`'s message: `.notFound` means "the
/// keyboard may simply not be plugged in yet" (worth waiting and retrying,
/// e.g. `StatusDaemon.setupHardware`), while `.multipleDevices` is a
/// configuration problem (`--location` is required) that retrying can
/// never resolve on its own.
enum C100ConnectionError: Error, CustomStringConvertible {
    case notFound
    case multipleDevices

    var description: String {
        switch self {
        case .notFound:
            "Keychron C100 8K vendor HID was not found"
        case .multipleDevices:
            "Multiple C100 devices found; pass --location with a value from `list`"
        }
    }
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
    private var cachedLedCount: Int?
    private(set) var isCompanion = false
    private var companionSequence: UInt8 = 0
    private var companionLock: DaemonInstanceLock?
    private var companionStates: [Set<Int>] = []
    private var companionOverflow = false
    private var nextCompanionHeartbeat = Date.distantPast
    private var companionFrame = [HSVColor](repeating: LEDColorName.off.color, count: 100)

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

    static func connect(locationID: Int? = nil, companion: Bool = false) throws -> C100Connection {
        let (manager, devices) = try matchingDevices()
        let candidates = locationID.map { wanted in
            devices.filter { propertyInt($0, key: kIOHIDLocationIDKey) == wanted }
        } ?? devices
        guard let device = candidates.first else {
            throw C100ConnectionError.notFound
        }
        if candidates.count > 1 && locationID == nil {
            throw C100ConnectionError.multipleDevices
        }
        let connection = C100Connection(manager: manager, device: device)
        try connection.open()
        if companion { try connection.startCompanion() }
        return connection
    }

    func apply(status: AgentStatus) throws {
        try apply(color: status.color)
    }

    func apply(color: HSVColor) throws {
        if isCompanion {
            try paintCompanion([HSVColor](repeating: color, count: 100))
            return
        }
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
        if isCompanion {
            guard (0..<100).contains(index) else { throw CLIError.runtime("Invalid companion key index") }
            var frame = companionFrame
            frame[index] = color
            try paintCompanion(frame)
            return
        }
        let ledCount = try ledCount()
        guard index >= 0 && index < ledCount else {
            throw CLIError.runtime("Key index \(index) is outside the device LED range 0...\(ledCount - 1)")
        }
        try transact(KeychronProtocol.setColorReport(index: index, color: color), expecting: .setLEDColor)
    }

    func apply(colorsByIndex: [Int: HSVColor], defaultColor: HSVColor) throws {
        if isCompanion {
            var frame = [HSVColor](repeating: defaultColor, count: 100)
            for (index, color) in colorsByIndex {
                guard (0..<100).contains(index) else { throw CLIError.runtime("Invalid companion key index") }
                frame[index] = color
            }
            try paintCompanion(frame)
            return
        }
        // Keychron's PER_KEY_RGB solid renderer deliberately overwrites each
        // stored HSV value with the global brightness, so V=0 cannot turn an
        // individual LED off. MIXED_RGB solves that without firmware changes:
        // region 0 renders assigned keys with PER_KEY_RGB; region 1 has no
        // effect and remains black after the temporary global-off transition.
        //
        // This is the full-frame path: it always blacks out the board for
        // ~50ms via `turnOff()` and re-establishes MIXED_RGB from scratch, so
        // it visibly flickers. Only call it when the board's actual state is
        // unknown (first paint, reconnect, `.clear`) -- once MIXED_RGB is
        // already active, prefer `update(colorsByIndex:defaultColor:previousColorsByIndex:)`,
        // which only touches the LEDs that actually changed.
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

    /// Incremental repaint for when MIXED_RGB is already active on the board
    /// (i.e. a prior `apply(colorsByIndex:defaultColor:)` or `update` already
    /// ran since the last reconnect/clear). Unlike the full-frame path, this
    /// never calls `turnOff()`, resends `mixedEffectListReports()`, or resets
    /// the effect -- doing so would re-run the ~50ms blackout-then-redraw
    /// that causes the whole grid to visibly flicker on every session
    /// add/remove. Instead it diffs against `previousColorsByIndex` (the
    /// last frame this connection actually painted) and only:
    ///   1. sends `setColorReport` for LEDs whose resolved color changed, and
    ///   2. resends the region map only if the *set* of assigned indexes
    ///      changed, always after step 1 so a key moving from region 1
    ///      (black) to region 0 already holds its real color the instant it
    ///      becomes visible instead of flashing black first.
    /// Sends nothing at all if neither changed.
    func update(
        colorsByIndex: [Int: HSVColor],
        defaultColor: HSVColor,
        previousColorsByIndex: [Int: HSVColor]
    ) throws {
        if isCompanion {
            if colorsByIndex != previousColorsByIndex {
                try apply(colorsByIndex: colorsByIndex, defaultColor: defaultColor)
            }
            return
        }
        let ledCount = try ledCount()
        for index in colorsByIndex.keys {
            guard index >= 0 && index < ledCount else {
                throw CLIError.runtime("Key index \(index) is outside the device LED range 0...\(ledCount - 1)")
            }
        }
        let diff = FrameDiff.compute(
            previousColorsByIndex: previousColorsByIndex,
            colorsByIndex: colorsByIndex,
            defaultColor: defaultColor,
            ledCount: ledCount
        )
        guard !diff.isEmpty else { return }
        for (index, color) in diff.changedColors {
            try transact(KeychronProtocol.setColorReport(index: index, color: color), expecting: .setLEDColor)
        }
        if diff.regionsChanged {
            let assignedIndexes = Set(colorsByIndex.keys)
            for report in KeychronProtocol.setRegionsReports(
                assignedIndexes: assignedIndexes,
                ledCount: ledCount
            ) {
                try transact(report, expecting: .setRegions)
            }
        }
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
        let isState = CompanionProtocol.isPacket(report) && report[5] == CompanionProtocol.state
        let isSnapshot = CompanionProtocol.isPacket(report) && report[5] == (CompanionProtocol.heartbeat | 0x80)
            && report[6] == companionSequence && report[7] == 0
        if isCompanion && (isState || isSnapshot) {
            if let keys = try? CompanionProtocol.pressedKeys(report[8..<21]) {
                if companionStates.count < 256 { companionStates.append(keys) }
                else { companionOverflow = true }
            } else { companionOverflow = true }
        }
        if !isState {
            // Unsolicited stock reports must not grow memory without bound.
            if responses.count >= 256 { responses.removeFirst() }
            responses.append(report)
        }
        reportObserver?(report)
    }

    private func companionRequest(_ command: UInt8, payload: [UInt8] = []) throws -> [UInt8] {
        companionSequence &+= 1
        let sequence = companionSequence
        let response = try transact(CompanionProtocol.report(command, sequence: sequence, payload: payload), matching: {
            CompanionProtocol.isPacket($0) && $0[5] == (command | 0x80) && $0[6] == sequence
        }, timeout: 0.5)
        guard response[7] == 0 else {
            throw CLIError.runtime("Companion rejected command \(command), status=\(response[7])")
        }
        return response
    }

    func checkCompanion() throws {
        let reply = try companionRequest(CompanionProtocol.hello)
        guard Array(reply[8..<12]) == [10, 10, 7, 3] else {
            throw CLIError.runtime("Incompatible companion capabilities; expected 10x10, input suppression, events, HSV and 3s watchdog")
        }
    }

    private func startCompanion() throws {
        companionLock = try DaemonInstanceLock(socketPath: "/tmp/c100-companion-\(getuid())-\(locationID)")
        try checkCompanion()
        isCompanion = true
        // Seed held keys without navigating them at startup.
        let snapshot = try companionRequest(CompanionProtocol.heartbeat)
        companionStates = [try CompanionProtocol.pressedKeys(snapshot[8..<21])]
        nextCompanionHeartbeat = Date().addingTimeInterval(0.75)
    }

    func drainCompanionStates() throws -> [Set<Int>] {
        CFRunLoopRunInMode(.defaultMode, 0.001, false)
        if Date() >= nextCompanionHeartbeat {
            let reply = try companionRequest(CompanionProtocol.heartbeat)
            guard reply[21] == 1 else {
                throw CLIError.runtime("Companion watchdog expired; restart to restore the full display")
            }
            nextCompanionHeartbeat = Date().addingTimeInterval(0.75)
        }
        guard !companionOverflow else { throw CLIError.runtime("Companion input queue overflow or malformed state; restart required") }
        let result = companionStates
        companionStates.removeAll(keepingCapacity: true)
        return result
    }

    func verifyCompanionWatchdog() throws {
        Thread.sleep(forTimeInterval: 3.3)
        let reply = try companionRequest(CompanionProtocol.heartbeat)
        guard reply[21] == 0 else {
            throw CLIError.runtime("Companion watchdog did not expire after 3.3s without traffic")
        }
        nextCompanionHeartbeat = Date().addingTimeInterval(0.75)
    }

    func stopCompanion() {
        if isCompanion { _ = try? companionRequest(CompanionProtocol.release) }
    }

    private func paintCompanion(_ frame: [HSVColor]) throws {
        for payload in CompanionProtocol.colorPayloads(frame) {
            _ = try companionRequest(CompanionProtocol.colors, payload: payload)
        }
        _ = try companionRequest(CompanionProtocol.commit)
        companionFrame = frame
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
        // The device's addressable LED count can't change for the lifetime
        // of a connection, and diffed single-key writes (`apply(color:at:)`,
        // `update(colorsByIndex:...)`) call this far more often than the
        // full-frame path did, so cache it after the first round-trip.
        if let cachedLedCount { return cachedLedCount }
        let countResponse = try transact(KeychronProtocol.ledCountReport(), expecting: .ledCount)
        guard countResponse.count > 3 else {
            throw CLIError.runtime("C100 returned an invalid LED-count response")
        }
        let ledCount = Int(countResponse[3])
        guard ledCount > 0 else {
            throw CLIError.runtime("C100 reported zero addressable LEDs")
        }
        cachedLedCount = ledCount
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
