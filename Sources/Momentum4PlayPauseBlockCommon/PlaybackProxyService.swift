import AVFoundation
import Foundation
import IOKit.hid
import MediaPlayer

public enum AllowedForwardSourceMode: String, CaseIterable, Equatable, Sendable {
    case specificProductName = "specific-product-name"
    case anyKeyboard = "any-keyboard"
    case anyHID = "any-hid"

    public var requiresProductName: Bool {
        self == .specificProductName
    }

    public var displayName: String {
        switch self {
        case .specificProductName:
            return "Specific device name"
        case .anyKeyboard:
            return "All keyboards"
        case .anyHID:
            return "All HID"
        }
    }
}

public struct PlaybackProxyConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let allowedForwardSourceMode: AllowedForwardSourceMode
    public let allowedForwardSourceProductName: String

    public init(
        enabled: Bool,
        allowedForwardSourceMode: AllowedForwardSourceMode = .anyHID,
        allowedForwardSourceProductName: String = ""
    ) {
        self.enabled = enabled
        self.allowedForwardSourceMode = allowedForwardSourceMode
        self.allowedForwardSourceProductName = allowedForwardSourceProductName
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PlaybackProxyStatus: Equatable, Sendable {
    case disabled
    case requestingPermissions
    case inputMonitoringDenied
    case musicAutomationDenied
    case active(String)
    case error(String)

    public var message: String {
        switch self {
        case .disabled:
            return "Blocking is disabled."
        case .requestingPermissions:
            return "macOS is requesting Input Monitoring and Apple Music control permission."
        case .inputMonitoringDenied:
            return "Input Monitoring is required. Allow the app in System Settings > Privacy & Security > Input Monitoring. If the proxy still does not activate after granting it, relaunch once."
        case .musicAutomationDenied:
            return "Apple Music control permission is required. Allow the app in System Settings > Privacy & Security > Automation. If the proxy still does not activate after granting it, relaunch once."
        case .active(let sourceDescription):
            return "Blocking remote play/pause and forwarding matching HID play/pause from \(sourceDescription) to Apple Music."
        case .error(let message):
            return message
        }
    }
}

@MainActor
public protocol PlaybackProxyControlling: AnyObject {
    var statusDidChange: ((PlaybackProxyStatus) -> Void)? { get set }
    var sourceCaptureDidResolve: ((String) -> Void)? { get set }
    var sourceCaptureDidFail: ((String) -> Void)? { get set }

    func apply(configuration: PlaybackProxyConfiguration)
    @discardableResult
    func beginSourceCapture() -> Bool
    func cancelSourceCapture()
}

private struct PendingForwardSourcePress {
    let observedAt: Date
    let deviceLabel: String
}

enum ProxyRemoteCommand: String {
    case togglePlayPause = "togglePlayPause"
    case play
    case pause

    var appleScriptVerb: String {
        switch self {
        case .togglePlayPause:
            return "playpause"
        case .play:
            return "play"
        case .pause:
            return "pause"
        }
    }
}

enum AppleMusicPermissionResult: Equatable {
    case granted
    case denied
    case error(String)
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

@MainActor
protocol AppleMusicControlling: AnyObject {
    func requestPermission() -> AppleMusicPermissionResult
    func send(command: ProxyRemoteCommand) -> Bool
}

@MainActor
private final class AppleMusicController: AppleMusicControlling {
    func requestPermission() -> AppleMusicPermissionResult {
        let result = runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Music\" to get player state as string"]
        )

        guard result.status != 0 else {
            return .granted
        }

        let combinedOutput = [result.stderr, result.stdout]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")

        if combinedOutput.localizedCaseInsensitiveContains("not authorized")
            || combinedOutput.contains("-1743")
        {
            return .denied
        }

        let message =
            combinedOutput.isEmpty
            ? "Could not confirm Apple Music automation permission."
            : combinedOutput
        return .error(message)
    }

    func send(command: ProxyRemoteCommand) -> Bool {
        let result = runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Music\" to \(command.appleScriptVerb)"]
        )

        return result.status == 0
    }

    private func runProcess(executablePath: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let stderrData = standardError.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

@MainActor
protocol NowPlayingProxyRuntimeControlling: AnyObject {
    func start(commandHandler: @escaping (ProxyRemoteCommand) -> Void) -> Bool
    func stop()
    func reassertNowPlayingState()
}

@MainActor
private final class SystemNowPlayingProxyRuntime: NowPlayingProxyRuntimeControlling {
    private static let ownershipKeepaliveInterval: TimeInterval = 1

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var remoteCommandTokens: [(command: MPRemoteCommand, token: Any)] = []
    private var ownershipKeepaliveTimer: Timer?
    private var playbackStartedAt: Date?
    private var isStarted = false

    func start(commandHandler: @escaping (ProxyRemoteCommand) -> Void) -> Bool {
        guard !isStarted else {
            return true
        }

        do {
            try startSilentLoop()
        } catch {
            stop()
            return false
        }

        playbackStartedAt = Date()
        publishNowPlayingState()
        startOwnershipKeepalive()
        installRemoteCommandHandlers(commandHandler: commandHandler)
        isStarted = true
        return true
    }

    func stop() {
        for token in remoteCommandTokens {
            token.command.removeTarget(token.token)
        }
        remoteCommandTokens.removeAll(keepingCapacity: false)

        ownershipKeepaliveTimer?.invalidate()
        ownershipKeepaliveTimer = nil

        playerNode.stop()
        engine.stop()

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = nil
        nowPlayingCenter.playbackState = .stopped
        playbackStartedAt = nil
        isStarted = false
    }

    func reassertNowPlayingState() {
        guard isStarted else {
            return
        }

        publishNowPlayingState()
    }

    private func startSilentLoop() throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(
                domain: "Momentum4PlayPauseBlockCommon.SystemNowPlayingProxyRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a silent PCM buffer."]
            )
        }

        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(repeating: 0, count: Int(frameCount))
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        playerNode.volume = 0
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)

        try engine.start()
        playerNode.play()
    }

    private func publishNowPlayingState() {
        let elapsedPlaybackTime = playbackStartedAt.map { startedAt in
            max(0, Date().timeIntervalSince(startedAt))
        } ?? 0
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Momentum4 Proxy",
            MPMediaItemPropertyArtist: "Momentum4PlayPauseBlock",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedPlaybackTime,
            MPMediaItemPropertyPlaybackDuration: 60 * 60 * 24,
        ]
        nowPlayingCenter.playbackState = .playing
    }

    private func startOwnershipKeepalive() {
        ownershipKeepaliveTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.ownershipKeepaliveInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishNowPlayingState()
            }
        }
        ownershipKeepaliveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installRemoteCommandHandlers(commandHandler: @escaping (ProxyRemoteCommand) -> Void) {
        let commandCenter = MPRemoteCommandCenter.shared()
        installHandler(
            for: commandCenter.togglePlayPauseCommand,
            command: .togglePlayPause,
            commandHandler: commandHandler
        )
        installHandler(for: commandCenter.playCommand, command: .play, commandHandler: commandHandler)
        installHandler(
            for: commandCenter.pauseCommand,
            command: .pause,
            commandHandler: commandHandler
        )
    }

    private func installHandler(
        for command: MPRemoteCommand,
        command proxyCommand: ProxyRemoteCommand,
        commandHandler: @escaping (ProxyRemoteCommand) -> Void
    ) {
        command.isEnabled = true
        let token = command.addTarget { _ in
            if Thread.isMainThread {
                commandHandler(proxyCommand)
            } else {
                DispatchQueue.main.async {
                    commandHandler(proxyCommand)
                }
            }
            return .success
        }
        remoteCommandTokens.append((command: command, token: token))
    }
}

