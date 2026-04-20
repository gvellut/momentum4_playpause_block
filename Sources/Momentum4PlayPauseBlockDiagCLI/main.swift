import AppKit
import Foundation
import IOKit.hid
import IOKit.hidsystem

private let kRCDServiceName = "com.apple.rcd"
private let kRCDPlistPath = "/System/Library/LaunchAgents/com.apple.rcd.plist"
private let kExclusiveAccessCode: UInt32 = 0xE00002C5

nonisolated(unsafe) private var globalDiagnosticCLI: DiagnosticCLI?

nonisolated(unsafe) private let signalHandler: @convention(c) (Int32) -> Void = { signal in
    globalDiagnosticCLI?.handleSignal(signal)
}

private enum CLIExitCode: Int32 {
    case success = 0
    case usageFailure = 64
    case runtimeFailure = 1
}

private enum Theory: String, CaseIterable {
    case discover
    case seize
    case redirect
}

private struct BluetoothAddress: Equatable, Hashable {
    let rawValue: String

    var comparableKey: String {
        Self.normalizeComparable(rawValue)!
    }

    init?(normalizing candidate: String) {
        guard let normalized = Self.normalizeComparable(candidate) else {
            return nil
        }

        let octets = stride(from: 0, to: normalized.count, by: 2).map { index in
            let start = normalized.index(normalized.startIndex, offsetBy: index)
            let end = normalized.index(start, offsetBy: 2)
            return String(normalized[start..<end])
        }

        rawValue = octets.joined(separator: ":")
    }

    static func normalizeComparable(_ candidate: String?) -> String? {
        guard let candidate else {
            return nil
        }

        let hexCharacters = candidate.uppercased().filter(\.isHexDigit)
        guard hexCharacters.count == 12 else {
            return nil
        }

        return String(hexCharacters)
    }
}

private enum TargetSelector: Equatable {
    case bluetoothAddress(BluetoothAddress)
    case genericAudioHeadset

    var summary: String {
        switch self {
        case .bluetoothAddress(let address):
            return "Bluetooth address \(address.rawValue)"
        case .genericAudioHeadset:
            return "generic Audio / Headset"
        }
    }
}

private struct CLIArguments {
    let theory: Theory
    let target: TargetSelector?
    let logging: Bool
}

private enum CLIArgumentError: Error, CustomStringConvertible {
    case helpRequested
    case missingTheory
    case invalidTheory(String)
    case missingTheoryValue
    case missingBluetoothAddressValue
    case invalidBluetoothAddress(String)
    case conflictingTargetFlags
    case targetRequired(Theory)
    case unexpectedArgument(String)

    var description: String {
        switch self {
        case .helpRequested:
            return ""
        case .missingTheory:
            return "The --theory flag is required."
        case .invalidTheory(let value):
            return "Invalid theory: \(value). Use discover, seize, or redirect."
        case .missingTheoryValue:
            return "The --theory flag requires a value."
        case .missingBluetoothAddressValue:
            return "The --bluetooth-address flag requires a Bluetooth address value."
        case .invalidBluetoothAddress(let candidate):
            return "Invalid Bluetooth address: \(candidate)"
        case .conflictingTargetFlags:
            return "Use either --bluetooth-address <id> or --generic-audio-headset, not both."
        case .targetRequired(let theory):
            return "The \(theory.rawValue) theory requires a target selector."
        case .unexpectedArgument(let argument):
            return "Unexpected argument: \(argument)"
        }
    }
}

private enum CLIArgumentParser {
    static func parse(_ arguments: [String]) throws -> CLIArguments {
        var theory: Theory?
        var bluetoothAddressCandidate: String?
        var wantsGenericAudioHeadset = false
        var logging = false

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]

            switch argument {
            case "--help", "-h":
                throw CLIArgumentError.helpRequested

            case "--logging":
                logging = true
                index = arguments.index(after: index)

            case "--theory":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentError.missingTheoryValue
                }

