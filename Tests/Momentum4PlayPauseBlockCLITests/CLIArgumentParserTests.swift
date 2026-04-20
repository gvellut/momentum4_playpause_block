@testable import Momentum4PlayPauseBlockCLI
import Momentum4PlayPauseBlockCommon
import Testing

struct CLIArgumentParserTests {
    private let parser = CLIArgumentParser()

    @Test
    func parsesNamedBluetoothAddressArgument() throws {
        let parsed = try parser.parse(["--bluetooth-address", "80:C3:BA:82:06:6B"])
        #expect(parsed.target == .bluetoothAddress(BluetoothAddress(normalizing: "80:C3:BA:82:06:6B")!))
        #expect(parsed.operationMode == .block)
    }

    @Test
    func parsesEqualsSeparatedBluetoothAddressArgument() throws {
        let parsed = try parser.parse(["--bluetooth-address=80-c3-ba-82-06-6b"])
        #expect(parsed.target == .bluetoothAddress(BluetoothAddress(normalizing: "80:C3:BA:82:06:6B")!))
        #expect(parsed.operationMode == .block)
    }

    @Test
    func parsesGenericAudioHeadsetFlag() throws {
        let parsed = try parser.parse(["--generic-audio-headset"])
        #expect(parsed.target == .genericAudioHeadset)
        #expect(parsed.operationMode == .block)
    }

    @Test
    func parsesLogEventsWithBluetoothAddressArgument() throws {
        let parsed = try parser.parse(["--bluetooth-address", "80:C3:BA:82:06:6B", "--log-events"])
        #expect(parsed.target == .bluetoothAddress(BluetoothAddress(normalizing: "80:C3:BA:82:06:6B")!))
        #expect(parsed.operationMode == .logEvents)
    }

    @Test
    func parsesLogEventsWithGenericAudioHeadsetFlag() throws {
        let parsed = try parser.parse(["--generic-audio-headset", "--log-events"])
        #expect(parsed.target == .genericAudioHeadset)
        #expect(parsed.operationMode == .logEvents)
    }

    @Test
    func rejectsMissingTarget() {
        #expect(throws: CLIArgumentParserError.missingTarget) {
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

    @Test
    func rejectsConflictingTargetFlags() {
        #expect(throws: CLIArgumentParserError.conflictingTargetFlags) {
            try parser.parse([
                "--bluetooth-address", "80:C3:BA:82:06:6B", "--generic-audio-headset",
            ])
        }
    }

    @Test
    func helpTextDocumentsLogEventsFlag() {
        #expect(CLIUsage.helpText(executableName: "tool").contains("--log-events"))
    }
}
