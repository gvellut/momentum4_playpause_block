import Foundation
import IOKit.hid

public struct HIDDeviceSnapshot: Equatable, Sendable {
    public let transport: String?
    public let manufacturer: String?
    public let product: String?
    public let serialNumber: String?
    public let usagePage: Int?
    public let usage: Int?
    public let locationID: Int?

    public init(
        transport: String?,
        manufacturer: String?,
        product: String?,
        serialNumber: String?,
        usagePage: Int?,
        usage: Int?,
        locationID: Int?
    ) {
        self.transport = transport
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
        self.usagePage = usagePage
        self.usage = usage
        self.locationID = locationID
    }

    public init(device: IOHIDDevice) {
        self.transport = Self.stringProperty(kIOHIDTransportKey, from: device)
        self.manufacturer = Self.stringProperty(kIOHIDManufacturerKey, from: device)
        self.product = Self.stringProperty(kIOHIDProductKey, from: device)
        self.serialNumber = Self.stringProperty(kIOHIDSerialNumberKey, from: device)
        self.usagePage = Self.intProperty(kIOHIDDeviceUsagePageKey, from: device)
            ?? Self.intProperty(kIOHIDPrimaryUsagePageKey, from: device)
        self.usage = Self.intProperty(kIOHIDDeviceUsageKey, from: device)
            ?? Self.intProperty(kIOHIDPrimaryUsageKey, from: device)
        self.locationID = Self.intProperty(kIOHIDLocationIDKey, from: device)
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
}

public enum HIDDeviceMatchResult: Equatable, Sendable {
    case matched(String)
    case rejected(String)
}

public struct HIDDeviceMatcher: Sendable {
    public init() {}

    public func match(device: HIDDeviceSnapshot, target: BluetoothDeviceSnapshot) -> HIDDeviceMatchResult {
        guard let transport = device.transport?.trimmingCharacters(in: .whitespacesAndNewlines),
              transport.localizedCaseInsensitiveContains("bluetooth")
        else {
            return .rejected("The HID device is not exposed over Bluetooth.")
        }

        guard device.usagePage == Int(kHIDPage_Consumer),
              device.usage == Int(kHIDUsage_Csmr_ConsumerControl)
        else {
            return .rejected("The HID device is not a consumer-control endpoint.")
        }

        if let comparableSerial = BluetoothAddress.normalizeComparable(device.serialNumber),
           comparableSerial == target.address.comparableKey
        {
            return .matched("The HID serial number matches the configured Bluetooth address.")
        }

        guard target.isConnected else {
            return .rejected("The target Bluetooth device is not connected, so name-based matching is not trusted.")
        }

        let targetName = normalizedWords(from: target.name)
        guard !targetName.isEmpty else {
            return .rejected("The target Bluetooth device does not expose a stable name for secondary matching.")
        }

        let productWords = normalizedWords(from: device.product)
        let manufacturerWords = normalizedWords(from: device.manufacturer)
        let hasNameOverlap = !targetName.isDisjoint(with: productWords)
        let hasMomentumSignal = productWords.contains("MOMENTUM")
        let hasSennheiserSignal = manufacturerWords.contains("SENNHEISER") || productWords.contains("SENNHEISER")

        guard hasNameOverlap && (hasMomentumSignal || hasSennheiserSignal) else {
            return .rejected("The HID metadata does not match the target headset strongly enough.")
        }

        return .matched("The HID metadata matches the connected target headset name and brand.")
    }

    private func normalizedWords(from candidate: String?) -> Set<String> {
        guard let candidate else {
            return []
        }

        let uppercase = candidate.uppercased()
        let tokens = uppercase
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { String($0) }

        return Set(tokens)
    }
}