                let rawValue = arguments[nextIndex]
                guard let parsedTheory = Theory(rawValue: rawValue) else {
                    throw CLIArgumentError.invalidTheory(rawValue)
                }

                theory = parsedTheory
                index = arguments.index(after: nextIndex)

            case "--bluetooth-address":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentError.missingBluetoothAddressValue
                }

                bluetoothAddressCandidate = arguments[nextIndex]
                index = arguments.index(after: nextIndex)

            case "--generic-audio-headset":
                wantsGenericAudioHeadset = true
                index = arguments.index(after: index)

            default:
                if argument.hasPrefix("--theory=") {
                    let rawValue = String(argument.dropFirst("--theory=".count))
                    guard let parsedTheory = Theory(rawValue: rawValue) else {
                        throw CLIArgumentError.invalidTheory(rawValue)
                    }

                    theory = parsedTheory
                    index = arguments.index(after: index)
                    continue
                }

                if argument.hasPrefix("--bluetooth-address=") {
                    bluetoothAddressCandidate = String(
                        argument.dropFirst("--bluetooth-address=".count)
                    )
                    index = arguments.index(after: index)
                    continue
                }

                throw CLIArgumentError.unexpectedArgument(argument)
            }
        }

        guard let theory else {
            throw CLIArgumentError.missingTheory
        }

        if bluetoothAddressCandidate != nil && wantsGenericAudioHeadset {
            throw CLIArgumentError.conflictingTargetFlags
        }

        let target: TargetSelector?
        if wantsGenericAudioHeadset {
            target = .genericAudioHeadset
        } else if let bluetoothAddressCandidate {
            guard let address = BluetoothAddress(normalizing: bluetoothAddressCandidate) else {
                throw CLIArgumentError.invalidBluetoothAddress(bluetoothAddressCandidate)
            }

            target = .bluetoothAddress(address)
        } else {
            target = nil
        }

        if theory != .discover && target == nil {
            throw CLIArgumentError.targetRequired(theory)
        }

        return CLIArguments(theory: theory, target: target, logging: logging)
    }
}

private enum CLIUsage {
    static func helpText(executableName: String) -> String {
        """
        Usage:
          \(executableName) --theory discover [--bluetooth-address 80:C3:BA:82:06:6B | --generic-audio-headset]
          \(executableName) --theory seize --generic-audio-headset --logging
          \(executableName) --theory redirect --bluetooth-address 80:C3:BA:82:06:6B --logging

        Required:
          --theory discover|seize|redirect

        Target selectors:
          --bluetooth-address   Match a device using Bluetooth-style identity hints.
          --generic-audio-headset
                                Match Transport=Audio and Product=Headset exactly.

        Optional:
          --logging             Add detailed device, event, mapping, and forward/drop logging.

        Notes:
          - discover may run without a target selector.
          - seize and redirect require a target selector.
          - redirect automatically boots out com.apple.rcd for that theory path and restores it on exit.
          - Input Monitoring permission is required for the terminal app launching this executable.
        """
    }
}

private struct DeviceInfo {
    let serviceID: io_service_t
    let transport: String?
    let manufacturer: String?
    let product: String?
    let serialNumber: String?
    let uniqueID: String?
    let usagePage: Int?
    let usage: Int?
    let locationID: Int?
    let vendorID: Int?
    let productID: Int?
    let registryBluetoothAddresses: [BluetoothAddress]
    let registryAddressHints: [String]