private struct ObservedDeviceSession {
    let device: HIDDeviceControlling
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot
}

@MainActor
public final class PlaybackProxyService: PlaybackProxyControlling {
    public var statusDidChange: ((PlaybackProxyStatus) -> Void)?
    public var sourceCaptureDidResolve: ((String) -> Void)?
    public var sourceCaptureDidFail: ((String) -> Void)?

    private let hidEnvironment: HIDEnvironment
    private let appleMusicController: AppleMusicControlling
    private let proxyFactory: () -> NowPlayingProxyRuntimeControlling
    private let ownershipRecoveryDelays: [TimeInterval]

    private var configuration = PlaybackProxyConfiguration(enabled: false)
    private var observedDeviceSessions: [io_service_t: ObservedDeviceSession] = [:]
    private var managerIsOpen = false
    private var musicAutomationGranted = false
    private var sourceCaptureIsActive = false
    private var proxyRuntime: NowPlayingProxyRuntimeControlling?
    private var pendingForwardSourcePress: PendingForwardSourcePress?
    private var lastPublishedStatus: PlaybackProxyStatus?
    private var ownershipRecoveryTasks: [Task<Void, Never>] = []

    public convenience init() {
        self.init(
            hidEnvironment: SystemHIDEnvironment(),
            appleMusicController: AppleMusicController(),
            proxyFactory: { SystemNowPlayingProxyRuntime() }
        )
    }

