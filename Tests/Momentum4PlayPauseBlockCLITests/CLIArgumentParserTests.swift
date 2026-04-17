@testable import Momentum4PlayPauseBlockCLI
import Momentum4PlayPauseBlockCommon
import Testing

struct CLIArgumentParserTests {
    private let parser = CLIArgumentParser()

    @Test
    func parsesNamedBluetoothAddressArgument() throws {
        let parsed = try parser.parse(["--bluetooth-address", "80:C3:BA:82:06:6B"])
        #expect(parsed.bluetoothAddress.rawValue == "80:C3:BA:82:06:6B")
    }

    @Test
    func parsesEqualsSeparatedBluetoothAddressArgument() throws {
        let parsed = try parser.parse(["--bluetooth-address=80-c3-ba-82-06-6b"])
        #expect(parsed.bluetoothAddress.rawValue == "80:C3:BA:82:06:6B")
    }

    @Test
    func rejectsMissingBluetoothAddress() {
        #expect(throws: CLIArgumentParserError.missingBluetoothAddress) {
            try parser.parse([])
        }
    }

    @Test
    func rejectsInvalidBluetoothAddress() {
        #expect(throws: CLIArgumentParserError.invalidBluetoothAddress("invalid")) {
            try parser.parse(["--bluetooth-address", "invalid"])
        }
    }

    @Test
    func supportsHelpFlag() {
        #expect(throws: CLIArgumentParserError.helpRequested) {
            try parser.parse(["--help"])
        }
    }
}