    init(device: IOHIDDevice) {
        let serviceID = IOHIDDeviceGetService(device)
        let registryMetadata = Self.registryMetadata(for: serviceID)

        self.serviceID = serviceID
        self.transport = Self.stringProperty(kIOHIDTransportKey, from: device)
        self.manufacturer = Self.stringProperty(kIOHIDManufacturerKey, from: device)
        self.product = Self.stringProperty(kIOHIDProductKey, from: device)
        self.serialNumber = Self.stringProperty(kIOHIDSerialNumberKey, from: device)
        self.uniqueID = Self.stringProperty(kIOHIDUniqueIDKey, from: device)
        self.usagePage = Self.intProperty(kIOHIDDeviceUsagePageKey, from: device)
            ?? Self.intProperty(kIOHIDPrimaryUsagePageKey, from: device)
        self.usage = Self.intProperty(kIOHIDDeviceUsageKey, from: device)
            ?? Self.intProperty(kIOHIDPrimaryUsageKey, from: device)
        self.locationID = Self.intProperty(kIOHIDLocationIDKey, from: device)
        self.vendorID = Self.intProperty(kIOHIDVendorIDKey, from: device)
        self.productID = Self.intProperty(kIOHIDProductIDKey, from: device)
        self.registryBluetoothAddresses = registryMetadata.addresses
        self.registryAddressHints = registryMetadata.hints
    }

    var summary: String {
        var parts: [String] = []
        parts.append("service=\(serviceID)")
        parts.append("usagePage=\(formattedHex(usagePage))")
        parts.append("usage=\(formattedHex(usage))")

        if let transport {
            parts.append("transport=\(transport)")
        }
        if let manufacturer {
            parts.append("manufacturer=\(manufacturer)")
        }
        if let product {
            parts.append("product=\(product)")
        }
        if let serialNumber {
            parts.append("serial=\(serialNumber)")
        }
        if let uniqueID {
            parts.append("uniqueID=\(uniqueID)")
        }
        if let locationID {
            parts.append("locationID=\(locationID)")
        }
        if let vendorID {
            parts.append("vendorID=\(vendorID)")
        }
        if let productID {
            parts.append("productID=\(productID)")
        }
        if !registryAddressHints.isEmpty {
            parts.append("registryHints=\(registryAddressHints.joined(separator: ","))")
        }

        return parts.joined(separator: " | ")
    }

    func targetMatch(for target: TargetSelector) -> String? {
        switch target {
        case .bluetoothAddress(let address):
            if let serialNumber,
               BluetoothAddress.normalizeComparable(serialNumber) == address.comparableKey
            {
                return "matched serial number"
            }

            if let uniqueID,
               BluetoothAddress.normalizeComparable(uniqueID) == address.comparableKey
            {
                return "matched unique ID"
            }

            if registryBluetoothAddresses.contains(address) {
                return "matched IORegistry address hint"
            }

            return nil

        case .genericAudioHeadset:
            guard let transport = transport?.trimmingCharacters(in: .whitespacesAndNewlines),
                  transport.localizedCaseInsensitiveCompare("Audio") == .orderedSame
            else {
                return nil
            }

            guard let product = product?.trimmingCharacters(in: .whitespacesAndNewlines),
                  product.localizedCaseInsensitiveCompare("Headset") == .orderedSame
            else {
                return nil
            }

            return "matched Transport=Audio and Product=Headset"
        }
    }

    private static func stringProperty(_ key: String, from device: IOHIDDevice) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private static func intProperty(_ key: String, from device: IOHIDDevice) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        if let string = value as? String {
            return Int(string)
        }

