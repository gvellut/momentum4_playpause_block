import AppKit
import Darwin
import Foundation
import IOBluetooth
import IOKit.hid
import IOKit.hidsystem

private let kRCDServiceName = "com.apple.rcd"
private let kRCDPlistPath = "/System/Library/LaunchAgents/com.apple.rcd.plist"
private let kExclusiveAccessCode: UInt32 = 0xE000_02C5

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
    case tapObserve = "tap-observe"
    case tapBlockPlayPause = "tap-block-playpause"
    case bluetooth
    case serviceLog = "service-log"
    case mediaRemoteProbe = "mediaremote-probe"
    case mediaRemoteObserve = "mediaremote-observe"
    case avrcpCompensate = "avrcp-compensate"

    var requiresTarget: Bool {
        switch self {
        case .seize, .redirect, .bluetooth, .avrcpCompensate:
            return true
        case .discover, .tapObserve, .tapBlockPlayPause, .serviceLog, .mediaRemoteProbe,
            .mediaRemoteObserve:
            return false
        }
    }

    var requiresBluetoothAddressTarget: Bool {
        switch self {
        case .bluetooth, .avrcpCompensate:
            return true
        case .discover, .seize, .redirect, .tapObserve, .tapBlockPlayPause, .serviceLog,
            .mediaRemoteProbe, .mediaRemoteObserve:
            return false
        }
    }

    var usesHIDManager: Bool {
        switch self {
        case .discover, .seize, .redirect:
            return true
        case .tapObserve, .tapBlockPlayPause, .bluetooth, .serviceLog, .mediaRemoteProbe,
            .mediaRemoteObserve, .avrcpCompensate:
            return false
        }
    }

    var usesEventTap: Bool {
        switch self {
        case .tapObserve, .tapBlockPlayPause:
            return true
        case .discover, .seize, .redirect, .bluetooth, .serviceLog, .mediaRemoteProbe,
            .mediaRemoteObserve, .avrcpCompensate:
            return false
        }
    }

    var keepsRunLoopAlive: Bool {
        switch self {
        case .bluetooth, .mediaRemoteProbe:
            return false
        case .discover, .seize, .redirect, .tapObserve, .tapBlockPlayPause, .serviceLog,
            .mediaRemoteObserve, .avrcpCompensate:
            return true
        }
    }
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
    let tapLocation: EventTapLocationOption
    let commandBackend: CommandBackend
    let compensationStrategy: CompensationStrategy
    let cooldownMilliseconds: Int
    let compensationDelayMilliseconds: Int
}

private enum EventTapLocationOption: String, CaseIterable {
    case session
    case hid
    case annotated

    var cgLocation: CGEventTapLocation {
        switch self {
        case .session:
            return .cgSessionEventTap
        case .hid:
            return .cghidEventTap
        case .annotated:
            return .cgAnnotatedSessionEventTap
        }
    }
}

private enum CommandBackend: String, CaseIterable {
    case mediaRemote = "mediaremote"
    case musicAppleScript = "music-applescript"
}

private enum CompensationStrategy: String, CaseIterable {
    case immediateAndRepair = "immediate-and-repair"
    case repairOnly = "repair-only"
}

private enum CLIArgumentError: Error, CustomStringConvertible {
    case helpRequested
    case missingTheory
    case invalidTheory(String)
    case missingTheoryValue
    case missingBluetoothAddressValue
    case invalidBluetoothAddress(String)
    case missingTapLocationValue
    case invalidTapLocation(String)
    case missingCommandBackendValue
    case invalidCommandBackend(String)
    case missingCompensationStrategyValue
    case invalidCompensationStrategy(String)
    case missingCooldownValue
    case invalidCooldownValue(String)
    case missingCompensationDelayValue
    case invalidCompensationDelayValue(String)
    case conflictingTargetFlags
    case bluetoothTheoryRequiresBluetoothAddress
    case targetRequired(Theory)
    case unexpectedArgument(String)

    var description: String {
        switch self {
        case .helpRequested:
            return ""
        case .missingTheory:
            return "The --theory flag is required."
        case .invalidTheory(let value):
            return "Invalid theory: \(value). Use \(Theory.allCases.map(\.rawValue).joined(separator: ", "))."
        case .missingTheoryValue:
            return "The --theory flag requires a value."
        case .missingBluetoothAddressValue:
            return "The --bluetooth-address flag requires a Bluetooth address value."
        case .invalidBluetoothAddress(let candidate):
            return "Invalid Bluetooth address: \(candidate)"
        case .missingTapLocationValue:
            return "The --tap-location flag requires a value."
        case .invalidTapLocation(let candidate):
            return "Invalid tap location: \(candidate). Use session, hid, or annotated."
        case .missingCommandBackendValue:
            return "The --command-backend flag requires a value."
        case .invalidCommandBackend(let candidate):
            return "Invalid command backend: \(candidate). Use mediaremote or music-applescript."
        case .missingCompensationStrategyValue:
            return "The --compensation-strategy flag requires a value."
        case .invalidCompensationStrategy(let candidate):
            return
                "Invalid compensation strategy: \(candidate). Use immediate-and-repair or repair-only."
        case .missingCooldownValue:
            return "The --cooldown-ms flag requires a value."
        case .invalidCooldownValue(let candidate):
            return "Invalid cooldown milliseconds: \(candidate). Use a non-negative integer."
        case .missingCompensationDelayValue:
            return "The --compensation-delay-ms flag requires a value."
        case .invalidCompensationDelayValue(let candidate):
            return "Invalid compensation delay milliseconds: \(candidate). Use a non-negative integer."
        case .conflictingTargetFlags:
            return "Use either --bluetooth-address <id> or --generic-audio-headset, not both."
        case .bluetoothTheoryRequiresBluetoothAddress:
            return "The \(Theory.bluetooth.rawValue) and \(Theory.avrcpCompensate.rawValue) theories require --bluetooth-address <id>."
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
        var tapLocation = EventTapLocationOption.session
        var commandBackend = CommandBackend.mediaRemote
        var compensationStrategy = CompensationStrategy.immediateAndRepair
        var cooldownMilliseconds = 300
        var compensationDelayMilliseconds = 0

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

            case "--tap-location":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentError.missingTapLocationValue
                }

                let rawValue = arguments[nextIndex]
                guard let parsedTapLocation = EventTapLocationOption(rawValue: rawValue) else {
                    throw CLIArgumentError.invalidTapLocation(rawValue)
                }

                tapLocation = parsedTapLocation
                index = arguments.index(after: nextIndex)

            case "--command-backend":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentError.missingCommandBackendValue
                }

                let rawValue = arguments[nextIndex]
                guard let parsedBackend = CommandBackend(rawValue: rawValue) else {
                    throw CLIArgumentError.invalidCommandBackend(rawValue)
                }

                commandBackend = parsedBackend
                index = arguments.index(after: nextIndex)

