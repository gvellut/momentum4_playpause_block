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
    public let target: BlockerTarget?

    public init(isEnabled: Bool, target: BlockerTarget? = nil) {
        self.isEnabled = isEnabled
        self.target = target
    }
}

@MainActor
public protocol HeadphoneBlockerControlling: AnyObject {
    var statusDidChange: ((BlockerStatus) -> Void)? { get set }
    func apply(configuration: BlockerConfiguration)
    func check(target: BlockerTarget?) -> BlockerCheckResult
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
            target: nil
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

    public func check(target: BlockerTarget?) -> BlockerCheckResult {
        guard ensureListenPermission() else {
            return BlockerCheckResult(
                target: target,
                matchedDevice: nil,
                message: BlockerStatus.permissionDenied.message
            )
        }

        guard let target else {
            return BlockerCheckResult(
                target: nil,
                matchedDevice: nil,
                message: "Choose a target before checking for a headset."
            )
        }

        guard openManagerIfNeeded() else {
            return BlockerCheckResult(
                target: target,
                matchedDevice: nil,
                message: "The HID manager could not be opened."
            )
        }

        return evaluation(for: target).checkResult
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

        guard let target = configuration.target else {
            releaseAllSeizedDevices()
            closeManagerIfNeeded()
            publishStatus(.error("No target is configured for blocking."))
            return
        }

        guard openManagerIfNeeded() else {
            releaseAllSeizedDevices()
            publishStatus(.error("The HID manager could not be opened."))
            return
        }

        refreshMatches(target: target)
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

    private func refreshMatches(target: BlockerTarget) {
        let evaluation = evaluation(for: target)

        guard let matches = evaluation.matchedCandidates else {
            releaseAllSeizedDevices()
            publishStatus(.waitingForTarget(evaluation.checkResult.message))
            return
        }

        var matchingServiceIDs = Set<io_service_t>()

        for candidate in matches {
            matchingServiceIDs.insert(candidate.serviceID)
            seizeDeviceIfNeeded(candidate.device, serviceID: candidate.serviceID)
        }

        let serviceIDsToRelease = Set(seizedDevices.keys).subtracting(matchingServiceIDs)
        for serviceID in serviceIDsToRelease {
            releaseDevice(serviceID: serviceID)
        }

        if let firstSnapshot = matches.first?.snapshot {
            publishStatus(.blocking(blockingDeviceLabel(for: firstSnapshot, target: target)))
            return
        }

        publishStatus(.waitingForTarget(evaluation.checkResult.message))
    }

    private func evaluation(for target: BlockerTarget) -> TargetEvaluation {
        switch target {
        case .bluetoothAddress(let address):
            guard let targetDevice = bluetoothResolver.resolve(address: address) else {
                return TargetEvaluation(
                    target: target,
                    checkResult: BlockerCheckResult(
                        target: target,
                        matchedDevice: nil,
                        message: "The selected Bluetooth address is unknown to macOS. Pair or connect the headset first."
                    ),
                    matchedCandidates: nil
                )
            }

            guard targetDevice.isConnected else {
                return TargetEvaluation(
                    target: target,
                    checkResult: BlockerCheckResult(
                        target: target,
                        matchedDevice: nil,
                        message: "The selected Bluetooth device is known to macOS, but it is not currently connected."
                    ),
                    matchedCandidates: nil
                )
            }

            return evaluateConnectedDevices(
                for: target,
                noDevicesMessage:
                    "The selected Bluetooth address is known to macOS, but no media-control HID endpoints are currently available.",
                noMatchMessage:
                    "The selected Bluetooth address is known to macOS, but it is not exposed by any available media-control HID endpoint."
            )

        case .genericAudioHeadset:
            return evaluateConnectedDevices(
                for: target,
                noDevicesMessage: "No media-control HID endpoints are currently available.",
                noMatchMessage:
                    "No generic Audio / Headset media-control HID endpoint is currently available."
            )
        }
    }

    private func evaluateConnectedDevices(
        for target: BlockerTarget,
        noDevicesMessage: String,
        noMatchMessage: String
    ) -> TargetEvaluation {
        guard let rawDevices = IOHIDManagerCopyDevices(manager) else {
            return TargetEvaluation(
                target: target,
                checkResult: BlockerCheckResult(
                    target: target,
                    matchedDevice: nil,
                    message: noDevicesMessage
                ),
                matchedCandidates: nil
            )
        }

        let devices = (rawDevices as NSSet).allObjects.map { $0 as! IOHIDDevice }
        var matchedCandidates: [MatchedCandidate] = []
        var rejectionMessages: [String] = []

        for device in devices {
            let snapshot = HIDDeviceSnapshot(device: device)
            let matchResult = matcher.match(device: snapshot, target: target)

            switch matchResult {
            case .matched:
                let service = IOHIDDeviceGetService(device)
                guard service != IO_OBJECT_NULL else {
                    rejectionMessages.append(
                        rejectionMessage(
                            for: snapshot,
                            reason: "The HID endpoint matched, but its IORegistry service could not be opened."
                        )
                    )
                    continue
                }

                matchedCandidates.append(
                    MatchedCandidate(device: device, serviceID: service, snapshot: snapshot)
                )

            case .rejected(let reason):
                rejectionMessages.append(rejectionMessage(for: snapshot, reason: reason))
            }
        }

        guard let firstMatch = matchedCandidates.first else {
            return TargetEvaluation(
                target: target,
                checkResult: BlockerCheckResult(
                    target: target,
                    matchedDevice: nil,
                    message: noMatchMessage,
                    rejectionMessages: rejectionMessages
                ),
                matchedCandidates: nil
            )
        }

        return TargetEvaluation(
            target: target,
            checkResult: BlockerCheckResult(
                target: target,
                matchedDevice: firstMatch.snapshot,
                message: "Found matching media-control HID endpoint for \(target.summary).",
                rejectionMessages: rejectionMessages
            ),
            matchedCandidates: matchedCandidates
        )
    }

    private func rejectionMessage(for snapshot: HIDDeviceSnapshot, reason: String) -> String {
        let summary = snapshot.displaySummary
        guard !summary.isEmpty else {
            return reason
        }

        return "\(summary): \(reason)"
    }

    private func blockingDeviceLabel(for snapshot: HIDDeviceSnapshot, target: BlockerTarget) -> String {
        switch target {
        case .bluetoothAddress(let address):
            return snapshot.product ?? snapshot.serialNumber ?? address.rawValue
        case .genericAudioHeadset:
            return snapshot.product ?? target.summary
        }
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

private struct MatchedCandidate {
    let device: IOHIDDevice
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot
}

private struct TargetEvaluation {
    let target: BlockerTarget
    let checkResult: BlockerCheckResult
    let matchedCandidates: [MatchedCandidate]?
}