        return nil
    }

    private static func registryMetadata(for service: io_service_t) -> (
        addresses: [BluetoothAddress], hints: [String]
    ) {
        guard service != IO_OBJECT_NULL else {
            return ([], [])
        }

        let keysToInspect = [
            "BTAddress",
            "BD_ADDR",
            "DeviceAddress",
            kIOHIDSerialNumberKey,
            kIOHIDUniqueIDKey,
        ]

        var addresses: [BluetoothAddress] = []
        var hints: [String] = []
        var seenAddresses = Set<BluetoothAddress>()
        var seenHints = Set<String>()
        var current = service
        var shouldReleaseCurrent = false

        defer {
            if shouldReleaseCurrent && current != IO_OBJECT_NULL {
                IOObjectRelease(current)
            }
        }

        for _ in 0..<12 {
            for key in keysToInspect {
                guard
                    let value = IORegistryEntryCreateCFProperty(
                        current,
                        key as CFString,
                        kCFAllocatorDefault,
                        0
                    )?.takeRetainedValue()
                else {
                    continue
                }

                for rawCandidate in addressCandidates(from: value) {
                    let hint = "\(key)=\(rawCandidate)"
                    if seenHints.insert(hint).inserted {
                        hints.append(hint)
                    }

                    guard let address = BluetoothAddress(normalizing: rawCandidate) else {
                        continue
                    }

                    if seenAddresses.insert(address).inserted {
                        addresses.append(address)
                    }
                }
            }

            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)

            if shouldReleaseCurrent && current != IO_OBJECT_NULL {
                IOObjectRelease(current)
            }

            if status != KERN_SUCCESS || parent == IO_OBJECT_NULL {
                shouldReleaseCurrent = false
                break
            }

            current = parent
            shouldReleaseCurrent = true
        }

        return (addresses, hints)
    }

    private static func addressCandidates(from value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }

        if let number = value as? NSNumber {
            return [number.stringValue]
        }

        if let data = value as? Data {
            return addressCandidates(from: data)
        }

        return []
    }

    private static func addressCandidates(from data: Data) -> [String] {
        guard !data.isEmpty else {
            return []
        }

        let bytes = Array(data)
        let forward = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        let reversed = bytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")

        if forward == reversed {
            return [forward]
        }

        return [forward, reversed]
    }
}

private enum MediaAction: String {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute

    var keyType: Int32 {
        switch self {
        case .playPause:
            return NX_KEYTYPE_PLAY
        case .nextTrack:
            return NX_KEYTYPE_NEXT
        case .previousTrack:
            return NX_KEYTYPE_PREVIOUS
        case .volumeUp:
            return NX_KEYTYPE_SOUND_UP
        case .volumeDown:
            return NX_KEYTYPE_SOUND_DOWN
        case .mute:
            return NX_KEYTYPE_MUTE
        }
    }
}

private struct HIDEvent {
    let timestamp: UInt64
    let usagePage: Int
    let usage: Int
    let value: Int

    init(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        timestamp = IOHIDValueGetTimeStamp(value)
        usagePage = Int(IOHIDElementGetUsagePage(element))
        usage = Int(IOHIDElementGetUsage(element))
        self.value = Int(IOHIDValueGetIntegerValue(value))
    }

    var isInteresting: Bool {
        switch usagePage {
        case Int(kHIDPage_Consumer):
            return true
        case Int(kHIDPage_Telephony):
            return true
        case Int(kHIDPage_GenericDesktop):
            return Self.genericDesktopUsages.contains(usage)
        default:
            return false
        }
    }

    var action: MediaAction? {
        switch (usagePage, usage) {
        case (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_PlayOrPause)):
            return .playPause
        case (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_ScanNextTrack)):
            return .nextTrack
        case (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_ScanPreviousTrack)):
            return .previousTrack
        case (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_VolumeIncrement)):
            return .volumeUp
        case (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_VolumeDecrement)):
            return .volumeDown
        case (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_Mute)):
            return .mute
        case (Int(kHIDPage_Telephony), Int(kHIDUsage_Tfon_HookSwitch)):
            return .playPause
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_SystemMenu)):
            return .playPause
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_SystemMenuRight)):
            return .nextTrack
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_SystemMenuLeft)):
            return .previousTrack
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_SystemMenuUp)):
            return .volumeUp
        case (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_SystemMenuDown)):
            return .volumeDown
        default:
            return nil
        }
    }

    var isPress: Bool {
        value != 0
    }

    private static let genericDesktopUsages: Set<Int> = [
        Int(kHIDUsage_GD_SystemControl),
        Int(kHIDUsage_GD_SystemPowerDown),
        Int(kHIDUsage_GD_SystemSleep),
        Int(kHIDUsage_GD_SystemWakeUp),
        Int(kHIDUsage_GD_SystemContextMenu),
        Int(kHIDUsage_GD_SystemMainMenu),
        Int(kHIDUsage_GD_SystemAppMenu),
        Int(kHIDUsage_GD_SystemMenu),
        Int(kHIDUsage_GD_SystemMenuRight),
        Int(kHIDUsage_GD_SystemMenuLeft),
        Int(kHIDUsage_GD_SystemMenuUp),
        Int(kHIDUsage_GD_SystemMenuDown),
    ]
}

