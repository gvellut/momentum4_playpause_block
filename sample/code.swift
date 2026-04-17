import Foundation
import IOKit.hid

// 1. Create the HID Manager
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// 2. Set it to specifically look for "Consumer Control" devices (which handle Play/Pause)
let matchDict: [String: Any] =[
    kIOHIDDeviceUsagePageKey: kHIDPage_Consumer,
    kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl
]

IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

// 3. Define the callback that runs when a device is found
let matchCallback: IOHIDDeviceCallback = { context, result, sender, device in
    
    // Get the device's name
    var deviceName = "Unknown Device"
    if let nameRef = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) {
        deviceName = nameRef as! String
    }
    
    print("Found Media Controller: \(deviceName)")
    
    // 4. Check if the device is the Momentum 4, or a generic AVRCP Headset
    // (We use localizedCaseInsensitiveContains to catch different variations)
    if deviceName.localizedCaseInsensitiveContains("MOMENTUM") || 
       deviceName.localizedCaseInsensitiveContains("AVRCP") ||
       deviceName.localizedCaseInsensitiveContains("Headset") {
        
        print("   -> Target identified! Seizing device to block its commands...")
        
        // 5. SEIZE THE DEVICE
        // Option '1' is kIOHIDOptionsTypeSeizeDevice.
        // This grants us exclusive access and literally blocks macOS from seeing the events.
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(1))
        
        if openResult == kIOReturnSuccess {
            print("   -> SUCCESS: \(deviceName) is seized. Its play/pause commands are now DEAD.")
        } else {
            print("   -> ERROR: Failed to seize device. (Error code: \(openResult)). Try running with sudo.")
        }
    } else {
        // If it's your Keychron or Mac keyboard, we do nothing.
        print("   -> Ignoring \(deviceName). It will continue to work normally.")
    }
}

// Register the callback
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)

// Schedule the HID manager on the main run loop
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

// Open the manager to start listening
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

print("Scanning for connected devices... (Press Ctrl+C to stop)")
CFRunLoopRun()