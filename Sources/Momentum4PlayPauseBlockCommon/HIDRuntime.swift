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

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matchingDictionary: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Int(kHIDPage_Consumer),
            kIOHIDDeviceUsageKey: Int(kHIDUsage_Csmr_ConsumerControl),
        ]

        IOHIDManagerSetDeviceMatching(manager, matchingDictionary as CFDictionary)

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

        return (rawDevices as NSSet).allObjects.map { rawDevice in
            SystemHIDDevice(device: rawDevice as! IOHIDDevice)
        }
    }

    private static let deviceMatchingCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else {
            return
        }

        let environment = Unmanaged<SystemHIDEnvironment>.fromOpaque(context).takeUnretainedValue()
        environment.devicesDidChange?()
    }

    private static let deviceRemovalCallback: IOHIDDeviceCallback = { context, _, _, _ in
        guard let context else {
            return
        }

        let environment = Unmanaged<SystemHIDEnvironment>.fromOpaque(context).takeUnretainedValue()
        environment.devicesDidChange?()
    }
}

@MainActor
private final class SystemHIDDevice: HIDDeviceControlling {
    let serviceID: io_service_t
    let snapshot: HIDDeviceSnapshot

    private let device: IOHIDDevice
    private var inputValueHandler: ((HIDInputEvent) -> Void)?

    init(device: IOHIDDevice) {
        self.device = device
        self.serviceID = IOHIDDeviceGetService(device)
        self.snapshot = HIDDeviceSnapshot(device: device)
    }

    func open(options: IOOptionBits) -> IOReturn {
        IOHIDDeviceOpen(device, options)
    }

    func close() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func scheduleWithMainRunLoop() {
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func unscheduleFromMainRunLoop() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    func setInputValueHandler(_ handler: ((HIDInputEvent) -> Void)?) {
        inputValueHandler = handler

        let context = handler.map { _ in
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        }

        IOHIDDeviceRegisterInputValueCallback(
            device,
            handler == nil ? nil : Self.inputValueCallback,
            context
        )
    }

    private func handleInputValue(_ value: IOHIDValue) {
        guard let inputValueHandler else {
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
