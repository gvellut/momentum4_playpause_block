@testable import Momentum4PlayPauseBlockCommon
import IOKit.hid
import Testing

@MainActor
struct HeadphoneBlockerServiceTests {
    @Test
    func matchedCandidateWithFailedSeizeDoesNotReportBlocking() {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(
            serviceID: 1,
            snapshot: .genericHeadset(),
            openResults: [IOOptionBits(kIOHIDOptionsTypeSeizeDevice): kIOReturnError]
        )
        environment.devices = [device]

        let service = makeService(environment: environment)
        var reportedStatuses: [BlockerStatus] = []
        service.statusDidChange = { reportedStatuses.append($0) }

        service.apply(
            configuration: BlockerConfiguration(
                isEnabled: true,
                target: .genericAudioHeadset
            )
        )

        #expect(!reportedStatuses.contains(where: isBlockingStatus))
        #expect(device.openCalls == [IOOptionBits(kIOHIDOptionsTypeSeizeDevice)])

        guard let lastStatus = reportedStatuses.last else {
            Issue.record("Expected a terminal status to be reported.")
            return
        }

        guard case .error(let message) = lastStatus else {
            Issue.record("Expected the blocker to report an activation error.")
            return
        }

        #expect(message.contains("could not activate any media-control HID endpoint"))
        #expect(message.contains("1"))
    }

    @Test
    func matchedCandidateWithSuccessfulSeizeReportsBlocking() {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 2, snapshot: .genericHeadset())
        environment.devices = [device]

        let service = makeService(environment: environment)
        var reportedStatuses: [BlockerStatus] = []
        service.statusDidChange = { reportedStatuses.append($0) }

        service.apply(
            configuration: BlockerConfiguration(
                isEnabled: true,
                target: .genericAudioHeadset
            )
        )

        #expect(device.openCalls == [IOOptionBits(kIOHIDOptionsTypeSeizeDevice)])

        guard let lastStatus = reportedStatuses.last else {
            Issue.record("Expected a blocking status to be reported.")
            return
        }

        guard case .blocking(let label) = lastStatus else {
            Issue.record("Expected a blocking status.")
            return
        }

        #expect(label.contains("product: Headset"))
    }

    @Test
    func matchedCandidateWithSuccessfulListenReportsObservingAndForwardsEvents() {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(serviceID: 3, snapshot: .genericHeadset())
        environment.devices = [device]

        let service = makeService(environment: environment)
        var reportedStatuses: [BlockerStatus] = []
        var receivedEvents: [HIDInputEvent] = []
        service.statusDidChange = { reportedStatuses.append($0) }
        service.inputEventDidReceive = { receivedEvents.append($0) }

        service.apply(
            configuration: BlockerConfiguration(
                isEnabled: true,
                target: .genericAudioHeadset,
                operationMode: .logEvents
            )
        )

        #expect(device.openCalls == [IOOptionBits(kIOHIDOptionsTypeNone)])
        #expect(device.scheduleCount == 1)

        guard let lastStatus = reportedStatuses.last else {
            Issue.record("Expected an observing status to be reported.")
            return
        }

        guard case .observing(let label) = lastStatus else {
            Issue.record("Expected an observing status.")
            return
        }

        #expect(label.contains("product: Headset"))

        device.emitInput(
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_PlayOrPause),
            value: 1,
            timestamp: 77
        )

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].usagePage == Int(kHIDPage_Consumer))
        #expect(receivedEvents[0].usage == Int(kHIDUsage_Csmr_PlayOrPause))
        #expect(receivedEvents[0].value == 1)
        #expect(receivedEvents[0].timestamp == 77)
        #expect(receivedEvents[0].actionLabel == "Play/Pause")
    }

    @Test
    func matchedCandidateWithFailedListenReportsError() {
        let environment = FakeHIDEnvironment()
        let device = FakeHIDDevice(
            serviceID: 4,
            snapshot: .genericHeadset(),
            openResults: [IOOptionBits(kIOHIDOptionsTypeNone): kIOReturnError]
        )
        environment.devices = [device]

        let service = makeService(environment: environment)
        var reportedStatuses: [BlockerStatus] = []
        service.statusDidChange = { reportedStatuses.append($0) }

        service.apply(
            configuration: BlockerConfiguration(
                isEnabled: true,
                target: .genericAudioHeadset,
                operationMode: .logEvents
            )
        )

        #expect(!reportedStatuses.contains(where: isObservingStatus))
        #expect(device.scheduleCount == 1)
        #expect(device.unscheduleCount == 1)
        #expect(device.inputValueHandler == nil)

        guard let lastStatus = reportedStatuses.last else {
            Issue.record("Expected an activation error to be reported.")
            return
        }

        guard case .error = lastStatus else {
            Issue.record("Expected an activation error.")
            return
        }
    }

    @Test
    func mixedMatchedDevicesOnlyReleaseSuccessfullyActivatedSessions() {
        let environment = FakeHIDEnvironment()
        let successfulDevice = FakeHIDDevice(serviceID: 5, snapshot: .genericHeadset())
        let failingDevice = FakeHIDDevice(
            serviceID: 6,
            snapshot: .genericHeadset(serialNumber: "failed"),
            openResults: [IOOptionBits(kIOHIDOptionsTypeSeizeDevice): kIOReturnError]
        )
        environment.devices = [successfulDevice, failingDevice]

        let service = makeService(environment: environment)

        service.apply(
            configuration: BlockerConfiguration(
                isEnabled: true,
                target: .genericAudioHeadset
            )
        )
        service.apply(configuration: BlockerConfiguration(isEnabled: false, target: nil))

        #expect(successfulDevice.closeCount == 1)
        #expect(failingDevice.closeCount == 0)
    }

    private func makeService(environment: FakeHIDEnvironment) -> HeadphoneBlockerService {
        HeadphoneBlockerService(
            bluetoothResolver: FakeBluetoothResolver(),
            matcher: HIDDeviceMatcher(),
            hidEnvironment: environment
        )
    }

    private func isBlockingStatus(_ status: BlockerStatus) -> Bool {
        if case .blocking = status {
            return true
        }

        return false
    }

    private func isObservingStatus(_ status: BlockerStatus) -> Bool {
        if case .observing = status {
            return true
        }

        return false
    }
}