private enum DeviceOpenMode {
    case observe
    case seize
}

private final class DeviceSession {
    unowned let app: DiagnosticCLI
    let device: IOHIDDevice
    let info: DeviceInfo
    let isTarget: Bool
    let matchReason: String?
    var openMode: DeviceOpenMode?
    var callbackInstalled = false
    var scheduled = false

    init(app: DiagnosticCLI, device: IOHIDDevice, info: DeviceInfo, isTarget: Bool, matchReason: String?) {
        self.app = app
        self.device = device
        self.info = info
        self.isTarget = isTarget
        self.matchReason = matchReason
    }

    func installCallback() {
        guard !callbackInstalled else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputValueCallback(device, DiagnosticCLI.inputValueCallback, context)
        callbackInstalled = true
    }

    func removeCallback() {
        guard callbackInstalled else {
            return
        }

        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        callbackInstalled = false
    }

    func schedule() {
        guard !scheduled else {
            return
        }

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        scheduled = true
    }

    func unschedule() {
        guard scheduled else {
            return
        }

        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        scheduled = false
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class DiagnosticCLI {
    private let arguments: CLIArguments
    private let manager: IOHIDManager
    private var deviceSessions: [io_service_t: DeviceSession] = [:]
    private var managerOpen = false
    private var isStopping = false
    private var shouldRestoreRCD = false

    init(arguments: CLIArguments) {
        self.arguments = arguments
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() -> CLIExitCode {
        guard ensureListenPermission() else {
            return .runtimeFailure
        }

        configureManager()
        installSignalHandlers()

        if arguments.theory == .redirect {
            guard bootOutRCDIfNeeded() else {
                return .runtimeFailure
            }
        }

        writeLine(startupMessage)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            writeError("Failed to open IOHIDManager: \(formattedIOReturn(openResult)).")
            cleanup()
            return .runtimeFailure
        }

        managerOpen = true
        attachExistingDevices()
        return .success
    }

    func handleSignal(_ signal: Int32) {
        writeLine("Received signal \(signal). Cleaning up.")
        stop(exitCode: .success)
    }

    private func installSignalHandlers() {
        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)
    }

    private func ensureListenPermission() -> Bool {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return true

        case kIOHIDAccessTypeUnknown, kIOHIDAccessTypeDenied:
            writeLine("Requesting Input Monitoring permission for HID event inspection.")
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            if !granted {
                writeError(
                    "Input Monitoring permission is required. Allow the terminal app in System Settings > Privacy & Security > Input Monitoring."
                )
            }
            return granted

        default:
            writeError(
                "Could not confirm HID listen access. Allow the terminal app in System Settings > Privacy & Security > Input Monitoring."
            )
            return false
        }
    }

