@testable import Momentum4PlayPauseBlockCommon
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

        #expect(appleMusic.sentCommands == [.togglePlayPause])
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

    private func makeService(
        environment: FakeHIDEnvironment,
        appleMusic: FakeAppleMusicController,
        runtime: FakeNowPlayingProxyRuntime
    ) -> PlaybackProxyService {
        PlaybackProxyService(
            hidEnvironment: environment,
            appleMusicController: appleMusic,
            proxyFactory: { runtime }
        )
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

    func start(commandHandler: @escaping (ProxyRemoteCommand) -> Void) -> Bool {
        self.commandHandler = commandHandler
        return true
    }

    func stop() {
        commandHandler = nil
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
