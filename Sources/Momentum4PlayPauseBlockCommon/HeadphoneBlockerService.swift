import Foundation
import IOKit.hid
import IOKit.hidsystem

public enum BlockerStatus: Equatable, Sendable {
    case disabled
    case requestingPermission
    case permissionDenied
    case waitingForTarget(String)
    case blocking(String)
    case observing(String)
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
        case .observing(let deviceName):
            return "Logging media-control events from \(deviceName)."
        case .error(let message):
            return message
        }
    }
}

public struct BlockerConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let target: BlockerTarget?
    public let operationMode: BlockerOperationMode

    public init(
        isEnabled: Bool,
        target: BlockerTarget? = nil,
        operationMode: BlockerOperationMode = .block
    ) {
        self.isEnabled = isEnabled
        self.target = target
        self.operationMode = operationMode
    }
}

@MainActor
public protocol HeadphoneBlockerControlling: AnyObject {
    var statusDidChange: ((BlockerStatus) -> Void)? { get set }
    var inputEventDidReceive: ((HIDInputEvent) -> Void)? { get set }

    func apply(configuration: BlockerConfiguration)
    func check(target: BlockerTarget?) -> BlockerCheckResult
}

@MainActor
public final class HeadphoneBlockerService: HeadphoneBlockerControlling {
    public var statusDidChange: ((BlockerStatus) -> Void)?
    public var inputEventDidReceive: ((HIDInputEvent) -> Void)?

    private let hidEnvironment: HIDEnvironment
    private let bluetoothResolver: BluetoothDeviceResolving
    private let matcher: HIDDeviceMatcher
    private var configuration: BlockerConfiguration
    private var managerIsOpen = false
    private var activeSessions: [io_service_t: ActiveSession] = [:]

    public convenience init(
        bluetoothResolver: BluetoothDeviceResolving = SystemBluetoothDeviceResolver(),
        matcher: HIDDeviceMatcher = HIDDeviceMatcher()
    ) {
        self.init(
            bluetoothResolver: bluetoothResolver,
            matcher: matcher,
            hidEnvironment: SystemHIDEnvironment()
        )
    }

    init(
        bluetoothResolver: BluetoothDeviceResolving,
        matcher: HIDDeviceMatcher,
        hidEnvironment: HIDEnvironment
    ) {
        self.hidEnvironment = hidEnvironment
        self.bluetoothResolver = bluetoothResolver
        self.matcher = matcher
        self.configuration = BlockerConfiguration(isEnabled: false, target: nil)

        hidEnvironment.devicesDidChange = { [weak self] in
            Task { @MainActor in
                self?.reconcileState()
            }
        }
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
            releaseAllActiveSessions()
            closeManagerIfNeeded()
            publishStatus(.disabled)
            return
        }

        guard ensureListenPermission() else {
            releaseAllActiveSessions()
            closeManagerIfNeeded()
            return
        }

        guard let target = configuration.target else {
            releaseAllActiveSessions()
            closeManagerIfNeeded()
            publishStatus(.error("No target is configured for blocking."))
            return
        }

        guard openManagerIfNeeded() else {
            releaseAllActiveSessions()
            publishStatus(.error("The HID manager could not be opened."))
            return
        }

