import Foundation
import IOKit.hid

@MainActor
protocol HIDEnvironment: AnyObject {
    var devicesDidChange: (() -> Void)? { get set }

    func checkListenAccess() -> IOHIDAccessType
    func requestListenAccess() -> Bool
    func openManager() -> IOReturn
    func closeManager()
    func currentDevices() -> [HIDDeviceControlling]
}

@MainActor
protocol HIDDeviceControlling: AnyObject {
    var serviceID: io_service_t { get }
    var snapshot: HIDDeviceSnapshot { get }

    func open(options: IOOptionBits) -> IOReturn
    func close()
    func scheduleWithMainRunLoop()
    func unscheduleFromMainRunLoop()
    func setInputValueHandler(_ handler: ((HIDInputEvent) -> Void)?)
}

@MainActor
final class SystemHIDEnvironment: HIDEnvironment {
    var devicesDidChange: (() -> Void)?

    private let manager: IOHIDManager
    private var devicesByIdentity: [ObjectIdentifier: SystemHIDDevice] = [:]

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matchingDictionaries: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_Consumer)],
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_Telephony)],
            [kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop)],
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDictionaries as CFArray)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovalCallback, context)
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
    }

    func checkListenAccess() -> IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    func requestListenAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func openManager() -> IOReturn {
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func closeManager() {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func currentDevices() -> [HIDDeviceControlling] {
        guard let rawDevices = IOHIDManagerCopyDevices(manager) else {
            return []
        }

        return (rawDevices as NSSet).allObjects.map { rawDevice -> HIDDeviceControlling in
            let device = rawDevice as! IOHIDDevice
            return cachedDevice(for: device)
        }
    }

    private func cachedDevice(for device: IOHIDDevice) -> SystemHIDDevice {
        let identity = ObjectIdentifier(device as AnyObject)
        if let cachedDevice = devicesByIdentity[identity] {
            return cachedDevice
        }

        let cachedDevice = SystemHIDDevice(device: device)
        devicesByIdentity[identity] = cachedDevice
        return cachedDevice
    }

    private func handleDeviceRemoval(_ device: IOHIDDevice) {
        let identity = ObjectIdentifier(device as AnyObject)
        devicesByIdentity[identity]?.prepareForRemoval()
        devicesDidChange?()
    }

    private static let deviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else {
            return
        }

        let environment = Unmanaged<SystemHIDEnvironment>.fromOpaque(context).takeUnretainedValue()
        environment.devicesDidChange?()
    }

    private static let deviceRemovalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else {
            return
        }

        let environment = Unmanaged<SystemHIDEnvironment>.fromOpaque(context).takeUnretainedValue()
        environment.handleDeviceRemoval(device)
    }
}

@MainActor
private final class SystemHIDDevice: HIDDeviceControlling {
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot

    private let device: IOHIDDevice
    private var inputValueHandler: ((HIDInputEvent) -> Void)?
    private var isOpen = false
    private var isScheduled = false
    private var isObservingInput = false

    init(device: IOHIDDevice) {
        self.device = device
        self.serviceID = IOHIDDeviceGetService(device)
        self.snapshot = HIDDeviceSnapshot(device: device)
    }

    func open(options: IOOptionBits) -> IOReturn {
        guard !isOpen else {
            return kIOReturnSuccess
        }

        let result = IOHIDDeviceOpen(device, options)
        if result == kIOReturnSuccess {
            isOpen = true
        }
        return result
    }

    func close() {
        guard isOpen else {
            return
        }

        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
    }

    func scheduleWithMainRunLoop() {
        guard !isScheduled else {
            return
        }

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        isScheduled = true
    }

    func unscheduleFromMainRunLoop() {
        guard isScheduled else {
            return
        }

        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        isScheduled = false
    }

    func setInputValueHandler(_ handler: ((HIDInputEvent) -> Void)?) {
        inputValueHandler = handler
        isObservingInput = handler != nil

        guard handler != nil else {
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        IOHIDDeviceRegisterInputValueCallback(
            device,
            Self.inputValueCallback,
            context
        )
    }

    func prepareForRemoval() {
        setInputValueHandler(nil)
        unscheduleFromMainRunLoop()
        close()
    }

    private func handleInputValue(_ value: IOHIDValue) {
        guard isObservingInput, let inputValueHandler else {
            return
        }

        let element = IOHIDValueGetElement(value)
        let event = HIDInputEvent(
            device: snapshot,
            timestamp: IOHIDValueGetTimeStamp(value),
            usagePage: Int(IOHIDElementGetUsagePage(element)),
            usage: Int(IOHIDElementGetUsage(element)),
            value: Int(IOHIDValueGetIntegerValue(value))
        )
        inputValueHandler(event)
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else {
            return
        }

        let device = Unmanaged<SystemHIDDevice>.fromOpaque(context).takeUnretainedValue()
        device.handleInputValue(value)
    }
}
