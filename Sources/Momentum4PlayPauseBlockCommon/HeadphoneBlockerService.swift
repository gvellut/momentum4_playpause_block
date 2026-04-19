import Foundation
import IOBluetooth
import IOKit.hid
import IOKit.hidsystem

public enum BlockerStatus: Equatable, Sendable {
    case disabled
    case requestingPermission
    case permissionDenied
    case waitingForTarget(String)
    case blocking(String)
    case error(String)

    public var message: String {
        switch self {
        case .disabled:
            return "Blocking is disabled."
        case .requestingPermission:
            return
                "macOS is requesting Input Monitoring permission so the app can inspect HID media events."
        case .permissionDenied:
            return
                "Input Monitoring permission is required. Allow the app in System Settings > Privacy & Security > Input Monitoring."
        case .waitingForTarget(let message):
            return message
        case .blocking(let deviceName):
            return "Blocking media-control events from \(deviceName)."
        case .error(let message):
            return message
        }
    }
}

public struct BlockerConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let targetAddress: BluetoothAddress?

    public init(isEnabled: Bool, targetAddress: BluetoothAddress? = nil) {
        self.isEnabled = isEnabled
        self.targetAddress = targetAddress
    }
}

@MainActor
public protocol HeadphoneBlockerControlling: AnyObject {
    var statusDidChange: ((BlockerStatus) -> Void)? { get set }
    func apply(configuration: BlockerConfiguration)
}

@MainActor
public final class HeadphoneBlockerService: HeadphoneBlockerControlling {
    public var statusDidChange: ((BlockerStatus) -> Void)?

    private let manager: IOHIDManager
    private let bluetoothResolver: BluetoothDeviceResolving
    private let matcher: HIDDeviceMatcher
    private var configuration: BlockerConfiguration
    private var managerIsOpen = false
    private var seizedDevices: [io_service_t: IOHIDDevice] = [:]

    public init(
        bluetoothResolver: BluetoothDeviceResolving = SystemBluetoothDeviceResolver(),
        matcher: HIDDeviceMatcher = HIDDeviceMatcher()
    ) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.bluetoothResolver = bluetoothResolver
        self.matcher = matcher
        self.configuration = BlockerConfiguration(
            isEnabled: false,
            targetAddress: nil
        )

        let matchingDictionary: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Int(kHIDPage_Consumer),
            kIOHIDDeviceUsageKey: Int(kHIDUsage_Csmr_ConsumerControl),
        ]

        IOHIDManagerSetDeviceMatching(manager, matchingDictionary as CFDictionary)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovalCallback, context)
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    public func apply(configuration: BlockerConfiguration) {
        self.configuration = configuration
        reconcileState()
    }

    private func reconcileState() {
        guard configuration.isEnabled else {
            releaseAllSeizedDevices()
            closeManagerIfNeeded()
            publishStatus(.disabled)
            return
        }

        guard ensureListenPermission() else {
            releaseAllSeizedDevices()
            closeManagerIfNeeded()
            return
        }

        guard let targetAddress = configuration.targetAddress else {
            releaseAllSeizedDevices()
            closeManagerIfNeeded()
            publishStatus(.error("No Bluetooth address is configured for blocking."))
            return
        }

        guard openManagerIfNeeded() else {
            releaseAllSeizedDevices()
            publishStatus(.error("The HID manager could not be opened."))
            return
        }

        refreshMatches(targetAddress: targetAddress)
    }

    private func ensureListenPermission() -> Bool {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return true
        case kIOHIDAccessTypeDenied, kIOHIDAccessTypeUnknown:
            publishStatus(.requestingPermission)
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            if !granted {
                publishStatus(.permissionDenied)
            }
            return granted
        default:
            publishStatus(.permissionDenied)
            return false
        }
    }

    private func openManagerIfNeeded() -> Bool {
        if managerIsOpen {
            return true
        }

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            return false
        }

        managerIsOpen = true
        return true
    }

    private func closeManagerIfNeeded() {
        guard managerIsOpen else {
            return
        }

        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        managerIsOpen = false
    }

    private func refreshMatches(targetAddress: BluetoothAddress) {
        guard let targetDevice = bluetoothResolver.resolve(address: targetAddress) else {
            releaseAllSeizedDevices()
            publishStatus(
                .waitingForTarget(
                    "The configured Bluetooth address is unknown to macOS. Pair or connect the headset first."
                ))
            return
        }

        guard targetDevice.isConnected else {
            releaseAllSeizedDevices()
            publishStatus(
                .waitingForTarget(
                    "The configured headset is known, but it is not currently connected."))
            return
        }

        guard let rawDevices = IOHIDManagerCopyDevices(manager) else {
            releaseAllSeizedDevices()
            publishStatus(
                .waitingForTarget(
                    "No Bluetooth consumer-control HID devices are currently available."))
            return
        }

        let devices = (rawDevices as NSSet).allObjects.map { $0 as! IOHIDDevice }
        var matchingServiceIDs = Set<io_service_t>()

        for device in devices {
            var deviceName = "Unknown Device"
            if let nameRef = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) {
                deviceName = nameRef as! String
            }

            print("Found Media Controller: \(deviceName)")

            let snapshot = HIDDeviceSnapshot(device: device)
            let matchResult = matcher.match(device: snapshot, target: targetDevice)
            guard case .matched = matchResult else {
                continue
            }

            let service = IOHIDDeviceGetService(device)
            guard service != IO_OBJECT_NULL else {
                continue
            }

            matchingServiceIDs.insert(service)
            seizeDeviceIfNeeded(device, serviceID: service)
        }

        let seizedServiceIDs = Set(seizedDevices.keys)
        let serviceIDsToRelease = seizedServiceIDs.subtracting(matchingServiceIDs)
        for serviceID in serviceIDsToRelease {
            releaseDevice(serviceID: serviceID)
        }

        if let device = seizedDevices.values.first {
            let deviceName =
                HIDDeviceSnapshot(device: device).product
                ?? targetDevice.name
                ?? targetDevice.address.rawValue
            publishStatus(.blocking(deviceName))
            return
        }

        publishStatus(
            .waitingForTarget(
                "The target headset is connected, but no confidently matching media-control HID endpoint was found."
            )
        )
    }

    private func seizeDeviceIfNeeded(_ device: IOHIDDevice, serviceID: io_service_t) {
        guard seizedDevices[serviceID] == nil else {
            return
        }

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            return
        }

        seizedDevices[serviceID] = device
    }

    private func releaseDevice(serviceID: io_service_t) {
        guard let device = seizedDevices.removeValue(forKey: serviceID) else {
            return
        }

        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func releaseAllSeizedDevices() {
        let serviceIDs = Array(seizedDevices.keys)
        for serviceID in serviceIDs {
            releaseDevice(serviceID: serviceID)
        }
    }

    private func publishStatus(_ status: BlockerStatus) {
        statusDidChange?(status)
    }

    private static let deviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else {
            return
        }

        let service = Unmanaged<HeadphoneBlockerService>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            service.reconcileState()
        }
    }

    private static let deviceRemovalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }

        let serviceID = IOHIDDeviceGetService(device)
        let service = Unmanaged<HeadphoneBlockerService>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            if serviceID != IO_OBJECT_NULL {
                service.releaseDevice(serviceID: serviceID)
            }
            service.reconcileState()
        }
    }
}