            case "--compensation-strategy":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentError.missingCompensationStrategyValue
                }

                let rawValue = arguments[nextIndex]
                guard let parsedStrategy = CompensationStrategy(rawValue: rawValue) else {
                    throw CLIArgumentError.invalidCompensationStrategy(rawValue)
                }

                compensationStrategy = parsedStrategy
                index = arguments.index(after: nextIndex)

            case "--cooldown-ms":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentError.missingCooldownValue
                }

                let rawValue = arguments[nextIndex]
                guard let parsedValue = Int(rawValue), parsedValue >= 0 else {
                    throw CLIArgumentError.invalidCooldownValue(rawValue)
                }

                cooldownMilliseconds = parsedValue
                index = arguments.index(after: nextIndex)

            case "--compensation-delay-ms":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentError.missingCompensationDelayValue
                }

                let rawValue = arguments[nextIndex]
                guard let parsedValue = Int(rawValue), parsedValue >= 0 else {
                    throw CLIArgumentError.invalidCompensationDelayValue(rawValue)
                }

                compensationDelayMilliseconds = parsedValue
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

                if argument.hasPrefix("--tap-location=") {
                    let rawValue = String(argument.dropFirst("--tap-location=".count))
                    guard let parsedTapLocation = EventTapLocationOption(rawValue: rawValue) else {
                        throw CLIArgumentError.invalidTapLocation(rawValue)
                    }

                    tapLocation = parsedTapLocation
                    index = arguments.index(after: index)
                    continue
                }

                if argument.hasPrefix("--command-backend=") {
                    let rawValue = String(argument.dropFirst("--command-backend=".count))
                    guard let parsedBackend = CommandBackend(rawValue: rawValue) else {
                        throw CLIArgumentError.invalidCommandBackend(rawValue)
                    }

                    commandBackend = parsedBackend
                    index = arguments.index(after: index)
                    continue
                }

                if argument.hasPrefix("--compensation-strategy=") {
                    let rawValue = String(argument.dropFirst("--compensation-strategy=".count))
                    guard let parsedStrategy = CompensationStrategy(rawValue: rawValue) else {
                        throw CLIArgumentError.invalidCompensationStrategy(rawValue)
                    }

                    compensationStrategy = parsedStrategy
                    index = arguments.index(after: index)
                    continue
                }

                if argument.hasPrefix("--cooldown-ms=") {
                    let rawValue = String(argument.dropFirst("--cooldown-ms=".count))
                    guard let parsedValue = Int(rawValue), parsedValue >= 0 else {
                        throw CLIArgumentError.invalidCooldownValue(rawValue)
                    }

                    cooldownMilliseconds = parsedValue
                    index = arguments.index(after: index)
                    continue
                }

                if argument.hasPrefix("--compensation-delay-ms=") {
                    let rawValue = String(argument.dropFirst("--compensation-delay-ms=".count))
                    guard let parsedValue = Int(rawValue), parsedValue >= 0 else {
                        throw CLIArgumentError.invalidCompensationDelayValue(rawValue)
                    }

                    compensationDelayMilliseconds = parsedValue
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

        if theory.requiresTarget && target == nil {
            throw CLIArgumentError.targetRequired(theory)
        }

        if theory.requiresBluetoothAddressTarget {
            guard case .bluetoothAddress = target else {
                throw CLIArgumentError.bluetoothTheoryRequiresBluetoothAddress
            }
        }

        return CLIArguments(
            theory: theory,
            target: target,
            logging: logging,
            tapLocation: tapLocation,
            commandBackend: commandBackend,
            compensationStrategy: compensationStrategy,
            cooldownMilliseconds: cooldownMilliseconds,
            compensationDelayMilliseconds: compensationDelayMilliseconds
        )
    }
}

