import Foundation
import Momentum4PlayPauseBlockCommon

struct CLIArguments: Equatable {
    let bluetoothAddress: BluetoothAddress
}

enum CLIArgumentParserError: Error, Equatable {
    case helpRequested
    case missingBluetoothAddress
    case missingBluetoothAddressValue
    case invalidBluetoothAddress(String)
    case unexpectedArgument(String)
}

extension CLIArgumentParserError: CustomStringConvertible {
    var description: String {
        switch self {
        case .helpRequested:
            return ""
        case .missingBluetoothAddress:
            return "Missing required --bluetooth-address argument."
        case .missingBluetoothAddressValue:
            return "The --bluetooth-address flag requires a Bluetooth address value."
        case .invalidBluetoothAddress(let candidate):
            return "Invalid Bluetooth address: \(candidate)"
        case .unexpectedArgument(let argument):
            return "Unexpected argument: \(argument)"
        }
    }
}

struct CLIArgumentParser {
    func parse(_ arguments: [String]) throws -> CLIArguments {
        var bluetoothAddressCandidate: String?
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
            default:
                if argument.hasPrefix("--bluetooth-address=") {
                    bluetoothAddressCandidate = String(argument.dropFirst("--bluetooth-address=".count))
                    index = arguments.index(after: index)
                    continue
                }

                throw CLIArgumentParserError.unexpectedArgument(argument)
            }
        }

        guard let bluetoothAddressCandidate else {
            throw CLIArgumentParserError.missingBluetoothAddress
        }

        guard let bluetoothAddress = BluetoothAddress(normalizing: bluetoothAddressCandidate) else {
            throw CLIArgumentParserError.invalidBluetoothAddress(bluetoothAddressCandidate)
        }

        return CLIArguments(bluetoothAddress: bluetoothAddress)
    }
}

enum CLIUsage {
    static func helpText(executableName: String) -> String {
        """
        Usage:
          \(executableName) --bluetooth-address 80:C3:BA:82:06:6B

        Required:
          --bluetooth-address   The Bluetooth address of the headset to block.

        Notes:
          - The CLI keeps running in the foreground until you stop it with Control-C.
          - macOS Input Monitoring permission is required before HID blocking can work.
        """
    }
}