    private func configureManager() {
        let matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_Consumer)],
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_Telephony)],
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop)],
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovalCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func attachExistingDevices() {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<NSObject> else {
            return
        }

        for deviceObject in devices {
            guard CFGetTypeID(deviceObject) == IOHIDDeviceGetTypeID() else {
                continue
            }

            let device = unsafeBitCast(deviceObject, to: IOHIDDevice.self)
            handleMatchedDevice(device)
        }
    }

    private func handleMatchedDevice(_ device: IOHIDDevice) {
        let info = DeviceInfo(device: device)
        guard deviceSessions[info.serviceID] == nil else {
            return
        }

        let matchReason = arguments.target.flatMap { info.targetMatch(for: $0) }
        let isTarget = matchReason != nil
        let session = DeviceSession(
            app: self,
            device: device,
            info: info,
            isTarget: isTarget,
            matchReason: matchReason
        )
        deviceSessions[info.serviceID] = session

        logDeviceMatch(session)

        switch arguments.theory {
        case .discover:
            openForObservation(session)
        case .seize:
            if session.isTarget {
                openForSeize(session)
            }
        case .redirect:
            openForObservation(session)
        }
    }

    private func handleRemovedDevice(_ device: IOHIDDevice) {
        let serviceID = IOHIDDeviceGetService(device)
        guard let session = deviceSessions.removeValue(forKey: serviceID) else {
            return
        }

        close(session)

        if arguments.theory == .discover || arguments.logging || session.isTarget {
            writeLine("[device removed] \(session.info.summary)")
        }
    }

    private func logDeviceMatch(_ session: DeviceSession) {
        let shouldLog: Bool
        switch arguments.theory {
        case .discover:
            shouldLog = true
        case .seize:
            shouldLog = session.isTarget || arguments.logging
        case .redirect:
            shouldLog = true
        }

        guard shouldLog else {
            return
        }

        if session.isTarget {
            writeLine("[target match] \(session.info.summary)")
            if let matchReason = session.matchReason {
                writeLine("  matchReason=\(matchReason)")
            }
        } else {
            writeLine("[device] \(session.info.summary)")
        }
    }

    private func openForObservation(_ session: DeviceSession) {
        guard session.openMode == nil else {
            return
        }

        session.installCallback()
        session.schedule()

        let result = IOHIDDeviceOpen(session.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            writeError(
                "Failed to open device for observation: \(session.info.summary) | result=\(formattedIOReturn(result))"
            )
            session.unschedule()
            session.removeCallback()
            return
        }

        session.openMode = .observe

        if arguments.theory == .discover || arguments.logging || session.isTarget {
            writeLine("[opened observe] \(session.info.summary)")
        }
    }

    private func openForSeize(_ session: DeviceSession) {
        guard session.openMode == nil else {
            return
        }

        if arguments.logging {
            session.installCallback()
            session.schedule()
        }

        let result = IOHIDDeviceOpen(session.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            if arguments.logging {
                session.unschedule()
                session.removeCallback()
            }

            writeError(
                "Seize failed for target device: \(session.info.summary) | result=\(formattedIOReturn(result))"
            )

            if UInt32(bitPattern: result) == kExclusiveAccessCode {
                writeError(
                    "Exclusive access error confirmed. Another process, likely com.apple.rcd or a similar media service, already owns this endpoint."
                )
            }
            return
        }

        session.openMode = .seize
        writeLine("[seized] \(session.info.summary)")
    }

    private func close(_ session: DeviceSession) {
        if session.openMode != nil {
            IOHIDDeviceClose(session.device, IOOptionBits(kIOHIDOptionsTypeNone))
            session.openMode = nil
        }

        session.unschedule()
        session.removeCallback()
    }

    private func handleInputValue(for session: DeviceSession, value: IOHIDValue) {
        let event = HIDEvent(value: value)
        guard event.isInteresting else {
            return
        }

        switch arguments.theory {
        case .discover:
            logEvent(event, from: session)

        case .seize:
            if arguments.logging {
                logEvent(event, from: session)
            }

        case .redirect:
            if arguments.logging {
                logEvent(event, from: session)
            }

            guard event.isPress else {
                return
            }

            guard let action = event.action else {
                if arguments.logging {
                    writeLine("[redirect ignored] unsupported action from service=\(session.info.serviceID)")
                }
                return
            }

            if session.isTarget {
                if arguments.logging {
                    writeLine("[redirect drop] action=\(action.rawValue) source=target service=\(session.info.serviceID)")
                }
                return
            }

            if arguments.logging {
                writeLine("[redirect forward] action=\(action.rawValue) source=non-target service=\(session.info.serviceID)")
            }
            repost(action)
        }
    }

    private func logEvent(_ event: HIDEvent, from session: DeviceSession) {
        let actionLabel = event.action?.rawValue ?? "unsupported"
        let sourceLabel = session.isTarget ? "target" : "non-target"
        writeLine(
            "[event] source=\(sourceLabel) service=\(session.info.serviceID) usagePage=\(formattedHex(event.usagePage)) usage=\(formattedHex(event.usage)) value=\(event.value) action=\(actionLabel) timestamp=\(event.timestamp)"
        )
    }

    private func repost(_ action: MediaAction) {
        sendMediaKey(action.keyType)
    }

    private func sendMediaKey(_ keyType: Int32) {
        let downFlags = NSEvent.ModifierFlags(rawValue: 0xA00)
        let upFlags = NSEvent.ModifierFlags(rawValue: 0xB00)
        let data1Down = Int((keyType << 16) | (0xA << 8))
        let data1Up = Int((keyType << 16) | (0xB << 8))

        guard
            let downEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: downFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: data1Down,
                data2: -1
            ),
            let upEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: upFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: data1Up,
                data2: -1
            ),
            let downCGEvent = downEvent.cgEvent,
            let upCGEvent = upEvent.cgEvent
        else {
            writeError("Failed to synthesize media key event for action keyType=\(keyType).")
            return
        }

        downCGEvent.post(tap: .cghidEventTap)
        upCGEvent.post(tap: .cghidEventTap)
    }

    private func bootOutRCDIfNeeded() -> Bool {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let serviceTarget = "\(domain)/\(kRCDServiceName)"

        let printResult = runProcess(
            executablePath: "/bin/launchctl",
            arguments: ["print", serviceTarget]
        )

        guard printResult.status == 0 else {
            writeLine(
                "com.apple.rcd was not active in \(domain). Continuing redirect theory without bootout."
            )
            return true
        }

        let bootoutResult = runProcess(
            executablePath: "/bin/launchctl",
            arguments: ["bootout", serviceTarget]
        )

        guard bootoutResult.status == 0 else {
            writeError(
                "Failed to boot out com.apple.rcd: \(bootoutResult.stderr.isEmpty ? bootoutResult.stdout : bootoutResult.stderr)"
            )
            return false
        }

        shouldRestoreRCD = true
        writeLine("Booted out com.apple.rcd for redirect theory.")
        return true
    }

    private func restoreRCDIfNeeded() {
        guard shouldRestoreRCD else {
            return
        }

        let uid = getuid()
        let domain = "gui/\(uid)"
        let serviceTarget = "\(domain)/\(kRCDServiceName)"

        let bootstrapResult = runProcess(
            executablePath: "/bin/launchctl",
            arguments: ["bootstrap", domain, kRCDPlistPath]
        )

        if bootstrapResult.status != 0 {
            writeError(
                "Failed to bootstrap com.apple.rcd: \(bootstrapResult.stderr.isEmpty ? bootstrapResult.stdout : bootstrapResult.stderr)"
            )
        }

        let kickstartResult = runProcess(
            executablePath: "/bin/launchctl",
            arguments: ["kickstart", "-k", serviceTarget]
        )

        if kickstartResult.status != 0 {
            writeError(
                "Failed to kickstart com.apple.rcd: \(kickstartResult.stderr.isEmpty ? kickstartResult.stdout : kickstartResult.stderr)"
            )
        } else {
            writeLine("Restored com.apple.rcd.")
        }

        shouldRestoreRCD = false
    }

    private func runProcess(executablePath: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(status: 1, stdout: "", stderr: error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func cleanup() {
        let sessions = Array(deviceSessions.values)
        deviceSessions.removeAll()

        for session in sessions {
            close(session)
        }

        if managerOpen {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            managerOpen = false
        }

        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        restoreRCDIfNeeded()
    }

    func stop(exitCode: CLIExitCode) {
        guard !isStopping else {
            Foundation.exit(exitCode.rawValue)
        }

        isStopping = true
        cleanup()
        fflush(stdout)
        fflush(stderr)
        Foundation.exit(exitCode.rawValue)
    }

    private var startupMessage: String {
        let loggingDescription = arguments.logging ? "additional logging enabled" : "additional logging disabled"

        switch arguments.theory {
        case .discover:
            if let target = arguments.target {
                return
                    "Running theory=discover for \(target.summary) with \(loggingDescription). Listening to Consumer, Telephony, and Generic Desktop candidates. Press Control-C to stop."
            }

            return
                "Running theory=discover with \(loggingDescription). Listening to Consumer, Telephony, and Generic Desktop candidates. Press Control-C to stop."

        case .seize:
            return
                "Running theory=seize for \(arguments.target!.summary) with \(loggingDescription). Matching target devices will be opened with exclusive access. Press Control-C to stop."

        case .redirect:
            return
                "Running theory=redirect for \(arguments.target!.summary) with \(loggingDescription). com.apple.rcd is disabled for this theory, matching target events are dropped, and supported non-target media events are reposted. Press Control-C to stop."
        }
    }

    private func writeLine(_ message: String) {
        fputs("\(message)\n", stdout)
    }

    private func writeError(_ message: String) {
        fputs("\(message)\n", stderr)
    }

    private func formattedIOReturn(_ result: IOReturn) -> String {
        "\(result) (\(formattedHex(UInt32(bitPattern: result))))"
    }

    static let deviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }

        let cli = Unmanaged<DiagnosticCLI>.fromOpaque(context).takeUnretainedValue()
        cli.handleMatchedDevice(device)
    }

    static let deviceRemovalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }

        let cli = Unmanaged<DiagnosticCLI>.fromOpaque(context).takeUnretainedValue()
        cli.handleRemovedDevice(device)
    }

    static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else {
            return
        }

        let session = Unmanaged<DeviceSession>.fromOpaque(context).takeUnretainedValue()
        session.app.handleInputValue(for: session, value: value)
    }
}

