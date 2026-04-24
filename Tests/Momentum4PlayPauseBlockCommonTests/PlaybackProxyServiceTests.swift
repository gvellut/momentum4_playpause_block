@testable import Momentum4PlayPauseBlockCommon
import Foundation
import IOKit.hid
import Testing

@MainActor
struct PlaybackProxyServiceTests {
    @Test
    func correlatedPlayPauseForwardsExactlyOnce() async {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 1, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [device]
        let appleMusic = FakeAppleMusicController()
        let runtime = FakeNowPlayingProxyRuntime()
        let service = makeService(
            environment: environment,
            appleMusic: appleMusic,
            runtime: runtime
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 1
        )
        await Task.yield()
        runtime.emit(.togglePlayPause)
        runtime.emit(.togglePlayPause)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(appleMusic.sentCommands == [.togglePlayPause])
        #expect(runtime.reassertNowPlayingStateCalls == 3)
    }

    @Test
    func nonCorrelatedRemoteCommandIsSwallowed() {
        let environment = FakeHIDEnvironment()
        environment.devices = [FakeHIDDevice(serviceID: 2, snapshot: .keyboard(product: "Keychron K1 Pro"))]
        let appleMusic = FakeAppleMusicController()
        let runtime = FakeNowPlayingProxyRuntime()
        let service = makeService(
            environment: environment,
            appleMusic: appleMusic,
            runtime: runtime
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        runtime.emit(.togglePlayPause)

        #expect(appleMusic.sentCommands.isEmpty)
    }

    @Test
    func specificProductNameMatchingIsCaseInsensitive() async {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 3, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [device]
        let appleMusic = FakeAppleMusicController()
        let runtime = FakeNowPlayingProxyRuntime()
        let service = makeService(
            environment: environment,
            appleMusic: appleMusic,
            runtime: runtime
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .specificProductName,
                allowedForwardSourceProductName: "keychron k1 pro"
            )
        )
        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 2
        )
        await Task.yield()
        runtime.emit(.togglePlayPause)