        refreshMatches(target: target)
    }

    private func ensureListenPermission() -> Bool {
        switch hidEnvironment.checkListenAccess() {
        case kIOHIDAccessTypeGranted:
            return true
        case kIOHIDAccessTypeDenied, kIOHIDAccessTypeUnknown:
            publishStatus(.requestingPermission)
            let granted = hidEnvironment.requestListenAccess()
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

        let result = hidEnvironment.openManager()
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

        hidEnvironment.closeManager()
        managerIsOpen = false
    }

    private func refreshMatches(target: BlockerTarget) {
        let evaluation = evaluation(for: target)

        guard let matches = evaluation.matchedCandidates else {
            releaseAllActiveSessions()
            publishStatus(.waitingForTarget(evaluation.checkResult.message))
            return
        }

        var activatedServiceIDs = Set<io_service_t>()
        var activationFailures: [ActivationFailure] = []

        for candidate in matches {
            switch activateCandidateIfNeeded(candidate, mode: configuration.operationMode) {
            case .active(let session):
                activatedServiceIDs.insert(session.serviceID)
            case .failed(let failure):
                activationFailures.append(failure)
            }
        }

        let serviceIDsToRelease = Set(activeSessions.keys).subtracting(activatedServiceIDs)
        for serviceID in serviceIDsToRelease {
            releaseDevice(serviceID: serviceID)
        }

        if let firstActiveSession = matches.compactMap({ activeSessions[$0.serviceID] }).first {
            publishStatus(
                statusForActiveSession(
                    snapshot: firstActiveSession.snapshot,
                    target: target,
                    mode: firstActiveSession.mode
                )
            )
            return
        }

        if !activationFailures.isEmpty {
            publishStatus(
                .error(
                    activationFailureMessage(
                        target: target,
                        mode: configuration.operationMode,
                        failures: activationFailures
                    )
                )
            )
            return
        }

        publishStatus(.waitingForTarget(evaluation.checkResult.message))
    }

    private func activateCandidateIfNeeded(
        _ candidate: MatchedCandidate,
        mode: BlockerOperationMode
    ) -> ActivationResult {
        if let existingSession = activeSessions[candidate.serviceID] {
            if existingSession.mode == mode {
                return .active(existingSession)
            }

            releaseDevice(serviceID: candidate.serviceID)
        }

        switch mode {
        case .block:
            return activateBlockingCandidate(candidate)
        case .logEvents:
            return activateLoggingCandidate(candidate)
        }
    }

    private func activateBlockingCandidate(_ candidate: MatchedCandidate) -> ActivationResult {
        let result = candidate.device.open(options: IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            return .failed(
                ActivationFailure(
                    serviceID: candidate.serviceID,
                    snapshot: candidate.snapshot,
                    mode: .block,
                    openResult: result
                )
            )
        }

        let session = ActiveSession(
            device: candidate.device,
            serviceID: candidate.serviceID,
            snapshot: candidate.snapshot,
            mode: .block
        )
        activeSessions[candidate.serviceID] = session
        return .active(session)
    }

    private func activateLoggingCandidate(_ candidate: MatchedCandidate) -> ActivationResult {
        candidate.device.setInputValueHandler { [weak self] event in
            self?.inputEventDidReceive?(event)
        }
        candidate.device.scheduleWithMainRunLoop()

        let result = candidate.device.open(options: IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            candidate.device.unscheduleFromMainRunLoop()
            candidate.device.setInputValueHandler(nil)
            return .failed(
                ActivationFailure(
                    serviceID: candidate.serviceID,
                    snapshot: candidate.snapshot,
                    mode: .logEvents,
                    openResult: result
                )
            )
        }

        let session = ActiveSession(
            device: candidate.device,
            serviceID: candidate.serviceID,
            snapshot: candidate.snapshot,
            mode: .logEvents
        )
        activeSessions[candidate.serviceID] = session
        return .active(session)
    }

    private func evaluation(for target: BlockerTarget) -> TargetEvaluation {
        switch target {
        case .bluetoothAddress(let address):
            guard let targetDevice = bluetoothResolver.resolve(address: address) else {
                return TargetEvaluation(
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
        let devices = hidEnvironment.currentDevices()
        guard !devices.isEmpty else {
            return TargetEvaluation(
                checkResult: BlockerCheckResult(
                    target: target,
                    matchedDevice: nil,
                    message: noDevicesMessage
                ),
                matchedCandidates: nil
            )
        }

        var matchedCandidates: [MatchedCandidate] = []
        var rejectionMessages: [String] = []

        for device in devices {
            let snapshot = device.snapshot
            let matchResult = matcher.match(device: snapshot, target: target)

            switch matchResult {
            case .matched:
                guard device.serviceID != IO_OBJECT_NULL else {
                    rejectionMessages.append(
                        rejectionMessage(
                            for: snapshot,
                            reason: "The HID endpoint matched, but its IORegistry service could not be opened."
                        )
                    )
                    continue
                }

                matchedCandidates.append(
                    MatchedCandidate(
                        device: device,
                        serviceID: device.serviceID,
                        snapshot: snapshot
                    )
                )

            case .rejected(let reason):
                rejectionMessages.append(rejectionMessage(for: snapshot, reason: reason))
            }
        }

        guard let firstMatch = matchedCandidates.first else {
            return TargetEvaluation(
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
            checkResult: BlockerCheckResult(
                target: target,
                matchedDevice: firstMatch.snapshot,
                message: "Found matching media-control HID candidate for \(target.summary).",
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

    private func statusForActiveSession(
        snapshot: HIDDeviceSnapshot,
        target: BlockerTarget,
        mode: BlockerOperationMode
    ) -> BlockerStatus {
        let label = activeDeviceLabel(for: snapshot, target: target)

        switch mode {
        case .block:
            return .blocking(label)
        case .logEvents:
            return .observing(label)
        }
    }

    private func activeDeviceLabel(for snapshot: HIDDeviceSnapshot, target: BlockerTarget) -> String {
        switch target {
        case .bluetoothAddress(let address):
            return snapshot.product ?? snapshot.serialNumber ?? address.rawValue
        case .genericAudioHeadset:
            let summary = snapshot.displaySummary
            return summary.isEmpty ? (snapshot.product ?? target.summary) : summary
        }
    }

    private func activationFailureMessage(
        target: BlockerTarget,
        mode: BlockerOperationMode,
        failures: [ActivationFailure]
    ) -> String {
        let modeDescription = switch mode {
        case .block:
            "seize"
        case .logEvents:
            "open for event logging"
        }

        let details = failures.map { failure in
            "\(failure.deviceSummary): \(modeDescription) failed with \(formatIOReturn(failure.openResult))."
        }
        .joined(separator: " ")

        return "Matched \(target.summary), but could not activate any media-control HID endpoint. \(details)"
    }

    private func formatIOReturn(_ result: IOReturn) -> String {
        let hex = String(UInt32(bitPattern: result), radix: 16, uppercase: true)
        return "\(result) (0x\(hex))"
    }

    private func releaseDevice(serviceID: io_service_t) {
        guard let session = activeSessions.removeValue(forKey: serviceID) else {
            return
        }

        if session.mode == .logEvents {
            session.device.setInputValueHandler(nil)
            session.device.unscheduleFromMainRunLoop()
        }

        session.device.close()
    }

    private func releaseAllActiveSessions() {
        let serviceIDs = Array(activeSessions.keys)
        for serviceID in serviceIDs {
            releaseDevice(serviceID: serviceID)
        }
    }

    private func publishStatus(_ status: BlockerStatus) {
        statusDidChange?(status)
    }
}

private struct ActiveSession {
    let device: HIDDeviceControlling
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot
    let mode: BlockerOperationMode
}

private struct ActivationFailure {
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot
    let mode: BlockerOperationMode
    let openResult: IOReturn

    var deviceSummary: String {
        let summary = snapshot.displaySummary
        guard !summary.isEmpty else {
            return "service \(serviceID)"
        }

        return summary
    }
}

private enum ActivationResult {
    case active(ActiveSession)
    case failed(ActivationFailure)
}

private struct MatchedCandidate {
    let device: HIDDeviceControlling
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot
}

private struct TargetEvaluation {
    let checkResult: BlockerCheckResult
    let matchedCandidates: [MatchedCandidate]?
}
