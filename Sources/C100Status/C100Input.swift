import Foundation
import IOKit.hid

private let keyboardValueCallback: IOHIDValueCallback = { context, result, _, value in
    guard result == kIOReturnSuccess, let context else { return }
    let capture = Unmanaged<C100InputCapture>.fromOpaque(context).takeUnretainedValue()
    capture.receive(value)
}

enum PhysicalKeyResolution: Equatable {
    case key(Int)
    case ambiguous([Int])
    case unmapped
}

struct PhysicalKeyMap {
    private let indexesByUsage: [UInt32: [Int]]

    init(qmkKeycodes: [UInt16]) {
        var result: [UInt32: [Int]] = [:]
        for (index, keycode) in qmkKeycodes.enumerated() {
            guard let usage = Self.keyboardUsage(for: keycode) else { continue }
            result[usage, default: []].append(index)
        }
        indexesByUsage = result
    }

    var mappedKeyCount: Int {
        indexesByUsage.values.reduce(0) { $0 + $1.count }
    }

    var ambiguousUsages: [(usage: UInt32, indexes: [Int])] {
        indexesByUsage
            .filter { $0.value.count > 1 }
            .map { (usage: $0.key, indexes: $0.value) }
            .sorted { $0.usage < $1.usage }
    }

    func resolve(usage: UInt32) -> PhysicalKeyResolution {
        guard let indexes = indexesByUsage[usage] else { return .unmapped }
        return indexes.count == 1 ? .key(indexes[0]) : .ambiguous(indexes)
    }

    private static func keyboardUsage(for qmkKeycode: UInt16) -> UInt32? {
        let value = Int(qmkKeycode)
        let basic: Int
        switch value {
        case 0x04...0xE7:
            basic = value
        case 0x0100...0x1FFF, 0x4000...0x4FFF, 0x6000...0x7FFF:
            // QMK modifier wrappers, layer-tap, and mod-tap retain the emitted
            // USB keyboard usage in their low byte.
            basic = value & 0xFF
        default:
            return nil
        }
        guard (0x04...0xE7).contains(basic) else { return nil }
        return UInt32(basic)
    }
}

final class C100InputCapture {
    private static let genericDesktopUsagePage = 0x01
    private static let keyboardUsage = 0x06
    private static let keyboardKeypadUsagePage: UInt32 = 0x07

    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let onPress: (UInt32) -> Void
    private var pressedUsages: Set<UInt32> = []
    private var isOpen = false

    static var accessDescription: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: "granted"
        case kIOHIDAccessTypeDenied: "denied"
        default: "unknown"
        }
    }

    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    private init(manager: IOHIDManager, device: IOHIDDevice, onPress: @escaping (UInt32) -> Void) {
        self.manager = manager
        self.device = device
        self.onPress = onPress
    }

    deinit {
        if isOpen {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }

    static func connect(
        locationID: Int? = nil,
        onPress: @escaping (UInt32) -> Void
    ) throws -> C100InputCapture {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var matching: [String: Any] = [
            kIOHIDVendorIDKey as String: C100Connection.vendorID,
            kIOHIDProductIDKey as String: C100Connection.productID,
            kIOHIDPrimaryUsagePageKey as String: genericDesktopUsagePage,
            kIOHIDPrimaryUsageKey as String: keyboardUsage,
        ]
        if let locationID {
            matching[kIOHIDLocationIDKey as String] = locationID
        }
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard managerResult == kIOReturnSuccess else {
            if managerResult == kIOReturnExclusiveAccess {
                throw CLIError.runtime(
                    "C100 keyboard input is already exclusively captured by another process. "
                        + "Karabiner currently lists this C100; exclude/disable this device there, then retry"
                )
            }
            if managerResult == kIOReturnNotPrivileged {
                throw CLIError.runtime(
                    "macOS requires the privileged C100 grabber to suppress a physical keyboard"
                )
            }
            if managerResult == kIOReturnNotPermitted {
                throw CLIError.runtime(
                    "macOS Input Monitoring permission is not granted to this process (IOReturn \(managerResult))"
                )
            }
            throw CLIError.runtime("Could not open C100 keyboard IOHIDManager (IOReturn \(managerResult))")
        }

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []
        let candidates = devices
        guard let device = candidates.first else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            throw CLIError.runtime("Keychron C100 8K keyboard HID was not found")
        }
        if candidates.count > 1 && locationID == nil {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            throw CLIError.runtime("Multiple C100 keyboard interfaces found; pass --location")
        }

        let capture = C100InputCapture(manager: manager, device: device, onPress: onPress)
        capture.open()
        return capture
    }

    func service() {
        CFRunLoopRunInMode(.defaultMode, 0.001, true)
    }

    fileprivate func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == Self.keyboardKeypadUsagePage else { return }
        let usage = IOHIDElementGetUsage(element)
        let isPressed = IOHIDValueGetIntegerValue(value) != 0
        if isPressed {
            guard pressedUsages.insert(usage).inserted else { return }
            onPress(usage)
        } else {
            pressedUsages.remove(usage)
        }
    }

    private func open() {
        isOpen = true
        IOHIDManagerRegisterInputValueCallback(
            manager,
            keyboardValueCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private static func propertyInt(_ device: IOHIDDevice, key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }
}