private enum CLIUsage {
    static func helpText(executableName: String) -> String {
        """
        Usage:
          \(executableName) --theory discover [--bluetooth-address 80:C3:BA:82:06:6B | --generic-audio-headset]
          \(executableName) --theory seize --generic-audio-headset --logging
          \(executableName) --theory redirect --bluetooth-address 80:C3:BA:82:06:6B --logging
          \(executableName) --theory tap-observe --tap-location session --logging
          \(executableName) --theory tap-block-playpause --tap-location annotated
          \(executableName) --theory bluetooth --bluetooth-address 80:C3:BA:82:06:6B
          \(executableName) --theory service-log [--bluetooth-address 80:C3:BA:82:06:6B] [--logging]
          \(executableName) --theory mediaremote-probe
          \(executableName) --theory mediaremote-observe [--logging]
          \(executableName) --theory avrcp-compensate --bluetooth-address 80:C3:BA:82:06:6B --command-backend mediaremote --logging
          \(executableName) --theory avrcp-compensate --bluetooth-address 80:C3:BA:82:06:6B --command-backend mediaremote --compensation-strategy repair-only

        Required:
          --theory discover|seize|redirect|tap-observe|tap-block-playpause|bluetooth|service-log|mediaremote-probe|mediaremote-observe|avrcp-compensate

        Target selectors:
          --bluetooth-address   Match a device using Bluetooth-style identity hints.
          --generic-audio-headset
                                Match Transport=Audio and Product=Headset exactly.

        Optional:
          --logging             Add detailed device, event, mapping, and forward/drop logging.
          --tap-location        For tap theories, choose session, hid, or annotated. Default: session.
          --command-backend     For avrcp-compensate, choose mediaremote or music-applescript. Default: mediaremote.
          --compensation-strategy
                                For avrcp-compensate, choose immediate-and-repair or repair-only. Default: immediate-and-repair.
          --cooldown-ms         Ignore duplicate headset AVRCP commands inside this window. Default: 300.
          --compensation-delay-ms
                                Delay the compensating command by this many milliseconds. Default: 0.

        Notes:
          - discover may run without a target selector.
          - seize and redirect require a target selector.
          - bluetooth requires --bluetooth-address and exits after printing the Bluetooth-side probe results.
          - tap-observe and tap-block-playpause work at the translated system event layer, not the device-aware HID layer.
          - service-log tails bluetoothd / mediaremoted / rcd logs to test whether the command only appears inside the media service layer.
          - mediaremote-probe checks whether private MediaRemote symbols can be loaded and queried in-process.
          - mediaremote-observe registers private MediaRemote notifications and distributed playback-state notifications without sending commands.
          - avrcp-compensate reacts only to AVRCP Play/Pause commands from the selected Bluetooth address and either sends the opposite command immediately and repairs if needed, or waits for the wrong playback-state transition and repairs only.
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
    let maxInputReportSize: Int?
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
        self.usagePage =
            Self.intProperty(kIOHIDDeviceUsagePageKey, from: device)
            ?? Self.intProperty(kIOHIDPrimaryUsagePageKey, from: device)
        self.usage =
            Self.intProperty(kIOHIDDeviceUsageKey, from: device)
            ?? Self.intProperty(kIOHIDPrimaryUsageKey, from: device)
        self.locationID = Self.intProperty(kIOHIDLocationIDKey, from: device)
        self.vendorID = Self.intProperty(kIOHIDVendorIDKey, from: device)
        self.productID = Self.intProperty(kIOHIDProductIDKey, from: device)
        self.maxInputReportSize = Self.intProperty(kIOHIDMaxInputReportSizeKey, from: device)
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
        if let maxInputReportSize {
            parts.append("maxInputReportSize=\(maxInputReportSize)")
        }
        if !registryAddressHints.isEmpty {
            parts.append("registryHints=\(registryAddressHints.joined(separator: ","))")
        }

        return parts.joined(separator: " | ")
    }

    var shouldSuppressRawReportLogging: Bool {
        guard let transport, let manufacturer, let product else {
            return false
        }

        return transport.localizedCaseInsensitiveCompare("USB") == .orderedSame
            && manufacturer.localizedCaseInsensitiveContains("Logitech")
            && product.localizedCaseInsensitiveCompare("USB Receiver") == .orderedSame
    }

    var shouldSkipObservationInDiscover: Bool {
        guard usagePage == Int(kHIDPage_GenericDesktop), let usage else {
            return false
        }

        // Skip obvious noisy pointer endpoints during broad discovery.
        if [0x01, 0x02].contains(usage) {
            return true
        }

        return shouldSuppressRawReportLogging
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

    static func systemDefinedAction(for keyType: Int32) -> MediaAction? {
        switch keyType {
        case NX_KEYTYPE_PLAY:
            return .playPause
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST:
            return .nextTrack
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND:
            return .previousTrack
        case NX_KEYTYPE_SOUND_UP:
            return .volumeUp
        case NX_KEYTYPE_SOUND_DOWN:
            return .volumeDown
        case NX_KEYTYPE_MUTE:
            return .mute
        default:
            return nil
        }
    }
}

private struct SystemDefinedTapEvent {
    let subtype: Int32
    let data1: Int
    let data2: Int
    let keyType: Int32
    let keyState: Int32
    let sourcePID: pid_t
    let flagsRawValue: UInt64

    init?(event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined else {
            return nil
        }

        subtype = Int32(nsEvent.subtype.rawValue)
        data1 = nsEvent.data1
        data2 = nsEvent.data2
        keyType = Int32((data1 & 0xFFFF0000) >> 16)
        keyState = Int32((data1 & 0x0000FF00) >> 8)
        sourcePID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        flagsRawValue = event.flags.rawValue
    }

    var isAuxControlButtons: Bool {
        subtype == NX_SUBTYPE_AUX_CONTROL_BUTTONS
    }

    var action: MediaAction? {
        MediaAction.systemDefinedAction(for: keyType)
    }

    var stateLabel: String {
        switch keyState {
        case 0xA:
            return "down"
        case 0xB:
            return "up"
        default:
            return "other(\(keyState))"
        }
    }

    var sourceProcessName: String? {
        guard sourcePID > 0 else {
            return nil
        }

        return NSRunningApplication(processIdentifier: sourcePID)?.localizedName
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

    var usageLabel: String? {
        switch (usagePage, usage) {
        case (Int(kHIDPage_Consumer), 0x238):
            return "ACPan"
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

private struct BluetoothServiceProfile {
    let uuid16: BluetoothSDPUUID16
    let label: String
}

private let knownBluetoothServiceProfiles: [BluetoothServiceProfile] = [
    .init(uuid16: 0x1108, label: "Headset"),
    .init(uuid16: 0x1112, label: "Headset Audio Gateway"),
    .init(uuid16: 0x111E, label: "Hands-Free"),
    .init(uuid16: 0x111F, label: "Hands-Free Audio Gateway"),
    .init(uuid16: 0x110A, label: "Audio Source"),
    .init(uuid16: 0x110B, label: "Audio Sink"),
    .init(uuid16: 0x110C, label: "AV Remote Control Target"),
    .init(uuid16: 0x110E, label: "AV Remote Control"),
    .init(uuid16: 0x110F, label: "AV Remote Control Controller"),
    .init(uuid16: 0x1124, label: "Human Interface Device"),
]

private final class BluetoothSDPQueryObserver: NSObject {
    private(set) var completionStatus: IOReturn?

    @objc(sdpQueryComplete:status:)
    func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        completionStatus = status
    }
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
    let reportBufferLength: Int
    let reportBuffer: UnsafeMutablePointer<UInt8>?
    let suppressRawReportLogging: Bool
    let skipObservationInDiscover: Bool
    var openMode: DeviceOpenMode?
    var callbackInstalled = false
    var reportCallbackInstalled = false
    var scheduled = false

    init(
        app: DiagnosticCLI, device: IOHIDDevice, info: DeviceInfo, isTarget: Bool,
        matchReason: String?
    ) {
        self.app = app
        self.device = device
        self.info = info
        self.isTarget = isTarget
        self.matchReason = matchReason
        self.suppressRawReportLogging = info.shouldSuppressRawReportLogging && !isTarget
        self.skipObservationInDiscover = info.shouldSkipObservationInDiscover && !isTarget
        self.reportBufferLength = max(info.maxInputReportSize ?? 0, 1024)
        if reportBufferLength > 0 {
            let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferLength)
            reportBuffer.initialize(repeating: 0, count: reportBufferLength)
            self.reportBuffer = reportBuffer
        } else {
            self.reportBuffer = nil
        }
    }

    deinit {
        if let reportBuffer {
            reportBuffer.deinitialize(count: reportBufferLength)
            reportBuffer.deallocate()
        }
    }

    func installCallback() {
        guard !callbackInstalled else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputValueCallback(device, DiagnosticCLI.inputValueCallback, context)
        callbackInstalled = true
    }

    func installReportCallback() {
        guard !suppressRawReportLogging, !reportCallbackInstalled, let reportBuffer, reportBufferLength > 0
        else {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            reportBufferLength,
            DiagnosticCLI.inputReportCallback,
            context
        )
        reportCallbackInstalled = true
    }

    func removeCallback() {
        guard callbackInstalled else {
            return
        }

        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        callbackInstalled = false
    }

    func removeReportCallback() {
        guard reportCallbackInstalled, let reportBuffer, reportBufferLength > 0 else {
            return
        }

        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, reportBufferLength, nil, nil)
        reportCallbackInstalled = false
    }

    func schedule() {
        guard !scheduled else {
            return
        }

        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        scheduled = true
    }

    func unschedule() {
        guard scheduled else {
            return
        }

        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        scheduled = false
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private enum MediaRemoteCommand: UInt32, CaseIterable {
    case play = 0
    case pause = 1

    var label: String {
        switch self {
        case .play:
            return "Play"
        case .pause:
            return "Pause"
        }
    }

    var opposite: MediaRemoteCommand {
        switch self {
        case .play:
            return .pause
        case .pause:
            return .play
        }
    }
}

private struct MediaRemoteProbeResult {
    let bundleLoaded: Bool
    let libraryOpened: Bool
    let availableSymbols: [String: Bool]
    let playbackStateQueryReturned: Bool
    let playbackStateValue: UInt32?
    let playbackStateNotificationName: String?
}

private final class MediaRemoteBridge {
    private typealias SendCommandFunction = @convention(c) (UInt32, CFDictionary?) -> Void
    private typealias RegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue)
        -> Void
    private typealias GetPlaybackStateFunction = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (UInt32) -> Void
    ) -> Void

    private let bundleLoaded: Bool
    private let libraryHandle: UnsafeMutableRawPointer?
    private let sendCommandFunction: SendCommandFunction?
    private let registerForNowPlayingNotificationsFunction:
        RegisterForNowPlayingNotificationsFunction?
    private let getPlaybackStateFunction: GetPlaybackStateFunction?
    private let playbackStateNotificationSymbolPointer: UnsafeMutableRawPointer?

    init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework"
        bundleLoaded = Bundle(path: frameworkPath)?.load() ?? false
        libraryHandle = dlopen("\(frameworkPath)/MediaRemote", RTLD_NOW)

        sendCommandFunction = Self.loadFunction(named: "MRMediaRemoteSendCommand")
        registerForNowPlayingNotificationsFunction = Self.loadFunction(
            named: "MRMediaRemoteRegisterForNowPlayingNotifications"
        )
        getPlaybackStateFunction = Self.loadFunction(
            named: "MRMediaRemoteGetNowPlayingApplicationPlaybackState"
        )
        playbackStateNotificationSymbolPointer = dlsym(
            Self.globalSymbolHandle,
            "kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification"
        )
    }

    var nowPlayingPlaybackStateDidChangeNotificationName: String? {
        guard let playbackStateNotificationSymbolPointer else {
            return nil
        }

        let pointer = playbackStateNotificationSymbolPointer.assumingMemoryBound(to: CFString?.self)
        guard let name = pointer.pointee else {
            return nil
        }

        return name as String
    }

    func makeProbeResult(timeout: TimeInterval) -> MediaRemoteProbeResult {
        let playbackStateProbe = queryPlaybackState(timeout: timeout)
        return MediaRemoteProbeResult(
            bundleLoaded: bundleLoaded,
            libraryOpened: libraryHandle != nil,
            availableSymbols: [
                "MRMediaRemoteSendCommand": sendCommandFunction != nil,
                "MRMediaRemoteRegisterForNowPlayingNotifications":
                    registerForNowPlayingNotificationsFunction != nil,
                "MRMediaRemoteGetNowPlayingApplicationPlaybackState":
                    getPlaybackStateFunction != nil,
                "kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification":
                    playbackStateNotificationSymbolPointer != nil,
            ],
            playbackStateQueryReturned: playbackStateProbe.didReturn,
            playbackStateValue: playbackStateProbe.value,
            playbackStateNotificationName: nowPlayingPlaybackStateDidChangeNotificationName
        )
    }

    func registerForNowPlayingNotifications() -> Bool {
        guard let registerForNowPlayingNotificationsFunction else {
            return false
        }

        registerForNowPlayingNotificationsFunction(.main)
        return true
    }

    func send(command: MediaRemoteCommand) -> Bool {
        guard let sendCommandFunction else {
            return false
        }

        sendCommandFunction(command.rawValue, nil)
        return true
    }

    func queryPlaybackState(timeout: TimeInterval) -> (didReturn: Bool, value: UInt32?) {
        guard let getPlaybackStateFunction else {
            return (false, nil)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "Momentum4PlayPauseBlockDiagCLI.MediaRemoteProbe")
        var playbackStateValue: UInt32?
        let callback: @convention(block) (UInt32) -> Void = { state in
            playbackStateValue = state
            semaphore.signal()
        }

        getPlaybackStateFunction(queue, callback)

        let didReturn = semaphore.wait(timeout: .now() + timeout) == .success
        return (didReturn, playbackStateValue)
    }

    private static var globalSymbolHandle: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: -2)!
    }

    private static func loadFunction<T>(named symbol: String) -> T? {
        guard let symbolPointer = dlsym(globalSymbolHandle, symbol) else {
            return nil
        }

        return unsafeBitCast(symbolPointer, to: T.self)
    }
}

private enum ServiceLogMediaRemoteDirection: String {
    case request
    case response
    case clientReceived = "client-received"
}

private enum ServiceLogEventKind {
    case avrcpCommand(command: MediaRemoteCommand, address: BluetoothAddress)
    case mediaRemoteCommand(
        command: MediaRemoteCommand,
        direction: ServiceLogMediaRemoteDirection,
        bundleIdentifier: String
    )
    case playbackStateTransition(from: String, to: String)
}

private struct ServiceLogEvent {
    let timestamp: String?
    let rawLine: String
    let kind: ServiceLogEventKind
}

private struct PendingAVRCPCompensation {
    let address: BluetoothAddress
    let incomingCommand: MediaRemoteCommand
    let compensatingCommand: MediaRemoteCommand
    let strategy: CompensationStrategy
    let createdAt: Date
    var repairAttempts: Int

    var expectedWrongPlaybackState: String {
        switch incomingCommand {
        case .pause:
            return "paused"
        case .play:
            return "playing"
        }
    }

    var desiredPlaybackState: String {
        switch incomingCommand {
        case .pause:
            return "playing"
        case .play:
            return "paused"
        }
    }
}

private enum AVRCPLogEventParser {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})"#
    )
    private static let avrcpCommandExpression = try! NSRegularExpression(
        pattern: #"Received AVRCP (Play|Pause) command from device ([0-9A-F:]{17})"#
    )
    private static let mediaRemoteRequestResponseExpression = try! NSRegularExpression(
        pattern: #"(Request|Response): Command = <(Play|Pause)>.*SenderBundleIdentifier = <([^>]+)>"#
    )
    private static let mediaRemoteClientReceivedExpression = try! NSRegularExpression(
        pattern: #"Received command from client <.*bundleIdentifier = ([^,>]+).*command = (Play|Pause),"#
    )
    private static let playbackStateTransitionExpression = try! NSRegularExpression(
        pattern: #"setting playback state from <([^>]+)> to <([^>]+)>"#
    )

    static func parse(line: String) -> ServiceLogEvent? {
        let timestamp = firstMatch(in: line, using: timestampExpression)?.first

        if let groups = firstMatch(in: line, using: avrcpCommandExpression),
            groups.count == 2,
            let command = mediaRemoteCommand(from: groups[0]),
            let address = BluetoothAddress(normalizing: groups[1])
        {
            return ServiceLogEvent(
                timestamp: timestamp,
                rawLine: line,
                kind: .avrcpCommand(command: command, address: address)
            )
        }

        if let groups = firstMatch(in: line, using: mediaRemoteRequestResponseExpression),
            groups.count == 3,
            let command = mediaRemoteCommand(from: groups[1])
        {
            let direction: ServiceLogMediaRemoteDirection =
                groups[0] == "Response" ? .response : .request
            return ServiceLogEvent(
                timestamp: timestamp,
                rawLine: line,
                kind: .mediaRemoteCommand(
                    command: command,
                    direction: direction,
                    bundleIdentifier: groups[2]
                )
            )
        }

        if let groups = firstMatch(in: line, using: mediaRemoteClientReceivedExpression),
            groups.count == 2,
            let command = mediaRemoteCommand(from: groups[1])
        {
            return ServiceLogEvent(
                timestamp: timestamp,
                rawLine: line,
                kind: .mediaRemoteCommand(
                    command: command,
                    direction: .clientReceived,
                    bundleIdentifier: groups[0]
                )
            )
        }

        if let groups = firstMatch(in: line, using: playbackStateTransitionExpression),
            groups.count == 2
        {
            return ServiceLogEvent(
                timestamp: timestamp,
                rawLine: line,
                kind: .playbackStateTransition(from: groups[0], to: groups[1])
            )
        }

        return nil
    }

    private static func mediaRemoteCommand(from candidate: String) -> MediaRemoteCommand? {
        switch candidate.lowercased() {
        case "play":
            return .play
        case "pause":
            return .pause
        default:
            return nil
        }
    }

    private static func firstMatch(in string: String, using expression: NSRegularExpression)
        -> [String]?
    {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = expression.firstMatch(in: string, options: [], range: range) else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            let nsRange = match.range(at: index)
            guard let range = Range(nsRange, in: string) else {
                return nil
            }

            return String(string[range])
        }
    }
}

private final class DiagnosticCLI: @unchecked Sendable {
    private let arguments: CLIArguments
    private let manager: IOHIDManager
    private let mediaRemoteBridge = MediaRemoteBridge()
    private var deviceSessions: [io_service_t: DeviceSession] = [:]
    private var discoverUnsupportedEventKeys = Set<String>()
    private var hidPostEventConnection: io_connect_t = IO_OBJECT_NULL
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var serviceLogProcess: Process?
    private var serviceLogPipe: Pipe?
    private var serviceLogPendingText = ""
    private var distributedNotificationObservers: [NSObjectProtocol] = []
    private var lastCompensationByEventKey: [String: Date] = [:]
    private var pendingAVRCPCompensations: [BluetoothAddress: PendingAVRCPCompensation] = [:]
    private var managerOpen = false
    private var isStopping = false
    private var shouldRestoreRCD = false

    init(arguments: CLIArguments) {
        self.arguments = arguments
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    var shouldEnterRunLoop: Bool {
        arguments.theory.keepsRunLoopAlive
    }

    func start() -> CLIExitCode {
        installSignalHandlers()

        switch arguments.theory {
        case .bluetooth:
            writeLine(startupMessage)
            return runBluetoothTheory() ? .success : .runtimeFailure

        case .mediaRemoteProbe:
            writeLine(startupMessage)
            return runMediaRemoteProbeTheory() ? .success : .runtimeFailure

        case .serviceLog:
            writeLine(startupMessage)
            guard startServiceLogTheory() else {
                cleanup()
                return .runtimeFailure
            }
            return .success

        case .mediaRemoteObserve:
            writeLine(startupMessage)
            guard installMediaRemoteObservers() else {
                cleanup()
                return .runtimeFailure
            }
            return .success

        case .avrcpCompensate:
            writeLine(startupMessage)
            guard installMediaRemoteObservers() else {
                cleanup()
                return .runtimeFailure
            }

            guard validateCompensationBackend() else {
                cleanup()
                return .runtimeFailure
            }

            guard startServiceLogTheory() else {
                cleanup()
                return .runtimeFailure
            }
            return .success

        case .tapObserve, .tapBlockPlayPause:
            guard ensureEventTapListenPermission() else {
                return .runtimeFailure
            }

            writeLine(startupMessage)
            guard installSystemEventTap() else {
                cleanup()
                return .runtimeFailure
            }
            return .success

        case .discover, .seize, .redirect:
            guard ensureListenPermission() else {
                return .runtimeFailure
            }

            configureManager()

            if arguments.theory == .redirect {
                guard bootOutRCDIfNeeded() else {
                    return .runtimeFailure
                }

                guard ensurePostPermission() else {
                    return .runtimeFailure
                }

                _ = openPostEventConnectionIfNeeded()
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
    }

    func handleSignal(_ signal: Int32) {
        writeLine("Received signal \(signal). Cleaning up.")
        stop(exitCode: .success)
    }

    private func installSignalHandlers() {
        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)
    }

    private func ensureEventTapListenPermission() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }

        writeLine("Requesting listen-event permission for CG event tap inspection.")
        let granted = CGRequestListenEventAccess()
        if !granted {
            writeError(
                "Listen-event permission is required for tap theories. Allow the terminal app in System Settings > Privacy & Security > Input Monitoring."
            )
        }
        return granted
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

    private func ensurePostPermission() -> Bool {
        switch IOHIDCheckAccess(kIOHIDRequestTypePostEvent) {
        case kIOHIDAccessTypeGranted:
            return true

        case kIOHIDAccessTypeUnknown, kIOHIDAccessTypeDenied:
            writeLine("Requesting HID post-event permission for redirect forwarding.")
            let granted = IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
            if !granted {
                writeError(
                    "HID post-event permission is required for redirect forwarding. Allow the terminal app if macOS prompts."
                )
            }
            return granted

        default:
            writeError("Could not confirm HID post-event permission.")
            return false
        }
    }

    private func openPostEventConnectionIfNeeded() -> Bool {
        guard hidPostEventConnection == IO_OBJECT_NULL else {
            return true
        }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(kIOHIDSystemClass)
        )
        guard service != IO_OBJECT_NULL else {
            writeError("Could not find IOHIDSystem service for redirect reposting.")
            return false
        }

        defer { IOObjectRelease(service) }

        var connection: io_connect_t = IO_OBJECT_NULL
        let result = IOServiceOpen(
            service,
            mach_task_self_,
            UInt32(kIOHIDParamConnectType),
            &connection
        )

        guard result == kIOReturnSuccess else {
            writeError("Could not open IOHIDSystem connection: \(formattedIOReturn(result)).")
            return false
        }

        hidPostEventConnection = connection
        return true
    }

    private func runMediaRemoteProbeTheory() -> Bool {
        let probeResult = mediaRemoteBridge.makeProbeResult(timeout: 2.0)
        writeLine(
            "[mediaremote probe] scope=global active MediaRemote client, not Apple Music specifically"
        )
        writeLine(
            "[mediaremote probe] note=another app such as Firefox can own the active media session even while Music is open or audible"
        )
        writeLine("[mediaremote probe] bundle.load=\(probeResult.bundleLoaded)")
        writeLine("[mediaremote probe] dlopen=\(probeResult.libraryOpened)")

        for symbol in probeResult.availableSymbols.keys.sorted() {
            let available = probeResult.availableSymbols[symbol] ?? false
            writeLine("[mediaremote probe] symbol=\(symbol) available=\(available)")
        }

        if let notificationName = probeResult.playbackStateNotificationName {
            writeLine("[mediaremote probe] playbackStateNotificationName=\(notificationName)")
        } else {
            writeLine("[mediaremote probe] playbackStateNotificationName=unavailable")
        }

        if probeResult.playbackStateQueryReturned {
            let valueDescription = probeResult.playbackStateValue.map(String.init) ?? "nil"
            writeLine("[mediaremote probe] playbackStateQuery=returned value=\(valueDescription)")
        } else {
            writeLine("[mediaremote probe] playbackStateQuery=timed-out")
        }

        return true
    }

    private func installMediaRemoteObservers() -> Bool {
        let registerResult = mediaRemoteBridge.registerForNowPlayingNotifications()
        writeLine(
            "[mediaremote observe] registerForNowPlayingNotifications=\(registerResult)"
        )

        let distributedCenter = DistributedNotificationCenter.default()
        let notificationNames = Set(
            [
                mediaRemoteBridge.nowPlayingPlaybackStateDidChangeNotificationName,
                "com.apple.MediaRemote.nowPlayingApplicationPlaybackStateDidChange",
                "com.apple.MediaRemote.nowPlayingApplicationIsPlayingDidChange",
                "com.apple.MediaRemote.nowPlayingActivePlayersIsPlayingDidChange",
            ].compactMap { $0 }
        ).sorted()

        for notificationName in notificationNames {
            let token = distributedCenter.addObserver(
                forName: Notification.Name(notificationName),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleObservedMediaRemoteNotification(
                    centerLabel: "distributed",
                    notificationName: notification.name.rawValue
                )
            }
            distributedNotificationObservers.append(token)
            writeLine(
                "[mediaremote observe] observerInstalled center=distributed name=\(notificationName)"
            )
        }

        return registerResult || !notificationNames.isEmpty
    }

    private func validateCompensationBackend() -> Bool {
        switch arguments.commandBackend {
        case .mediaRemote:
            let probeResult = mediaRemoteBridge.makeProbeResult(timeout: 0.1)
            guard probeResult.availableSymbols["MRMediaRemoteSendCommand"] == true else {
                writeError(
                    "The mediaremote backend is unavailable because MRMediaRemoteSendCommand could not be resolved."
                )
                return false
            }
            return true

        case .musicAppleScript:
            return true
        }
    }

    private func startServiceLogTheory() -> Bool {
        guard serviceLogProcess == nil else {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style",
            "compact",
            "--level",
            arguments.logging ? "debug" : "default",
            "--predicate",
            #"process == "rcd" || process == "bluetoothd" || process == "mediaremoted""#,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputHandle = pipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else {
                return
            }

            guard let chunk = String(data: data, encoding: .utf8) else {
                return
            }

            self.handleServiceLogChunk(chunk)
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            writeError("Failed to start /usr/bin/log stream: \(error.localizedDescription)")
            return false
        }

        serviceLogProcess = process
        serviceLogPipe = pipe
        writeLine(
            "[service-log] streaming bluetoothd / mediaremoted / rcd logs\(arguments.logging ? " with broad output" : " with structured filtering")"
        )
        return true
    }

    private func handleServiceLogChunk(_ chunk: String) {
        serviceLogPendingText += chunk
        let hasTrailingNewline = serviceLogPendingText.hasSuffix("\n")
        let rawLines = serviceLogPendingText.split(separator: "\n", omittingEmptySubsequences: false)

        let linesToProcess: ArraySlice<Substring>
        if hasTrailingNewline {
            linesToProcess = rawLines[rawLines.startIndex..<rawLines.endIndex]
            serviceLogPendingText.removeAll(keepingCapacity: true)
        } else if rawLines.isEmpty {
            return
        } else {
            linesToProcess = rawLines.dropLast()
            serviceLogPendingText = String(rawLines.last ?? "")
        }

        for rawLine in linesToProcess {
            let line = String(rawLine).trimmingCharacters(in: .newlines)
            guard !line.isEmpty else {
                continue
            }

            handleServiceLogLine(line)
        }
    }

    private func handleServiceLogLine(_ line: String) {
        let parsedEvent = AVRCPLogEventParser.parse(line: line)

        switch arguments.theory {
        case .serviceLog:
            if arguments.logging {
                writeLine("[service-log raw] \(line)")
                return
            }

            if let parsedEvent, let compactDescription = compactDescription(for: parsedEvent) {
                writeLine("[service-log] \(compactDescription)")
                return
            }

            if shouldPrintRawServiceLogLine(line) {
                writeLine("[service-log] \(line)")
            }

        case .avrcpCompensate:
            handleAVRCPCompensationLogLine(line, parsedEvent: parsedEvent)

        case .discover, .seize, .redirect, .tapObserve, .tapBlockPlayPause, .bluetooth,
            .mediaRemoteProbe, .mediaRemoteObserve:
            break
        }
    }

    private func handleObservedMediaRemoteNotification(
        centerLabel: String,
        notificationName: String
    ) {
        let timestamp = Self.serviceLogTimestampFormatter.string(from: Date())
        writeLine(
            "[mediaremote observe] timestamp=\(timestamp) center=\(centerLabel) name=\(notificationName)"
        )
    }

    private func handleAVRCPCompensationLogLine(
        _ line: String,
        parsedEvent: ServiceLogEvent?
    ) {
        guard let parsedEvent else {
            if arguments.logging && shouldPrintRawServiceLogLine(line) {
                writeLine("[avrcp raw] \(line)")
            }
            return
        }

        if let compactDescription = compactDescription(for: parsedEvent) {
            writeLine("[avrcp observed] \(compactDescription)")
        }

        switch parsedEvent.kind {
        case .avrcpCommand(let command, let address):
            guard isTargetAddress(address) else {
                if arguments.logging {
                    writeLine(
                        "[avrcp ignored] address=\(address.rawValue) did not match target selector"
                    )
                }
                return
            }

            guard shouldCompensate(for: address, incomingCommand: command) else {
                writeLine(
                    "[avrcp skipped] address=\(address.rawValue) command=\(command.label) reason=cooldown backend=\(arguments.commandBackend.rawValue)"
                )
                return
            }

            let oppositeCommand = command.opposite
            writeLine(
                "[avrcp match] address=\(address.rawValue) incoming=\(command.label) compensateWith=\(oppositeCommand.label) backend=\(arguments.commandBackend.rawValue) strategy=\(arguments.compensationStrategy.rawValue) delayMs=\(arguments.compensationDelayMilliseconds)"
            )
            armPendingCompensation(
                incomingCommand: command,
                compensatingCommand: oppositeCommand,
                targetAddress: address
            )

            if arguments.compensationStrategy == .immediateAndRepair {
                scheduleCompensation(command: oppositeCommand, targetAddress: address)
            } else {
                writeLine(
                    "[avrcp waiting] address=\(address.rawValue) strategy=repair-only waitingForPlaybackStateMismatch"
                )
            }

        case .playbackStateTransition(let from, let to):
            handleObservedPlaybackStateTransition(from: from, to: to)

        case .mediaRemoteCommand:
            break
        }
    }

    private func shouldEmitCompactServiceLogEvent(_ event: ServiceLogEvent) -> Bool {
        switch event.kind {
        case .avrcpCommand(_, let address):
            if case .bluetoothAddress(let targetAddress) = arguments.target {
                return address == targetAddress
            }
            return true

        case .mediaRemoteCommand(_, _, let bundleIdentifier):
            return bundleIdentifier == "com.apple.bluetoothd"

        case .playbackStateTransition:
            return true
        }
    }

    private func compactDescription(for event: ServiceLogEvent) -> String? {
        guard shouldEmitCompactServiceLogEvent(event) else {
            return nil
        }

        let timestampPrefix = event.timestamp.map { "timestamp=\($0) " } ?? ""

        switch event.kind {
        case .avrcpCommand(let command, let address):
            return "\(timestampPrefix)avrcpCommand=\(command.label) address=\(address.rawValue)"

        case .mediaRemoteCommand(let command, let direction, let bundleIdentifier):
            return
                "\(timestampPrefix)mediaRemote direction=\(direction.rawValue) command=\(command.label) senderBundleIdentifier=\(bundleIdentifier)"

        case .playbackStateTransition(let from, let to):
            return "\(timestampPrefix)playbackState from=\(from) to=\(to)"
        }
    }

    private func shouldPrintRawServiceLogLine(_ line: String) -> Bool {
        if arguments.logging {
            return true
        }

        if case .bluetoothAddress = arguments.target {
            return false
        }

        let lowercaseLine = line.lowercased()
        let keywords = [
            "avrcp",
            "mediaremote",
            "media remote",
            "play",
            "pause",
            "command",
            "button",
            "headset",
            "momentum",
            "bluetooth",
            "remotecontrol",
            "now playing",
            "nowplaying",
            "hfp",
            "a2dp",
            "route",
            "rcd",
            "mediaremoted",
        ]

        if keywords.contains(where: lowercaseLine.contains) {
            return true
        }

        if case .bluetoothAddress(let address) = arguments.target {
            let comparableAddress = address.comparableKey.lowercased()
            let compactLine = lowercaseLine.filter(\.isHexDigit)
            if compactLine.contains(comparableAddress) {
                return true
            }
        }

        return false
    }

    private func isTargetAddress(_ address: BluetoothAddress) -> Bool {
        guard case .bluetoothAddress(let targetAddress) = arguments.target else {
            return false
        }

        return targetAddress == address
    }

    private func shouldCompensate(
        for address: BluetoothAddress,
        incomingCommand: MediaRemoteCommand
    ) -> Bool {
        purgeExpiredPendingCompensations()

        let eventKey = "\(address.comparableKey):\(incomingCommand.rawValue)"
        let now = Date()

        if let lastDate = lastCompensationByEventKey[eventKey],
            now.timeIntervalSince(lastDate) * 1000 < Double(arguments.cooldownMilliseconds)
        {
            return false
        }

        lastCompensationByEventKey[eventKey] = now
        return true
    }

    private func armPendingCompensation(
        incomingCommand: MediaRemoteCommand,
        compensatingCommand: MediaRemoteCommand,
        targetAddress: BluetoothAddress
    ) {
        pendingAVRCPCompensations[targetAddress] = PendingAVRCPCompensation(
            address: targetAddress,
            incomingCommand: incomingCommand,
            compensatingCommand: compensatingCommand,
            strategy: arguments.compensationStrategy,
            createdAt: Date(),
            repairAttempts: 0
        )
    }

    private func purgeExpiredPendingCompensations() {
        let now = Date()
        let expirationInterval: TimeInterval = 2.0

        pendingAVRCPCompensations = pendingAVRCPCompensations.filter { _, pending in
            now.timeIntervalSince(pending.createdAt) < expirationInterval
        }
    }

    private func handleObservedPlaybackStateTransition(from: String, to: String) {
        purgeExpiredPendingCompensations()

        let normalizedToState = normalizedPlaybackStateLabel(to)
        guard !normalizedToState.isEmpty else {
            return
        }

        for (address, pending) in Array(pendingAVRCPCompensations) {
            if normalizedToState == pending.desiredPlaybackState {
                writeLine(
                    "[avrcp stabilized] address=\(address.rawValue) finalState=\(to) incoming=\(pending.incomingCommand.label)"
                )
                pendingAVRCPCompensations[address] = nil
                continue
            }

            guard normalizedToState == pending.expectedWrongPlaybackState else {
                continue
            }

            guard pending.repairAttempts < 1 else {
                continue
            }

            writeLine(
                "[avrcp repair] address=\(address.rawValue) strategy=\(pending.strategy.rawValue) observedFinalState=\(to) expectedFinalState=\(pending.desiredPlaybackState) sending=\(pending.compensatingCommand.label)"
            )

            var updatedPending = pending
            updatedPending.repairAttempts += 1
            pendingAVRCPCompensations[address] = updatedPending
            scheduleCompensation(command: pending.compensatingCommand, targetAddress: address)
        }
    }

    private func normalizedPlaybackStateLabel(_ state: String) -> String {
        state
            .lowercased()
            .filter { $0.isLetter }
    }

    private func scheduleCompensation(command: MediaRemoteCommand, targetAddress: BluetoothAddress) {
        let delay = Double(arguments.compensationDelayMilliseconds) / 1000.0
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else {
                    return
                }

                self.performCompensation(command: command, targetAddress: targetAddress)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.performCompensation(command: command, targetAddress: targetAddress)
            }
        }
    }

    private func performCompensation(command: MediaRemoteCommand, targetAddress: BluetoothAddress) {
        guard !isStopping else {
            return
        }

        let succeeded: Bool
        let backendLabel = arguments.commandBackend.rawValue

        switch arguments.commandBackend {
        case .mediaRemote:
            succeeded = mediaRemoteBridge.send(command: command)

        case .musicAppleScript:
            succeeded = sendMusicAppleScriptCommand(command)
        }

        if succeeded {
            writeLine(
                "[avrcp compensate] address=\(targetAddress.rawValue) backend=\(backendLabel) command=\(command.label) result=success"
            )
        } else {
            writeError(
                "[avrcp compensate] address=\(targetAddress.rawValue) backend=\(backendLabel) command=\(command.label) result=failure"
            )
        }
    }

    private func sendMusicAppleScriptCommand(_ command: MediaRemoteCommand) -> Bool {
        let verb: String
        switch command {
        case .play:
            verb = "play"
        case .pause:
            verb = "pause"
        }

        let result = runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Music\" to \(verb)"]
        )

        if result.status == 0 {
            return true
        }

        let errorMessage = result.stderr.isEmpty ? result.stdout : result.stderr
        writeError("[music-applescript] \(errorMessage)")
        return false
    }

    private func installSystemEventTap() -> Bool {
        guard eventTap == nil else {
            return true
        }

        guard let systemDefinedEventType = CGEventType(rawValue: UInt32(NX_SYSDEFINED)) else {
            writeError("Could not create CGEventType for NX_SYSDEFINED.")
            return false
        }

        let eventMask = CGEventMask(1) << CGEventMask(systemDefinedEventType.rawValue)
        let options: CGEventTapOptions =
            arguments.theory == .tapObserve ? .listenOnly : .defaultTap
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard
            let eventTap = CGEvent.tapCreate(
                tap: arguments.tapLocation.cgLocation,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: eventMask,
                callback: Self.systemEventTapCallback,
                userInfo: context
            )
        else {
            writeError(
                "Failed to create CG event tap at location=\(arguments.tapLocation.rawValue). Check permissions and try a different --tap-location value."
            )
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            writeError("Failed to create run loop source for CG event tap.")
            CFMachPortInvalidate(eventTap)
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        writeLine(
            "[tap installed] location=\(arguments.tapLocation.rawValue) mode=\(arguments.theory == .tapObserve ? "listenOnly" : "defaultTap")"
        )
        return true
    }

    private func runBluetoothTheory() -> Bool {
        guard case .bluetoothAddress(let address) = arguments.target else {
            writeError("The bluetooth theory requires --bluetooth-address <id>.")
            return false
        }

        guard let device = resolveBluetoothDevice(address: address) else {
            writeError("Could not resolve a Bluetooth device for address \(address.rawValue).")
            return false
        }

        let deviceName = sanitizedBluetoothName(device.name) ?? sanitizedBluetoothName(device.nameOrAddress)
        let connectedLabel = device.isConnected() ? "true" : "false"
        writeLine(
            "[bluetooth device] address=\(address.rawValue) name=\(deviceName ?? "Unknown") connected=\(connectedLabel)"
        )

        if let lastServicesUpdate = device.getLastServicesUpdate() {
            writeLine("[bluetooth services cache] lastUpdate=\(lastServicesUpdate)")
        } else {
            writeLine("[bluetooth services cache] no cached SDP query on record")
        }

        let observer = BluetoothSDPQueryObserver()
        let queryStartResult = device.performSDPQuery(observer)
        if queryStartResult == kIOReturnSuccess {
            writeLine("[bluetooth sdp] started full SDP query for \(address.rawValue)")
        } else {
            writeError(
                "[bluetooth sdp] failed to start SDP query: \(formattedIOReturn(queryStartResult))"
            )
        }

        let deadline = Date().addingTimeInterval(8)
        while observer.completionStatus == nil && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        if let completionStatus = observer.completionStatus {
            writeLine("[bluetooth sdp] completionStatus=\(formattedIOReturn(completionStatus))")
        } else {
            writeError("[bluetooth sdp] timed out waiting for SDP query completion; using any cached services that are available.")
        }

        let services = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        if services.isEmpty {
            writeLine("[bluetooth service] none")
        } else {
            for (index, service) in services.enumerated() {
                writeLine("[bluetooth service \(index + 1)] \(describeBluetoothService(service))")
            }
        }

        emitBluetoothInference(for: services)
        return true
    }

    private func resolveBluetoothDevice(address: BluetoothAddress) -> IOBluetoothDevice? {
        IOBluetoothDevice.perform(
            NSSelectorFromString("deviceWithAddressString:"),
            with: address.rawValue
        )?.takeUnretainedValue() as? IOBluetoothDevice
    }

    private func sanitizedBluetoothName(_ candidate: String?) -> String? {
        guard let candidate else {
            return nil
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if BluetoothAddress.normalizeComparable(trimmed) != nil {
            return nil
        }

        return trimmed
    }

    private func describeBluetoothService(_ service: IOBluetoothSDPServiceRecord) -> String {
        var parts: [String] = []

        if let serviceName = sanitizedBluetoothName(service.getServiceName()) {
            parts.append("name=\(serviceName)")
        }

        let matchedProfiles = knownBluetoothServiceProfiles.compactMap { profile in
            service.matchesUUID16(profile.uuid16) ? profile.label : nil
        }
        if !matchedProfiles.isEmpty {
            parts.append("profiles=\(matchedProfiles.joined(separator: ","))")
        }

        var psm: BluetoothL2CAPPSM = 0
        if service.getL2CAPPSM(&psm) == kIOReturnSuccess {
            parts.append("l2capPSM=\(psm)")
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        if service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
            parts.append("rfcommChannel=\(channelID)")
        }

        var recordHandle: BluetoothSDPServiceRecordHandle = 0
        if service.getHandle(&recordHandle) == kIOReturnSuccess {
            parts.append("recordHandle=\(recordHandle)")
        }

        if parts.isEmpty {
            parts.append("unnamed service record")
        }

        return parts.joined(separator: " | ")
    }

    private func emitBluetoothInference(for services: [IOBluetoothSDPServiceRecord]) {
        let matchedProfileLabels = Set(
            services.flatMap { service in
                knownBluetoothServiceProfiles.compactMap { profile in
                    service.matchesUUID16(profile.uuid16) ? profile.label : nil
                }
            }
        )

        if matchedProfileLabels.isEmpty {
            writeLine(
                "Inference: no known audio-control SDP profiles were identified in this probe, so the Bluetooth side is still inconclusive."
            )
            return
        }

        let hasHID = matchedProfileLabels.contains("Human Interface Device")
        let hasAudioControlProfile =
            matchedProfileLabels.contains("AV Remote Control Target")
            || matchedProfileLabels.contains("AV Remote Control")
            || matchedProfileLabels.contains("AV Remote Control Controller")
            || matchedProfileLabels.contains("Audio Sink")
            || matchedProfileLabels.contains("Hands-Free")
            || matchedProfileLabels.contains("Headset")

        if hasAudioControlProfile && !hasHID {
            writeLine(
                "Inference: the headset advertises classic audio-control profiles such as AVRCP/HFP/A2DP and no HID service was identified in this SDP probe. That is consistent with the HID-based theories staying silent for MOMENTUM 4."
            )
            return
        }

        if hasHID {
            writeLine(
                "Inference: a HID service record was identified in this SDP probe, so the headset may still expose a control path outside the current HID matching rules."
            )
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
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
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
            if session.skipObservationInDiscover {
                writeLine("[device ignored for observation] \(session.info.summary)")
            } else {
                openForObservation(session)
            }
        case .seize:
            if session.isTarget {
                openForSeize(session)
            }
        case .redirect:
            openForObservation(session)
        case .tapObserve, .tapBlockPlayPause, .bluetooth, .serviceLog, .mediaRemoteProbe,
            .mediaRemoteObserve, .avrcpCompensate:
            break
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
        case .tapObserve, .tapBlockPlayPause, .bluetooth, .serviceLog, .mediaRemoteProbe,
            .mediaRemoteObserve, .avrcpCompensate:
            shouldLog = arguments.logging
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
            if session.suppressRawReportLogging && arguments.theory == .discover {
                writeLine("  rawReportLogging=disabled for noisy Logitech USB receiver")
            }
        }
    }

    private func openForObservation(_ session: DeviceSession) {
        guard session.openMode == nil else {
            return
        }

        session.installCallback()
        session.installReportCallback()
        session.schedule()

        let result = IOHIDDeviceOpen(session.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            writeError(
                "Failed to open device for observation: \(session.info.summary) | result=\(formattedIOReturn(result))"
            )
            session.unschedule()
            session.removeCallback()
            session.removeReportCallback()
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
            session.installReportCallback()
            session.schedule()
        }

        let result = IOHIDDeviceOpen(session.device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            if arguments.logging {
                session.unschedule()
                session.removeCallback()
                session.removeReportCallback()
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
        session.removeReportCallback()
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
                    writeLine(
                        "[redirect ignored] unsupported action from service=\(session.info.serviceID)"
                    )
                }
                return
            }

            if session.isTarget {
                if arguments.logging {
                    writeLine(
                        "[redirect drop] action=\(action.rawValue) source=target service=\(session.info.serviceID)"
                    )
                }
                return
            }

            if arguments.logging {
                writeLine(
                    "[redirect forward] action=\(action.rawValue) source=non-target service=\(session.info.serviceID)"
                )
            }
            repost(action)

        case .tapObserve, .tapBlockPlayPause, .bluetooth, .serviceLog, .mediaRemoteProbe,
            .mediaRemoteObserve, .avrcpCompensate:
            return
        }
    }

    private func logEvent(_ event: HIDEvent, from session: DeviceSession) {
        if arguments.theory == .discover, !session.isTarget, event.action == nil {
            if event.value == 0 {
                return
            }

            let key = "\(session.info.serviceID):\(event.usagePage):\(event.usage)"
            guard discoverUnsupportedEventKeys.insert(key).inserted else {
                return
            }
        }

        let actionLabel = event.action?.rawValue ?? "unsupported"
        let sourceLabel = session.isTarget ? "target" : "non-target"
        let usageLabelSuffix = event.usageLabel.map { " usageLabel=\($0)" } ?? ""
        writeLine(
            "[event] source=\(sourceLabel) service=\(session.info.serviceID) usagePage=\(formattedHex(event.usagePage)) usage=\(formattedHex(event.usage)) value=\(event.value) action=\(actionLabel)\(usageLabelSuffix) timestamp=\(event.timestamp)"
        )
    }

    private func handleInputReport(
        for session: DeviceSession,
        result: IOReturn,
        type: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        guard result == kIOReturnSuccess else {
            if arguments.theory == .discover || arguments.logging || session.isTarget {
                writeError(
                    "[report error] service=\(session.info.serviceID) type=\(type.rawValue) reportID=\(reportID) result=\(formattedIOReturn(result))"
                )
            }
            return
        }

        let byteCount = Int(reportLength)
        guard byteCount > 0 else {
            return
        }

        let previewCount = min(byteCount, 32)
        let bytes = UnsafeBufferPointer(start: report, count: previewCount)
        let hexPreview = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let truncatedSuffix = byteCount > previewCount ? " ..." : ""
        let sourceLabel = session.isTarget ? "target" : "non-target"

        writeLine(
            "[report] source=\(sourceLabel) service=\(session.info.serviceID) type=\(type.rawValue) reportID=\(reportID) length=\(byteCount) bytes=\(hexPreview)\(truncatedSuffix)"
        )
    }

    private func handleSystemEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            writeLine("[tap] re-enabled after \(type.rawValue)")
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == UInt32(NX_SYSDEFINED) else {
            return Unmanaged.passUnretained(event)
        }

        guard let tapEvent = SystemDefinedTapEvent(event: event), tapEvent.isAuxControlButtons else {
            return Unmanaged.passUnretained(event)
        }

        let actionLabel = tapEvent.action?.rawValue ?? "unsupported"
        let processLabel = tapEvent.sourceProcessName.map { " sourceProcess=\($0)" } ?? ""
        let loggingSuffix: String
        if arguments.logging {
            loggingSuffix =
                " flags=\(formattedHex(tapEvent.flagsRawValue)) data1=\(formattedHex(tapEvent.data1)) data2=\(formattedHex(tapEvent.data2))"
        } else {
            loggingSuffix = ""
        }

        writeLine(
            "[tap event] location=\(arguments.tapLocation.rawValue) keyType=\(tapEvent.keyType) action=\(actionLabel) state=\(tapEvent.stateLabel) sourcePID=\(tapEvent.sourcePID)\(processLabel)\(loggingSuffix)"
        )

        guard arguments.theory == .tapBlockPlayPause, tapEvent.action == .playPause else {
            return Unmanaged.passUnretained(event)
        }

        writeLine(
            "[tap drop] action=playPause state=\(tapEvent.stateLabel) sourcePID=\(tapEvent.sourcePID)\(processLabel)"
        )
        return nil
    }

    private func repost(_ action: MediaAction) {
        sendMediaKey(action.keyType)
    }

    private func sendMediaKey(_ keyType: Int32) {
        if postMediaKeyViaNSEvent(keyType) {
            return
        }

        if postMediaKeyViaIOHID(keyType) {
            return
        }

        writeError("All media key repost methods failed for keyType=\(keyType).")
    }

    private func postMediaKeyViaIOHID(_ keyType: Int32) -> Bool {
        guard hidPostEventConnection != IO_OBJECT_NULL || openPostEventConnectionIfNeeded() else {
            return false
        }

        let location = IOGPoint(x: 0, y: 0)

        let downData = Int32((keyType << 16) | (0xA << 8))
        let upData = Int32((keyType << 16) | (0xB << 8))

        var downEventData = makeAuxControlEventData(data1: downData)
        let downResult = IOHIDPostEvent(
            hidPostEventConnection,
            UInt32(NX_SYSDEFINED),
            location,
            &downEventData,
            UInt32(kNXEventDataVersion),
            0,
            0
        )

        guard downResult == kIOReturnSuccess else {
            writeError(
                "IOHIDPostEvent key down failed for keyType=\(keyType): \(formattedIOReturn(downResult))"
            )
            return false
        }

        var upEventData = makeAuxControlEventData(data1: upData)
        let upResult = IOHIDPostEvent(
            hidPostEventConnection,
            UInt32(NX_SYSDEFINED),
            location,
            &upEventData,
            UInt32(kNXEventDataVersion),
            0,
            0
        )

        guard upResult == kIOReturnSuccess else {
            writeError(
                "IOHIDPostEvent key up failed for keyType=\(keyType): \(formattedIOReturn(upResult))"
            )
            return false
        }

        if arguments.logging {
            writeLine("[redirect repost] keyType=\(keyType) via=IOHIDPostEvent")
        }

        return true
    }

    private func postMediaKeyViaNSEvent(_ keyType: Int32) -> Bool {
        let downData1 = Int((keyType << 16) | (0xA << 8))
        let upData1 = Int((keyType << 16) | (0xB << 8))

        guard
            let downEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(NX_KEYDOWN << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: downData1,
                data2: -1
            ),
            let upEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(NX_KEYUP << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                data1: upData1,
                data2: -1
            ),
            let downCGEvent = downEvent.cgEvent,
            let upCGEvent = upEvent.cgEvent
        else {
            writeError("Failed to create NSEvent media key events for keyType=\(keyType).")
            return false
        }

        downCGEvent.post(tap: .cghidEventTap)
        upCGEvent.post(tap: .cghidEventTap)

        if arguments.logging {
            writeLine("[redirect repost] keyType=\(keyType) via=NSEvent")
        }

        return true
    }

    private func makeAuxControlEventData(data1: Int32) -> NXEventData {
        var eventData = NXEventData()
        eventData.compound.subType = Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS)

        withUnsafeMutableBytes(of: &eventData.compound.misc) { rawBuffer in
            let values = rawBuffer.bindMemory(to: Int32.self)
            values[0] = data1
            values[1] = -1
        }

        return eventData
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

        let stdout =
            String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        let stderr =
            String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
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

        if hidPostEventConnection != IO_OBJECT_NULL {
            IOServiceClose(hidPostEventConnection)
            hidPostEventConnection = IO_OBJECT_NULL
        }

        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let serviceLogProcess {
            serviceLogPipe?.fileHandleForReading.readabilityHandler = nil
            if serviceLogProcess.isRunning {
                serviceLogProcess.terminate()
            }
            self.serviceLogProcess = nil
            self.serviceLogPipe = nil
            serviceLogPendingText.removeAll(keepingCapacity: false)
        }

        if !distributedNotificationObservers.isEmpty {
            let distributedCenter = DistributedNotificationCenter.default()
            for observer in distributedNotificationObservers {
                distributedCenter.removeObserver(observer)
            }
            distributedNotificationObservers.removeAll(keepingCapacity: false)
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
        let loggingDescription =
            arguments.logging ? "additional logging enabled" : "additional logging disabled"

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

        case .tapObserve:
            if let target = arguments.target {
                return
                    "Running theory=tap-observe for \(target.summary) with \(loggingDescription). Listening for translated NSSystemDefined media events at tap location=\(arguments.tapLocation.rawValue). This layer is not device-aware. Press Control-C to stop."
            }

            return
                "Running theory=tap-observe with \(loggingDescription). Listening for translated NSSystemDefined media events at tap location=\(arguments.tapLocation.rawValue). Press Control-C to stop."

        case .tapBlockPlayPause:
            return
                "Running theory=tap-block-playpause with \(loggingDescription). Listening at tap location=\(arguments.tapLocation.rawValue) and dropping translated play/pause system events at that layer. This blocks all matching sources seen by the tap. Press Control-C to stop."

        case .bluetooth:
            return
                "Running theory=bluetooth for \(arguments.target!.summary) with \(loggingDescription). Resolving the Bluetooth device and querying SDP service profiles. This theory exits after printing its results."

        case .serviceLog:
            if let target = arguments.target {
                return
                    "Running theory=service-log for \(target.summary) with \(loggingDescription). Tailing bluetoothd, mediaremoted, and rcd logs to test whether the headset command only exists inside the system media service layer. Press Control-C to stop."
            }

            return
                "Running theory=service-log with \(loggingDescription). Tailing bluetoothd, mediaremoted, and rcd logs to test whether the command only exists inside the system media service layer. Press Control-C to stop."

        case .mediaRemoteProbe:
            return
                "Running theory=mediaremote-probe with \(loggingDescription). Probing private MediaRemote framework loading, symbol resolution, and playback-state query behavior. This theory exits after printing its results."

        case .mediaRemoteObserve:
            return
                "Running theory=mediaremote-observe with \(loggingDescription). Registering private MediaRemote and distributed playback-state notifications to test what a normal user process can observe. Press Control-C to stop."

        case .avrcpCompensate:
            return
                "Running theory=avrcp-compensate for \(arguments.target!.summary) with \(loggingDescription). Listening for AVRCP Play/Pause commands from the selected Bluetooth address and using strategy=\(arguments.compensationStrategy.rawValue) through backend=\(arguments.commandBackend.rawValue) with cooldownMs=\(arguments.cooldownMilliseconds) and delayMs=\(arguments.compensationDelayMilliseconds). Press Control-C to stop."
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

    private static let serviceLogTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

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

    static let inputReportCallback: IOHIDReportCallback = {
        context,
        result,
        _,
        type,
        reportID,
        report,
        reportLength
    in
        guard let context else {
            return
        }

        let session = Unmanaged<DeviceSession>.fromOpaque(context).takeUnretainedValue()
        session.app.handleInputReport(
            for: session,
            result: result,
            type: type,
            reportID: reportID,
            report: report,
            reportLength: reportLength
        )
    }

    static let systemEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let cli = Unmanaged<DiagnosticCLI>.fromOpaque(userInfo).takeUnretainedValue()
        return cli.handleSystemEventTap(type: type, event: event)
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

        if diagnosticCLI.shouldEnterRunLoop {
            RunLoop.main.run()
        }

        diagnosticCLI.stop(exitCode: .success)
    }
}
