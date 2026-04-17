import Momentum4PlayPauseBlockCore
import Testing

struct BluetoothAddressTests {
    @Test
    func bluetoothAddressNormalizesDashSeparatedInput() {
        let address = BluetoothAddress(normalizing: "80-c3-ba-82-06-6b")
        #expect(address?.rawValue == "80:C3:BA:82:06:6B")
    }

    @Test
    func bluetoothAddressRejectsInvalidLength() {
        #expect(BluetoothAddress(normalizing: "80:C3:BA:82") == nil)
    }

    @Test
    func bluetoothAddressSanitizesDraft() {
        #expect(
            BluetoothAddress.sanitizeUserEntry("80:c3:ba:82:06:6b!?!") == "80:C3:BA:82:06:6B"
        )
    }
}
