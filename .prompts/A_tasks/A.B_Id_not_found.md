no confidently matching media-control HID

Bluetooth headphone does not have Id defined as the system_profiler SPBluetoothDataType => 80:C3:BA:82:06:6B

 let snapshot = HIDDeviceSnapshot(device: device) in Sources/Momentum4PlayPauseBlockCommon/HeadphoneBlockerService.swift returns :
{transport:"Audio", manufacturer:"Apple", product:"Headset", serialNumber:nil, usagePage:12, usage:1, locationID:nil}

Ohter devices like BT keyboard + wireless mouse (dongle) are found as well. Only Keyboard has an id (serialNumber "6C:93:08:66:FF:CC")
{transport:"Bluetooth", manufacturer:nil, product:"Keychron K1 Pro", serialNumber:"6C:93:08:66:FF:CC", usagePage:1, usage:6, locationID:140967884}

Find how system_profiler SPBluetoothDataType works. How does it find the Id ? and how to link the id defined as parameter to the device in the code
Then do that.

If you cannot, tell me. And will do an alteernate simpler thing ie defined tranport : Audio product : Headset (will be a checkbox that sets those values) and seize that device. On top of the device Id (so 2 possibilties : 1 sepecific and 1 generic, which will work for me)

Also in the Settings for the app : add a check button : that button will see if it finds whatever device has been chosen : either by Id (like now ; only possiblity) or by generic transport product (audio Headset)