    init(
        hidEnvironment: HIDEnvironment,
        appleMusicController: AppleMusicControlling,
        proxyFactory: @escaping () -> NowPlayingProxyRuntimeControlling,
        ownershipRecoveryDelays: [TimeInterval] = [0.08, 0.25, 0.6]
    ) {
        self.hidEnvironment = hidEnvironment
        self.appleMusicController = appleMusicController
        self.proxyFactory = proxyFactory
        self.ownershipRecoveryDelays = ownershipRecoveryDelays

        hidEnvironment.devicesDidChange = { [weak self] in
            Task { @MainActor in
                self?.refreshObservedDevices()
            }
        }
    }

    public func apply(configuration: PlaybackProxyConfiguration) {
        self.configuration = PlaybackProxyConfiguration(
            enabled: configuration.enabled,
            allowedForwardSourceMode: configuration.allowedForwardSourceMode,
            allowedForwardSourceProductName: configuration.allowedForwardSourceProductName
        )

        if !configuration.enabled {
            pendingForwardSourcePress = nil
        }

        reconcileState()
    }

    @discardableResult
    public func beginSourceCapture() -> Bool {
        sourceCaptureIsActive = true
        reconcileState()

        return managerIsOpen
    }

    public func cancelSourceCapture() {
        guard sourceCaptureIsActive else {
            return
        }

        sourceCaptureIsActive = false
        refreshObservedDevices()

        if !configuration.enabled {
            publishStatus(.disabled)
        }
    }

    private func reconcileState() {
        if !configuration.enabled && !sourceCaptureIsActive {
            stopProxyIfNeeded()
            releaseAllObservedDevices()
            closeManagerIfNeeded()
            publishStatus(.disabled)
            return
        }

        publishStatus(.requestingPermissions)

        let inputMonitoringGranted = ensureListenPermission()

        if !inputMonitoringGranted {
            stopProxyIfNeeded()
            releaseAllObservedDevices()
            closeManagerIfNeeded()

            sourceCaptureIsActive = false
            publishStatus(.inputMonitoringDenied)
            return
        }

        let automationPermissionResult: AppleMusicPermissionResult
        if configuration.enabled {
            automationPermissionResult = ensureMusicAutomationPermission()
        } else {
            automationPermissionResult = .granted
        }

        switch automationPermissionResult {
        case .granted:
            break
        case .denied:
            stopProxyIfNeeded()
            if !sourceCaptureIsActive {
                releaseAllObservedDevices()
                closeManagerIfNeeded()
            }
            publishStatus(.musicAutomationDenied)
            return
        case .error(let message):
            stopProxyIfNeeded()
            if !sourceCaptureIsActive {
                releaseAllObservedDevices()
                closeManagerIfNeeded()
            }
            publishStatus(.error(message))
            return
        }

        guard openManagerIfNeeded() else {
            stopProxyIfNeeded()
            publishStatus(.error("The HID manager could not be opened."))
            return
        }

        refreshObservedDevices()

        if configuration.enabled {
            guard startProxyIfNeeded() else {
                publishStatus(
                    .error("The Apple Music proxy could not be started.")
                )
                return
            }

            publishStatus(.active(activeSourceDescription))
        } else {
            stopProxyIfNeeded()
            publishStatus(.disabled)
        }
    }

