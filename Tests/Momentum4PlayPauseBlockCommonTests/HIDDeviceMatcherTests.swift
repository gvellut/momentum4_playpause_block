import IOKit.hid
import Momentum4PlayPauseBlockCommon
import Testing

struct HIDDeviceMatcherTests {
    private let matcher = HIDDeviceMatcher()
    private let targetAddress = BluetoothAddress(normalizing: "80:C3:BA:82:06:6B")!

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
            matcher.match(device: device, target: .bluetoothAddress(targetAddress))
                == .matched("The HID serial number matches the configured Bluetooth address.")
        )
    }

    @Test
    func matcherAcceptsRegistryAddressCorrelation() {
        let device = HIDDeviceSnapshot(
            transport: "Audio",
            manufacturer: "Apple",
            product: "Headset",
            serialNumber: nil,
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: nil,
            registryBluetoothAddresses: [targetAddress],
            registryAddressHints: ["BTAddress=80:C3:BA:82:06:6B"]
        )

        #expect(
            matcher.match(device: device, target: .bluetoothAddress(targetAddress))
                == .matched(
                    "An address-like registry property matches the configured Bluetooth address."
                )
        )
    }

    @Test
    func matcherRejectsAudioHeadsetWithoutBridgeInBluetoothAddressMode() {
        let device = HIDDeviceSnapshot(
            transport: "Audio",
            manufacturer: "Apple",
            product: "Headset",
            serialNumber: nil,
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: nil
        )

        #expect(
            matcher.match(device: device, target: .bluetoothAddress(targetAddress))
                == .rejected(
                    "The HID endpoint does not expose the configured Bluetooth address through SerialNumber, UniqueID, or parent registry address properties."
                )
        )
    }

    @Test
    func matcherAcceptsGenericAudioHeadsetTarget() {
        let device = HIDDeviceSnapshot(
            transport: "Audio",
            manufacturer: "Apple",
            product: "Headset",
            serialNumber: nil,
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: nil
        )

        #expect(
            matcher.match(device: device, target: .genericAudioHeadset)
                == .matched("The HID endpoint matches the generic Audio / Headset target.")
        )
    }

    @Test
    func matcherRejectsKeyboardMediaInterfaceForGenericAudioHeadsetTarget() {
        let device = HIDDeviceSnapshot(
            transport: "Bluetooth",
            manufacturer: "Keychron",
            product: "Keychron K1 Pro",
            serialNumber: "6C:93:08:66:FF:CC",
            usagePage: Int(kHIDPage_Consumer),
            usage: Int(kHIDUsage_Csmr_ConsumerControl),
            locationID: 140_967_884
        )

        #expect(
            matcher.match(device: device, target: .genericAudioHeadset)
                == .rejected("The HID endpoint transport is not Audio.")
        )
    }
}
