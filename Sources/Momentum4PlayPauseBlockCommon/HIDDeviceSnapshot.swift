import Foundation
import IOKit.hid

public struct HIDDeviceSnapshot: Equatable, Sendable {
    public let transport: String?
    public let manufacturer: String?
    public let product: String?
    public let serialNumber: String?
    public let uniqueID: String?
    public let usagePage: Int?
    public let usage: Int?
    public let locationID: Int?
    public let vendorID: Int?
    public let productID: Int?
    public let deviceTypeHint: String?
    public let registryBluetoothAddresses: [BluetoothAddress]
    public let registryAddressHints: [String]

    public init(
        transport: String?,
        manufacturer: String?,
        product: String?,
        serialNumber: String?,
        uniqueID: String? = nil,
        usagePage: Int?,
        usage: Int?,
        locationID: Int?,
        vendorID: Int? = nil,
        productID: Int? = nil,
        deviceTypeHint: String? = nil,
        registryBluetoothAddresses: [BluetoothAddress] = [],
        registryAddressHints: [String] = []
    ) {
        self.transport = transport
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
        self.uniqueID = uniqueID
        self.usagePage = usagePage
        self.usage = usage
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
        self.deviceTypeHint = deviceTypeHint
        self.registryBluetoothAddresses = registryBluetoothAddresses
        self.registryAddressHints = registryAddressHints
    }

    public init(device: IOHIDDevice) {
        let service = IOHIDDeviceGetService(device)
        let registryMetadata = Self.registryMetadata(for: service)

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
        self.deviceTypeHint = Self.stringProperty("DeviceTypeHint", from: device)
        self.registryBluetoothAddresses = registryMetadata.addresses
        self.registryAddressHints = registryMetadata.hints
    }

    public var displaySummary: String {
        var parts: [String] = []

        if let transport {
            parts.append("transport: \(transport)")
        }
        if let product {
            parts.append("product: \(product)")
        }
        if let manufacturer {
            parts.append("manufacturer: \(manufacturer)")
        }
        if let serialNumber {
            parts.append("serial: \(serialNumber)")
        }
        if let uniqueID {
            parts.append("uniqueID: \(uniqueID)")
        }
        if !registryAddressHints.isEmpty {
            parts.append("registry: \(registryAddressHints.joined(separator: ", "))")
        }

        return parts.joined(separator: " | ")
    }

    public var isKeyboardInterface: Bool {
        usagePage == Int(kHIDPage_GenericDesktop) && usage == Int(kHIDUsage_GD_Keyboard)
    }

    public var preferredSourceLabel: String {
        if let product,
            !product.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return product
        }

        let summary = displaySummary
        if !summary.isEmpty {
            return summary
        }

        return "Unknown HID source"
    }

    public func matchesProductName(_ candidate: String) -> Bool {
        guard let product else {
            return false
        }

        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCandidate.isEmpty else {
            return false
        }

        return product.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(normalizedCandidate) == .orderedSame
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
        var addressHints: [String] = []
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
                        addressHints.append(hint)
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

        return (addresses, addressHints)
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

public enum HIDDeviceMatchResult: Equatable, Sendable {
    case matched(String)
    case rejected(String)
}

public struct HIDDeviceMatcher: Sendable {
    public init() {}

    public func match(device: HIDDeviceSnapshot, target: BlockerTarget) -> HIDDeviceMatchResult {
        guard device.usagePage == Int(kHIDPage_Consumer),
              device.usage == Int(kHIDUsage_Csmr_ConsumerControl)
        else {
            return .rejected("The HID device is not a consumer-control endpoint.")
        }

        switch target {
        case .bluetoothAddress(let address):
            if let comparableSerial = BluetoothAddress.normalizeComparable(device.serialNumber),
               comparableSerial == address.comparableKey
            {
                return .matched("The HID serial number matches the configured Bluetooth address.")
            }

            if let comparableUniqueID = BluetoothAddress.normalizeComparable(device.uniqueID),
               comparableUniqueID == address.comparableKey
            {
                return .matched("The HID unique ID matches the configured Bluetooth address.")
            }

            if device.registryBluetoothAddresses.contains(address) {
                return .matched(
                    "An address-like registry property matches the configured Bluetooth address."
                )
            }

            return .rejected(
                "The HID endpoint does not expose the configured Bluetooth address through SerialNumber, UniqueID, or parent registry address properties."
            )
        case .genericAudioHeadset:
            guard let transport = device.transport?.trimmingCharacters(in: .whitespacesAndNewlines),
                  transport.localizedCaseInsensitiveCompare("Audio") == .orderedSame
            else {
                return .rejected("The HID endpoint transport is not Audio.")
            }

            guard let product = device.product?.trimmingCharacters(in: .whitespacesAndNewlines),
                  product.localizedCaseInsensitiveCompare("Headset") == .orderedSame
            else {
                return .rejected("The HID endpoint product is not Headset.")
            }

            return .matched("The HID endpoint matches the generic Audio / Headset target.")
        }
    }
}