    private var activeSourceDescription: String {
        switch configuration.allowedForwardSourceMode {
        case .specificProductName:
            return configuration.allowedForwardSourceProductName
        case .anyKeyboard:
            return "all keyboards"
        case .anyHID:
            return "all HID sources"
        }
    }

    private func ensureListenPermission() -> Bool {
        switch hidEnvironment.checkListenAccess() {
        case kIOHIDAccessTypeGranted:
            return true
        case kIOHIDAccessTypeDenied, kIOHIDAccessTypeUnknown:
            _ = hidEnvironment.requestListenAccess()
            return hidEnvironment.checkListenAccess() == kIOHIDAccessTypeGranted
        default:
            return false
        }
    }

    private func ensureMusicAutomationPermission() -> AppleMusicPermissionResult {
        if musicAutomationGranted {
            return .granted
        }

        let result = appleMusicController.requestPermission()
        if result == .granted {
            musicAutomationGranted = true
        }
        return result
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

    private func startProxyIfNeeded() -> Bool {
        if let proxyRuntime {
            return proxyRuntime.start(commandHandler: { [weak self] command in
                self?.handleRemoteCommand(command)
            })
        }

        let proxyRuntime = proxyFactory()
        guard proxyRuntime.start(commandHandler: { [weak self] command in
            self?.handleRemoteCommand(command)
        }) else {
            return false
        }

        self.proxyRuntime = proxyRuntime
        return true
    }

    private func stopProxyIfNeeded() {
        cancelOwnershipRecoveryTasks()
        proxyRuntime?.stop()
        proxyRuntime = nil
    }

    private func refreshObservedDevices() {
        guard managerIsOpen else {
            return
        }

        let devices = hidEnvironment.currentDevices()
        let desiredDevices = devices.filter { shouldObserveDevice($0.snapshot) }
        let desiredServiceIDs = Set(desiredDevices.map(\.serviceID))

        for serviceID in Set(observedDeviceSessions.keys).subtracting(desiredServiceIDs) {
            releaseObservedDevice(serviceID: serviceID)
        }

        for device in desiredDevices where observedDeviceSessions[device.serviceID] == nil {
            observeDevice(device)
        }
    }

    private func shouldObserveDevice(_ snapshot: HIDDeviceSnapshot) -> Bool {
        if sourceCaptureIsActive {
            return true
        }

        guard configuration.enabled else {
            return false
        }

        switch configuration.allowedForwardSourceMode {
        case .specificProductName:
            return snapshot.matchesProductName(configuration.allowedForwardSourceProductName)
        case .anyKeyboard:
            return snapshot.isKeyboardInterface
        case .anyHID:
            return true
        }
    }

    private func matchesForwardSource(_ snapshot: HIDDeviceSnapshot) -> Bool {
        switch configuration.allowedForwardSourceMode {
        case .specificProductName:
            return snapshot.matchesProductName(configuration.allowedForwardSourceProductName)
        case .anyKeyboard:
            return snapshot.isKeyboardInterface
        case .anyHID:
            return true
        }
    }

    private func observeDevice(_ device: HIDDeviceControlling) {
        device.setInputValueHandler { [weak self] event in
            Task { @MainActor in
                self?.handleInputEvent(event)
            }
        }
        device.scheduleWithMainRunLoop()

        let openResult = device.open(options: IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            device.unscheduleFromMainRunLoop()
            device.setInputValueHandler(nil)
            publishStatus(.error("A HID source could not be opened for observation."))
            return
        }

        observedDeviceSessions[device.serviceID] = ObservedDeviceSession(
            device: device,
            serviceID: device.serviceID,
            snapshot: device.snapshot
        )
    }

    private func releaseObservedDevice(serviceID: io_service_t) {
        guard let session = observedDeviceSessions.removeValue(forKey: serviceID) else {
            return
        }

        session.device.setInputValueHandler(nil)
        session.device.unscheduleFromMainRunLoop()
        session.device.close()
    }

    private func releaseAllObservedDevices() {
        for serviceID in Array(observedDeviceSessions.keys) {
            releaseObservedDevice(serviceID: serviceID)
        }
    }

    private func handleInputEvent(_ event: HIDInputEvent) {
        if sourceCaptureIsActive {
            handleSourceCaptureEvent(event)
        }

        guard configuration.enabled else {
            return
        }

        guard event.value != 0, isForwardTriggerEvent(event), matchesForwardSource(event.device) else {
            return
        }

        pendingForwardSourcePress = PendingForwardSourcePress(
            observedAt: Date(),
            deviceLabel: event.device.preferredSourceLabel
        )
    }

    private func handleSourceCaptureEvent(_ event: HIDInputEvent) {
        guard sourceCaptureIsActive, event.value != 0 else {
            return
        }

        let capturedProductName = event.device.product?.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceCaptureIsActive = false

        guard let capturedProductName, !capturedProductName.isEmpty else {
            sourceCaptureDidFail?(
                "Could not read a product name from that source. Try a different key."
            )
            refreshObservedDevices()
            if !configuration.enabled {
                releaseAllObservedDevices()
                closeManagerIfNeeded()
                publishStatus(.disabled)
            } else {
                publishStatus(.active(activeSourceDescription))
            }
            return
        }

        sourceCaptureDidResolve?(capturedProductName)
        refreshObservedDevices()

        if !configuration.enabled {
            releaseAllObservedDevices()
            closeManagerIfNeeded()
            publishStatus(.disabled)
        }
    }

    private func handleRemoteCommand(_ command: ProxyRemoteCommand) {
        guard configuration.enabled else {
            return
        }

        guard consumeRecentForwardSourcePress() != nil else {
            return
        }

        guard appleMusicController.send(command: command) else {
            musicAutomationGranted = false
            publishStatus(.error("The proxy could not forward a command to Apple Music."))
            return
        }

        refreshProxyOwnershipAfterForward()
        publishStatus(.active(activeSourceDescription))
    }

    private func refreshProxyOwnershipAfterForward() {
        guard configuration.enabled else {
            return
        }

        let hadRuntime = proxyRuntime != nil
        if hadRuntime {
            proxyRuntime?.stop()
            proxyRuntime = nil
        }

        if !startProxyIfNeeded() {
            publishStatus(.error("The Apple Music proxy could not be restarted after forwarding."))
            return
        }

        scheduleOwnershipRecoveryBursts()
    }

    private func scheduleOwnershipRecoveryBursts() {
        cancelOwnershipRecoveryTasks()
        proxyRuntime?.reassertNowPlayingState()

        for delay in ownershipRecoveryDelays {
            let task = Task { @MainActor [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    await Task.yield()
                }

                guard !Task.isCancelled else {
                    return
                }

                self?.proxyRuntime?.reassertNowPlayingState()
            }
            ownershipRecoveryTasks.append(task)
        }
    }

    private func cancelOwnershipRecoveryTasks() {
        for task in ownershipRecoveryTasks {
            task.cancel()
        }
        ownershipRecoveryTasks.removeAll(keepingCapacity: false)
    }

    private func consumeRecentForwardSourcePress() -> PendingForwardSourcePress? {
        guard let pendingForwardSourcePress else {
            return nil
        }

        let age = Date().timeIntervalSince(pendingForwardSourcePress.observedAt)
        if age < 0 || age > 0.05 {
            self.pendingForwardSourcePress = nil
            return nil
        }

        self.pendingForwardSourcePress = nil
        return pendingForwardSourcePress
    }

    private func isForwardTriggerEvent(_ event: HIDInputEvent) -> Bool {
        switch (event.usagePage, event.usage) {
        case (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_PlayOrPause)),
            (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_Play)),
            (Int(kHIDPage_Consumer), Int(kHIDUsage_Csmr_Pause)),
            (Int(kHIDPage_Telephony), Int(kHIDUsage_Tfon_HookSwitch)),
            (Int(kHIDPage_GenericDesktop), Int(kHIDUsage_GD_SystemMenu)):
            return true
        default:
            return false
        }
    }

    private func publishStatus(_ status: PlaybackProxyStatus) {
        guard lastPublishedStatus != status else {
            return
        }

        lastPublishedStatus = status
        statusDidChange?(status)
    }
}
