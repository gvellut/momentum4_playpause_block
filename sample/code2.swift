import Foundation
import IOKit.hid

// 1. Create HID Manager
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// 2. Match Consumer Controls, Telephony, and Keyboards to catch EVERYTHING
let matchConsumer = [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer]
let matchTelephony = [kIOHIDDeviceUsagePageKey: kHIDPage_Telephony]
let matchGeneric = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop]

IOHIDManagerSetDeviceMatchingMultiple(
    manager, [matchConsumer, matchTelephony, matchGeneric] as CFArray)

// 3. Callback when a device is connected/discovered
let matchCallback: IOHIDDeviceCallback = { context, result, sender, device in
    let name =
        (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Unknown"
    let manufacturer =
        (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? "Unknown"

    print("\n[+] Found Device: \(name) (Manufacturer: \(manufacturer))")

    // Attempt to seize ONLY devices named "Headset" or "Audio" (The virtual Apple ones)
    if name.localizedCaseInsensitiveContains("Headset")
        || name.localizedCaseInsensitiveContains("Audio")
    {
        print("    -> Attempting to seize this virtual headset device...")
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if openResult == kIOReturnSuccess {
            print("    -> SUCCESS: Seized \(name).")
        } else {
            // If it returns 0xE00002C5, it means kIOReturnExclusiveAccess (rcd holds it)
            let errorHex = String(format: "%08X", openResult)
            print("    -> FAILED to seize \(name). Error: 0x\(errorHex).")
            print(
                "    -> Theory confirmed: com.apple.rcd (or another app) already holds exclusive access."
            )
        }
    }

    // Register to listen to the actual button presses
    IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, nil)
}

// 4. Callback when a button is actually pressed
let inputValueCallback: IOHIDValueCallback = { context, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    // intValue == 1 is key down, 0 is key up
    if intValue == 1 {
        // Extract the device name that sent the event
        var deviceName = "Unknown"
        if let senderPtr = sender {
            let device = Unmanaged<IOHIDDevice>.fromOpaque(senderPtr).takeUnretainedValue()
            deviceName =
                (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
                ?? "Unknown"
        }

        print("\n[EVENT] Button Pressed on: \(deviceName)")
        print("        Usage Page: 0x\(String(format:"%02X", usagePage))")
        print("        Usage ID:   0x\(String(format:"%02X", usage))")

        // Check if it's a standard play/pause
        if usagePage == kHIDPage_Consumer && usage == kHIDUsage_Csmr_PlayOrPause {
            print("        *** STANDARD CONSUMER PLAY/PAUSE DETECTED ***")
        } else if usagePage == kHIDPage_Telephony {
            print("        *** TELEPHONY COMMAND DETECTED (e.g., Hook Switch) ***")
        }
    }
}

// 5. Start listening
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

print("Diagnostics running. Press Play/Pause on your Keyboard, then on your Momentum 4.")
CFRunLoopRun()
