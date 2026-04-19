import Foundation
import Momentum4PlayPauseBlockCommon

struct CLIArguments: Equatable {
    let target: BlockerTarget

    var startupDescription: String {
        switch target {
        case .bluetoothAddress(let address):
            return address.rawValue
        case .genericAudioHeadset:
            return "generic Audio / Headset"
        }
    }
}

enum CLIArgumentParserError: Error, Equatable {
    case helpRequested
    case missingTarget
    case missingBluetoothAddressValue
    case invalidBluetoothAddress(String)
    case conflictingTargetFlags
    case unexpectedArgument(String)
}

extension CLIArgumentParserError: CustomStringConvertible {
    var description: String {
        switch self {
        case .helpRequested:
            return ""
        case .missingTarget:
            return "Choose exactly one target: --bluetooth-address <id> or --generic-audio-headset."
        case .missingBluetoothAddressValue:
            return "The --bluetooth-address flag requires a Bluetooth address value."
        case .invalidBluetoothAddress(let candidate):
            return "Invalid Bluetooth address: \(candidate)"
        case .conflictingTargetFlags:
            return "The --bluetooth-address and --generic-audio-headset flags are mutually exclusive."
        case .unexpectedArgument(let argument):
            return "Unexpected argument: \(argument)"
        }
    }
}

struct CLIArgumentParser {
    func parse(_ arguments: [String]) throws -> CLIArguments {
        var bluetoothAddressCandidate: String?
        var wantsGenericAudioHeadset = false
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]

            switch argument {
            case "--help", "-h":
                throw CLIArgumentParserError.helpRequested
            case "--bluetooth-address":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentParserError.missingBluetoothAddressValue
                }

                bluetoothAddressCandidate = arguments[nextIndex]
                index = arguments.index(after: nextIndex)
            case "--generic-audio-headset":
                wantsGenericAudioHeadset = true
                index = arguments.index(after: index)
            default:
                if argument.hasPrefix("--bluetooth-address=") {
                    bluetoothAddressCandidate = String(argument.dropFirst("--bluetooth-address=".count))
                    index = arguments.index(after: index)
                    continue
                }

                throw CLIArgumentParserError.unexpectedArgument(argument)
            }
        }

        if bluetoothAddressCandidate != nil && wantsGenericAudioHeadset {
            throw CLIArgumentParserError.conflictingTargetFlags
        }

        if wantsGenericAudioHeadset {
            return CLIArguments(target: .genericAudioHeadset)
        }

        guard let bluetoothAddressCandidate else {
            throw CLIArgumentParserError.missingTarget
        }

        guard let bluetoothAddress = BluetoothAddress(normalizing: bluetoothAddressCandidate) else {
            throw CLIArgumentParserError.invalidBluetoothAddress(bluetoothAddressCandidate)
        }

        return CLIArguments(target: .bluetoothAddress(bluetoothAddress))
    }
}

enum CLIUsage {
    static func helpText(executableName: String) -> String {
        """
        Usage:
          \(executableName) --bluetooth-address 80:C3:BA:82:06:6B
          \(executableName) --generic-audio-headset

        Choose exactly one:
          --bluetooth-address   The Bluetooth address of the headset to block.
          --generic-audio-headset
                                Match the generic Audio / Headset HID endpoint.

        Notes:
          - The CLI keeps running in the foreground until you stop it with Control-C.
          - macOS Input Monitoring permission is required before HID blocking can work.
        """
    }
}
