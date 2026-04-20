import Foundation
import Momentum4PlayPauseBlockCommon

struct CLIArguments: Equatable {
    let allowedForwardSourceMode: AllowedForwardSourceMode
    let allowedForwardSourceProductName: String

    var startupDescription: String {
        switch allowedForwardSourceMode {
        case .specificProductName:
            return "the HID product name \"\(allowedForwardSourceProductName)\""
        case .anyKeyboard:
            return "all keyboard HID sources"
        case .anyHID:
            return "all HID sources"
        }
    }

    var configuration: PlaybackProxyConfiguration {
        PlaybackProxyConfiguration(
            enabled: true,
            allowedForwardSourceMode: allowedForwardSourceMode,
            allowedForwardSourceProductName: allowedForwardSourceProductName
        )
    }
}

enum CLIArgumentParserError: Error, Equatable {
    case helpRequested
    case missingForwardSourceValue
    case invalidForwardSourceValue(String)
    case missingProductNameValue
    case specificProductNameRequiresValue
    case productNameRequiresSpecificSourceMode
    case unexpectedArgument(String)
}

extension CLIArgumentParserError: CustomStringConvertible {
    var description: String {
        switch self {
        case .helpRequested:
            return ""
        case .missingForwardSourceValue:
            return "The --forward-source flag requires a value."
        case .invalidForwardSourceValue(let value):
            return
                "Invalid --forward-source value: \(value). Use specific-product-name, any-keyboard, or any-hid."
        case .missingProductNameValue:
            return "The --product-name flag requires a product name."
        case .specificProductNameRequiresValue:
            return
                "The specific-product-name source mode requires --product-name \"Exact HID Product Name\"."
        case .productNameRequiresSpecificSourceMode:
            return
                "The --product-name flag can only be used with --forward-source specific-product-name."
        case .unexpectedArgument(let argument):
            return "Unexpected argument: \(argument)"
        }
    }
}

struct CLIArgumentParser {
    func parse(_ arguments: [String]) throws -> CLIArguments {
        var allowedForwardSourceMode: AllowedForwardSourceMode = .anyHID
        var allowedForwardSourceProductName = ""
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]

            switch argument {
            case "--help", "-h":
                throw CLIArgumentParserError.helpRequested
            case "--forward-source":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentParserError.missingForwardSourceValue
                }

                guard
                    let parsedMode = AllowedForwardSourceMode(rawValue: arguments[nextIndex])
                else {
                    throw CLIArgumentParserError.invalidForwardSourceValue(arguments[nextIndex])
                }

                allowedForwardSourceMode = parsedMode
                index = arguments.index(after: nextIndex)
            case "--product-name":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentParserError.missingProductNameValue
                }

                allowedForwardSourceProductName = arguments[nextIndex].trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                index = arguments.index(after: nextIndex)
            default:
                if argument.hasPrefix("--forward-source=") {
                    let value = String(argument.dropFirst("--forward-source=".count))
                    guard let parsedMode = AllowedForwardSourceMode(rawValue: value) else {
                        throw CLIArgumentParserError.invalidForwardSourceValue(value)
                    }

                    allowedForwardSourceMode = parsedMode
                    index = arguments.index(after: index)
                    continue
                }

                if argument.hasPrefix("--product-name=") {
                    allowedForwardSourceProductName = String(argument.dropFirst("--product-name=".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    index = arguments.index(after: index)
                    continue
                }

                throw CLIArgumentParserError.unexpectedArgument(argument)
            }
        }

        if allowedForwardSourceMode == .specificProductName {
            guard !allowedForwardSourceProductName.isEmpty else {
                throw CLIArgumentParserError.specificProductNameRequiresValue
            }
        } else if !allowedForwardSourceProductName.isEmpty {
            throw CLIArgumentParserError.productNameRequiresSpecificSourceMode
        }

        return CLIArguments(
            allowedForwardSourceMode: allowedForwardSourceMode,
            allowedForwardSourceProductName: allowedForwardSourceProductName
        )
    }
}

enum CLIUsage {
    static func helpText(executableName: String) -> String {
        """
        Usage:
          \(executableName)
          \(executableName) --forward-source any-keyboard
          \(executableName) --forward-source specific-product-name --product-name "Keychron K1 Pro"

        Options:
          --forward-source     Which HID source can bypass the Apple Music proxy.
                               Values: specific-product-name, any-keyboard, any-hid
                               Default: any-hid
          --product-name       Exact HID product name to allow when --forward-source specific-product-name is used.

        Notes:
          - This CLI uses the working Apple Music-only proxy path.
          - Momentum 4 or other remote play/pause commands are swallowed unless they correlate with the allowed HID source.
          - macOS Input Monitoring permission is required before HID observation can work.
          - macOS Automation permission for Music is required because forwarding uses AppleScript.
          - The CLI stays in the foreground until you stop it with Control-C.
        """
    }
}