        #expect(appleMusic.sentCommands == [.togglePlayPause])
    }

    @Test
    func anyKeyboardIgnoresNonKeyboardSource() {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 4, snapshot: .mouse(product: "USB Receiver"))
        environment.devices = [device]
        let appleMusic = FakeAppleMusicController()
        let runtime = FakeNowPlayingProxyRuntime()
        let service = makeService(
            environment: environment,
            appleMusic: appleMusic,
            runtime: runtime
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 3
        )
        runtime.emit(.togglePlayPause)

        #expect(appleMusic.sentCommands.isEmpty)
    }

    @Test
    func anyHIDAcceptsNonKeyboardSource() async {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 5, snapshot: .mouse(product: "USB Receiver"))
        environment.devices = [device]
        let appleMusic = FakeAppleMusicController()
        let runtime = FakeNowPlayingProxyRuntime()
        let service = makeService(
            environment: environment,
            appleMusic: appleMusic,
            runtime: runtime
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID
            )
        )
        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 4
        )
        await Task.yield()
        runtime.emit(.togglePlayPause)

        #expect(appleMusic.sentCommands == [.togglePlayPause])
    }

    @Test
    func disableThenReenableStartsFreshRuntimeAgain() {
        let environment = FakeHIDEnvironment()
        let appleMusic = FakeAppleMusicController()
        let firstRuntime = FakeNowPlayingProxyRuntime()
        let secondRuntime = FakeNowPlayingProxyRuntime()
        var runtimes = [firstRuntime, secondRuntime]

        let service = PlaybackProxyService(
            hidEnvironment: environment,
            appleMusicController: appleMusic,
            proxyFactory: { runtimes.removeFirst() }
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID
            )
        )
        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: false,
                allowedForwardSourceMode: .anyHID
            )
        )
        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID
            )
        )

        #expect(firstRuntime.startCalls == 1)
        #expect(firstRuntime.stopCalls == 1)
        #expect(secondRuntime.startCalls == 1)
    }

    @Test
    func forwardedCommandRestartsProxyRuntimeToReclaimOwnership() async {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 6, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [device]
        let appleMusic = FakeAppleMusicController()
        let firstRuntime = FakeNowPlayingProxyRuntime()
        let secondRuntime = FakeNowPlayingProxyRuntime()
        var runtimes = [firstRuntime, secondRuntime]

        let service = PlaybackProxyService(
            hidEnvironment: environment,
            appleMusicController: appleMusic,
            proxyFactory: { runtimes.removeFirst() },
            ownershipRecoveryDelays: [0.001, 0.002]
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 6
        )
        await Task.yield()
        firstRuntime.emit(.togglePlayPause)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(appleMusic.sentCommands == [.togglePlayPause])
        #expect(firstRuntime.stopCalls == 1)
        #expect(secondRuntime.startCalls == 1)
        #expect(secondRuntime.reassertNowPlayingStateCalls == 3)
    }

    @Test
    func timedOwnershipMonitorTriggerRestartsProxyRuntime() async {
        let ownershipMonitor = FakePlaybackProxyOwnershipMonitor()
        let firstRuntime = FakeNowPlayingProxyRuntime()
        let secondRuntime = FakeNowPlayingProxyRuntime()
        var runtimes = [firstRuntime, secondRuntime]

        let service = PlaybackProxyService(
            hidEnvironment: FakeHIDEnvironment(),
            appleMusicController: FakeAppleMusicController(),
            proxyFactory: { runtimes.removeFirst() },
            ownershipMonitorFactory: { ownershipMonitor },
            ownershipRecoveryDelays: [0.001, 0.002],
            ownershipReclaimCooldown: 0.05
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID,
                pollInterval: 15
            )
        )
        ownershipMonitor.trigger(.timedBackstopTick(15))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(ownershipMonitor.startConfigurations == [
            PlaybackProxyOwnershipMonitoringConfiguration(
                eventDrivenReclaimEnabled: false,
                pollInterval: 15
            )
        ])
        #expect(firstRuntime.stopCalls == 1)
        #expect(secondRuntime.startCalls == 1)
        #expect(secondRuntime.reassertNowPlayingStateCalls == 3)
    }

    @Test
    func eventDrivenOwnershipMonitorTriggerRestartsProxyRuntime() async {
        let ownershipMonitor = FakePlaybackProxyOwnershipMonitor()
        let firstRuntime = FakeNowPlayingProxyRuntime()
        let secondRuntime = FakeNowPlayingProxyRuntime()
        var runtimes = [firstRuntime, secondRuntime]

        let service = PlaybackProxyService(
            hidEnvironment: FakeHIDEnvironment(),
            appleMusicController: FakeAppleMusicController(),
            proxyFactory: { runtimes.removeFirst() },
            ownershipMonitorFactory: { ownershipMonitor },
            ownershipRecoveryDelays: [0.001, 0.002],
            ownershipReclaimCooldown: 0.05
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID,
                eventDrivenReclaimEnabled: true
            )
        )
        ownershipMonitor.trigger(.mediaRemoteNotification("com.apple.MediaRemote.test"))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(ownershipMonitor.startConfigurations == [
            PlaybackProxyOwnershipMonitoringConfiguration(
                eventDrivenReclaimEnabled: true,
                pollInterval: nil
            )
        ])
        #expect(firstRuntime.stopCalls == 1)
        #expect(secondRuntime.startCalls == 1)
        #expect(secondRuntime.reassertNowPlayingStateCalls == 3)
    }

    @Test
    func clusteredOwnershipMonitorTriggersAreDebounced() async {
        let ownershipMonitor = FakePlaybackProxyOwnershipMonitor()
        let firstRuntime = FakeNowPlayingProxyRuntime()
        let secondRuntime = FakeNowPlayingProxyRuntime()
        let thirdRuntime = FakeNowPlayingProxyRuntime()
        var runtimes = [firstRuntime, secondRuntime, thirdRuntime]

        let service = PlaybackProxyService(
            hidEnvironment: FakeHIDEnvironment(),
            appleMusicController: FakeAppleMusicController(),
            proxyFactory: { runtimes.removeFirst() },
            ownershipMonitorFactory: { ownershipMonitor },
            ownershipRecoveryDelays: [0.001, 0.002],
            ownershipReclaimCooldown: 1
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID,
                eventDrivenReclaimEnabled: true
            )
        )
        ownershipMonitor.trigger(.mediaRemoteNotification("com.apple.MediaRemote.test"))
        ownershipMonitor.trigger(.mediaRemoteNotification("com.apple.MediaRemote.test"))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(firstRuntime.stopCalls == 1)
        #expect(secondRuntime.startCalls == 1)
        #expect(thirdRuntime.startCalls == 0)
    }

    @Test
    func missingRemoteCommandAfterAllowedHIDPressReclaimsOwnership() async {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 12, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [device]
        let firstRuntime = FakeNowPlayingProxyRuntime()
        let secondRuntime = FakeNowPlayingProxyRuntime()
        var runtimes = [firstRuntime, secondRuntime]

        let service = PlaybackProxyService(
            hidEnvironment: environment,
            appleMusicController: FakeAppleMusicController(),
            proxyFactory: { runtimes.removeFirst() },
            ownershipRecoveryDelays: [0.001, 0.002],
            forwardSourceCorrelationWindow: 0.01,
            ownershipReclaimCooldown: 0.05
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 12
        )
        try? await Task.sleep(for: .milliseconds(30))

        #expect(firstRuntime.stopCalls == 1)
        #expect(secondRuntime.startCalls == 1)
        #expect(secondRuntime.reassertNowPlayingStateCalls == 3)
    }

    @Test
    func remoteCommandWithinCorrelationWindowCancelsTimeoutRecovery() async {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 13, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [device]
        let appleMusic = FakeAppleMusicController()
        let firstRuntime = FakeNowPlayingProxyRuntime()
        let secondRuntime = FakeNowPlayingProxyRuntime()
        let thirdRuntime = FakeNowPlayingProxyRuntime()
        var runtimes = [firstRuntime, secondRuntime, thirdRuntime]

        let service = PlaybackProxyService(
            hidEnvironment: environment,
            appleMusicController: appleMusic,
            proxyFactory: { runtimes.removeFirst() },
            ownershipRecoveryDelays: [0.001, 0.002],
            forwardSourceCorrelationWindow: 0.01,
            ownershipReclaimCooldown: 0.05
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 13
        )
        await Task.yield()
        firstRuntime.emit(.togglePlayPause)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(appleMusic.sentCommands == [.togglePlayPause])
        #expect(firstRuntime.stopCalls == 1)
        #expect(secondRuntime.startCalls == 1)
        #expect(thirdRuntime.startCalls == 0)
    }

    @Test
    func ownershipMonitoringDisabledLeavesCurrentBehaviorUnchanged() async {
        let ownershipMonitor = FakePlaybackProxyOwnershipMonitor()
        let runtime = FakeNowPlayingProxyRuntime()
        let service = PlaybackProxyService(
            hidEnvironment: FakeHIDEnvironment(),
            appleMusicController: FakeAppleMusicController(),
            proxyFactory: { runtime },
            ownershipMonitorFactory: { ownershipMonitor },
            ownershipRecoveryDelays: [0.001, 0.002]
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID
            )
        )
        ownershipMonitor.trigger(.timedBackstopTick(15))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(ownershipMonitor.startConfigurations.isEmpty)
        #expect(runtime.stopCalls == 0)
        #expect(runtime.startCalls == 1)
        #expect(runtime.reassertNowPlayingStateCalls == 0)
    }

    @Test
    func sleepAndWakeSignalsEmitDiagnostics() async {
        let ownershipMonitor = FakePlaybackProxyOwnershipMonitor()
        let runtime = FakeNowPlayingProxyRuntime()
        let service = PlaybackProxyService(
            hidEnvironment: FakeHIDEnvironment(),
            appleMusicController: FakeAppleMusicController(),
            proxyFactory: { runtime },
            ownershipMonitorFactory: { ownershipMonitor },
            ownershipRecoveryDelays: [0.001, 0.002],
            ownershipReclaimCooldown: 0.05
        )
        var diagnostics: [PlaybackProxyDiagnosticEvent] = []
        service.diagnosticDidEmit = { diagnostics.append($0) }

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyHID,
                eventDrivenReclaimEnabled: true
            )
        )
        ownershipMonitor.trigger(.systemWillSleep)
        ownershipMonitor.trigger(.screensDidSleep)
        ownershipMonitor.trigger(.systemDidWake)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(diagnostics.contains(.systemWillSleep))
        #expect(diagnostics.contains(.screensDidSleep))
        #expect(diagnostics.contains(.systemDidWake))
        #expect(diagnostics.contains(.ownershipReclaimStarted(.systemDidWake)))
        #expect(diagnostics.contains(.ownershipReclaimSucceeded(.systemDidWake)))
    }

    @Test
    func sourceCaptureObservesOnlyKeyboardInterfaces() {
        let environment = FakeHIDEnvironment()
        let mouse = FakeHIDDevice(serviceID: 7, snapshot: .mouse(product: "USB Receiver"))
        let keyboard = FakeHIDDevice(serviceID: 8, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [mouse, keyboard]
        let service = makeService(
            environment: environment,
            appleMusic: FakeAppleMusicController(),
            runtime: FakeNowPlayingProxyRuntime()
        )

        #expect(service.beginSourceCapture())
        #expect(!mouse.isObservingInput)
        #expect(keyboard.isObservingInput)
    }

    @Test
    func sourceCaptureIgnoresNoisyNonKeyboardInputUntilAKeyboardKeyIsPressed() async {
        let environment = FakeHIDEnvironment()
        let mouse = FakeHIDDevice(serviceID: 9, snapshot: .mouse(product: "USB Receiver"))
        let keyboard = FakeHIDDevice(serviceID: 10, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [mouse, keyboard]
        let service = makeService(
            environment: environment,
            appleMusic: FakeAppleMusicController(),
            runtime: FakeNowPlayingProxyRuntime()
        )
        var capturedProductNames: [String] = []
        service.sourceCaptureDidResolve = { capturedProductNames.append($0) }

        #expect(service.beginSourceCapture())

        mouse.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 9
        )
        await Task.yield()
        #expect(capturedProductNames.isEmpty)

        keyboard.emitInput(
            usagePage: Int(kHIDPage_KeyboardOrKeypad),
            usage: 0x04,
            value: 1,
            timestamp: 10
        )
        await Task.yield()
        #expect(capturedProductNames == ["Keychron K1 Pro"])
    }

    @Test
    func disablingStopsObservingPreviouslyTrackedDevices() {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 11, snapshot: .keyboard(product: "Keychron K1 Pro"))
        environment.devices = [device]
        let service = makeService(
            environment: environment,
            appleMusic: FakeAppleMusicController(),
            runtime: FakeNowPlayingProxyRuntime()
        )

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: true,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        #expect(device.isObservingInput)

        service.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: false,
                allowedForwardSourceMode: .anyKeyboard
            )
        )
        #expect(!device.isObservingInput)
    }

    private func makeService(
        environment: FakeHIDEnvironment,
        appleMusic: FakeAppleMusicController,
        runtime: FakeNowPlayingProxyRuntime,
        ownershipMonitor: FakePlaybackProxyOwnershipMonitor = FakePlaybackProxyOwnershipMonitor(),
        forwardSourceCorrelationWindow: TimeInterval = 0.15,
        ownershipReclaimCooldown: TimeInterval = 1
    ) -> PlaybackProxyService {
        PlaybackProxyService(
            hidEnvironment: environment,
            appleMusicController: appleMusic,
            proxyFactory: { runtime },
            ownershipMonitorFactory: { ownershipMonitor },
            ownershipRecoveryDelays: [0.001, 0.002],
            forwardSourceCorrelationWindow: forwardSourceCorrelationWindow,
            ownershipReclaimCooldown: ownershipReclaimCooldown
        )
    }
}

