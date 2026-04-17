import IOKit.hid
import Momentum4PlayPauseBlockCommon
import Testing

struct HIDDeviceMatcherTests {
    private let matcher = HIDDeviceMatcher()
    private let target = BluetoothDeviceSnapshot(
        address: BluetoothAddress(normalizing: "80:C3:BA:82:06:6B")!,
        name: "MOMENTUM 4",
        isConnected: true
    )

    @Test
    func matcherAcceptsMatchingSerialNumber() {
        let device = HIDDeviceSnapshot(
            transport: "Bluetooth",
            manufacturer: "Unknown",
            product: "AVRCP Controller",
            serialNumber: "80-C3-BA-82-06-6B",
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: nil
        )

        #expect(
            matcher.match(device: device, target: target)
                == .matched("The HID serial number matches the configured Bluetooth address.")
        )
    }

    @Test
    func matcherAcceptsNameAndBrandCorrelation() {
        let device = HIDDeviceSnapshot(
            transport: "Bluetooth Low Energy",
            manufacturer: "Sennheiser",
            product: "MOMENTUM 4 Media Controller",
            serialNumber: nil,
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: nil
        )

        #expect(
            matcher.match(device: device, target: target)
                == .matched("The HID metadata matches the connected target headset name and brand.")
        )
    }

    @Test
    func matcherRejectsWeakCorrelation() {
        let device = HIDDeviceSnapshot(
            transport: "Bluetooth",
            manufacturer: "Keychron",
            product: "Keyboard Media Keys",
            serialNumber: nil,
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: nil
        )

        #expect(
            matcher.match(device: device, target: target)
                == .rejected("The HID metadata does not match the target headset strongly enough.")
        )
    }
}
