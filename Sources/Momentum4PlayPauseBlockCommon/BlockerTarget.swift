import Foundation

public enum BlockerTarget: Equatable, Sendable {
    case bluetoothAddress(BluetoothAddress)
    case genericAudioHeadset

    public var requiresBluetoothAddress: Bool {
        switch self {
        case .bluetoothAddress:
            return true
        case .genericAudioHeadset:
            return false
        }
    }

    public var summary: String {
        switch self {
        case .bluetoothAddress(let address):
            return "Bluetooth address \(address.rawValue)"
        case .genericAudioHeadset:
            return "generic Audio / Headset"
        }
    }
}

public struct BlockerCheckResult: Equatable, Sendable {
    public let target: BlockerTarget?
    public let matchedDevice: HIDDeviceSnapshot?
    public let message: String
    public let rejectionMessages: [String]

    public init(
        target: BlockerTarget?,
        matchedDevice: HIDDeviceSnapshot?,
        message: String,
        rejectionMessages: [String] = []
    ) {
        self.target = target
        self.matchedDevice = matchedDevice
        self.message = message
        self.rejectionMessages = rejectionMessages
    }

    public var isMatchFound: Bool {
        matchedDevice != nil
    }
}