@MainActor
private final class FakePlaybackProxyOwnershipMonitor: PlaybackProxyOwnershipMonitoring {
    private(set) var startConfigurations: [PlaybackProxyOwnershipMonitoringConfiguration] = []
    private(set) var stopCalls = 0
    private var signalHandler: ((PlaybackProxyOwnershipMonitorSignal) -> Void)?

    func start(
        configuration: PlaybackProxyOwnershipMonitoringConfiguration,
        onSignal: @escaping (PlaybackProxyOwnershipMonitorSignal) -> Void
    ) {
        startConfigurations.append(configuration)
        signalHandler = onSignal
    }

    func stop() {
        stopCalls += 1
        signalHandler = nil
    }

    func trigger(_ signal: PlaybackProxyOwnershipMonitorSignal) {
        signalHandler?(signal)
    }
}

@MainActor
private final class FakeAppleMusicController: AppleMusicControlling {
    var requestPermissionResult: AppleMusicPermissionResult = .granted
    var sendResult = true
    private(set) var sentCommands: [ProxyRemoteCommand] = []

    func requestPermission() -> AppleMusicPermissionResult {
        requestPermissionResult
    }

    func send(command: ProxyRemoteCommand) -> Bool {
        sentCommands.append(command)
        return sendResult
    }
}