private struct FakeBluetoothResolver: BluetoothDeviceResolving {
    func resolve(address: BluetoothAddress) -> BluetoothDeviceSnapshot? {
        BluetoothDeviceSnapshot(address: address, name: "Momentum 4", isConnected: true)
    }
}

@MainActor
private final class FakeHIDEnvironment: HIDEnvironment {
    var devicesDidChange: (() -> Void)?
    var accessType: IOHIDAccessType = kIOHIDAccessTypeGranted
    var requestAccessResult = true
    var openManagerResult: IOReturn = kIOReturnSuccess
    var devices: [HIDDeviceControlling] = []
    var openManagerCallCount = 0
    var closeManagerCallCount = 0

    func checkListenAccess() -> IOHIDAccessType {
        accessType
    }

    func requestListenAccess() -> Bool {
        requestAccessResult
    }

    func openManager() -> IOReturn {
        openManagerCallCount += 1
        return openManagerResult
    }

    func closeManager() {
        closeManagerCallCount += 1
    }

    func currentDevices() -> [HIDDeviceControlling] {
        devices
    }
}

@MainActor
private final class FakeHIDDevice: HIDDeviceControlling {
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot

    var openResults: [IOOptionBits: IOReturn]
    var openCalls: [IOOptionBits] = []
    var closeCount = 0
    var scheduleCount = 0
    var unscheduleCount = 0
    var inputValueHandler: ((HIDInputEvent) -> Void)?

    init(
        serviceID: io_service_t,
        snapshot: HIDDeviceSnapshot,
        openResults: [IOOptionBits: IOReturn] = [:]
    ) {
        self.serviceID = serviceID
        self.snapshot = snapshot
        self.openResults = openResults
    }

    func open(options: IOOptionBits) -> IOReturn {
        openCalls.append(options)
        return openResults[options] ?? kIOReturnSuccess
    }

    func close() {
        closeCount += 1
    }

    func scheduleWithMainRunLoop() {
        scheduleCount += 1
    }

    func unscheduleFromMainRunLoop() {
        unscheduleCount += 1
    }

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
    static func genericHeadset(serialNumber: String? = nil) -> HIDDeviceSnapshot {
        HIDDeviceSnapshot(
            transport: "Audio",
            manufacturer: "Apple",
            product: "Headset",
            serialNumber: serialNumber,
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: nil
        )
    }
}
