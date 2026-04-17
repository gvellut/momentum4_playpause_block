import Foundation
import IOBluetooth

public struct BluetoothDeviceSnapshot: Equatable, Sendable {
    public let address: BluetoothAddress
    public let name: String?
    public let isConnected: Bool

    public init(address: BluetoothAddress, name: String?, isConnected: Bool) {
        self.address = address
        self.name = name
        self.isConnected = isConnected
    }
}

public protocol BluetoothDeviceResolving {
    func resolve(address: BluetoothAddress) -> BluetoothDeviceSnapshot?
}

public final class SystemBluetoothDeviceResolver: BluetoothDeviceResolving {
    public init() {}

    public func resolve(address: BluetoothAddress) -> BluetoothDeviceSnapshot? {
        guard let unresolvedDevice = IOBluetoothDevice.perform(
            NSSelectorFromString("deviceWithAddressString:"),
            with: address.rawValue
        )?.takeUnretainedValue() as? IOBluetoothDevice else {
            return nil
        }

        let resolvedName = sanitizedName(unresolvedDevice.name) ?? sanitizedName(unresolvedDevice.nameOrAddress)

        return BluetoothDeviceSnapshot(
            address: address,
            name: resolvedName,
            isConnected: unresolvedDevice.isConnected()
        )
    }

    private func sanitizedName(_ candidate: String?) -> String? {
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
}