@MainActor
private final class FakeNowPlayingProxyRuntime: NowPlayingProxyRuntimeControlling {
    private var commandHandler: ((ProxyRemoteCommand) -> Void)?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var reassertNowPlayingStateCalls = 0

    func start(commandHandler: @escaping (ProxyRemoteCommand) -> Void) -> Bool {
        startCalls += 1
        self.commandHandler = commandHandler
        return true
    }

    func stop() {
        stopCalls += 1
        commandHandler = nil
    }

    func reassertNowPlayingState() {
        reassertNowPlayingStateCalls += 1
    }

    func emit(_ command: ProxyRemoteCommand) {
        commandHandler?(command)
    }
}

@MainActor
private final class FakeHIDEnvironment: HIDEnvironment {
    var devicesDidChange: (() -> Void)?
    var accessType: IOHIDAccessType = kIOHIDAccessTypeGranted
    var requestAccessResult = true
    var openManagerResult: IOReturn = kIOReturnSuccess
    var devices: [HIDDeviceControlling] = []

    func checkListenAccess() -> IOHIDAccessType {
        accessType
    }

    func requestListenAccess() -> Bool {
        requestAccessResult
    }

    func openManager() -> IOReturn {
        openManagerResult
    }

    func closeManager() {}

    func currentDevices() -> [HIDDeviceControlling] {
        devices
    }
}