private func formattedHex<T: FixedWidthInteger>(_ value: T?) -> String {
    guard let value else {
        return "nil"
    }

    return String(format: "0x%X", UInt64(truncatingIfNeeded: value))
}

@main
private struct Momentum4PlayPauseBlockDiagCLIExecutable {
    static func main() {
        let executableName = URL(
            fileURLWithPath: CommandLine.arguments.first ?? "Momentum4PlayPauseBlockDiagCLI"
        ).lastPathComponent

        let parsedArguments: CLIArguments
        do {
            parsedArguments = try CLIArgumentParser.parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIArgumentError {
            if case .helpRequested = error {
                fputs("\(CLIUsage.helpText(executableName: executableName))\n", stdout)
                Foundation.exit(CLIExitCode.success.rawValue)
            }

            fputs("\(error.description)\n\n", stderr)
            fputs("\(CLIUsage.helpText(executableName: executableName))\n", stderr)
            Foundation.exit(CLIExitCode.usageFailure.rawValue)
        } catch {
            fputs("Unexpected CLI error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(CLIExitCode.runtimeFailure.rawValue)
        }

        let diagnosticCLI = DiagnosticCLI(arguments: parsedArguments)
        globalDiagnosticCLI = diagnosticCLI

        let startupExitCode = diagnosticCLI.start()
        if startupExitCode != .success {
            diagnosticCLI.stop(exitCode: startupExitCode)
        }

        RunLoop.main.run()
    }
}