@MainActor
private final class FakeHIDDevice: HIDDeviceControlling {
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot

    private var inputValueHandler: ((HIDInputEvent) -> Void)?
    private(set) var isObservingInput = false

    init(serviceID: io_service_t, snapshot: HIDDeviceSnapshot) {
        self.serviceID = serviceID
        self.snapshot = snapshot
    }

    func open(options: IOOptionBits) -> IOReturn {
        kIOReturnSuccess
    }

    func close() {}

    func scheduleWithMainRunLoop() {}

    func unscheduleFromMainRunLoop() {}

    func setInputValueHandler(_ handler: ((HIDInputEvent) -> Void)?) {
        inputValueHandler = handler
        isObservingInput = handler != nil
    }

    func emitInput(usagePage: Int, usage: Int, value: Int, timestamp: UInt64) {
        inputValueHandler?(
            HIDInputEvent(
                device: snapshot,
                timestamp: timestamp,
                usagePage: usagePage,
                usage: usage,
                value: value
            )
        )
    }
}

private extension HIDDeviceSnapshot {
    static func keyboard(product: String) -> HIDDeviceSnapshot {
        HIDDeviceSnapshot(
            transport: "Bluetooth",
            manufacturer: "Keychron",
            product: product,
            serialNumber: nil,
            usagePage: Int(kHIDPage_GenericDesktop),
            usage: Int(kHIDUsage_GD_Keyboard),
            locationID: nil
        )
    }

    static func mouse(product: String) -> HIDDeviceSnapshot {
        HIDDeviceSnapshot(
            transport: "USB",
            manufacturer: "Logitech",
            product: product,
            serialNumber: nil,
            usagePage: Int(kHIDPage_GenericDesktop),
            usage: Int(kHIDUsage_GD_Mouse),
            locationID: nil
        )
    }
}
