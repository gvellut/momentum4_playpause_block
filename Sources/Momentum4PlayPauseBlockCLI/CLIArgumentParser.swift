import Foundation
import Momentum4PlayPauseBlockCommon

struct CLIArguments: Equatable {
    static let defaultOwnershipPollInterval: TimeInterval = 15
    static let defaultOwnershipPollIntervalDescription = formattedSeconds(
        defaultOwnershipPollInterval
    )

    let allowedForwardSourceMode: AllowedForwardSourceMode
    let allowedForwardSourceProductName: String
    let ownershipPollInterval: TimeInterval?

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

    var ownershipReclaimDescription: String {
        if let ownershipPollInterval {
            return
                "Ownership reclaim is enabled: event-driven monitoring is active and the timed backstop runs every \(Self.formattedSeconds(ownershipPollInterval))."
        }

        return
            "Ownership reclaim is enabled: event-driven monitoring is active and the timed backstop is disabled."
    }

    var configuration: PlaybackProxyConfiguration {
        PlaybackProxyConfiguration(
            enabled: true,
            allowedForwardSourceMode: allowedForwardSourceMode,
            allowedForwardSourceProductName: allowedForwardSourceProductName,
            eventDrivenReclaimEnabled: true,
            pollInterval: ownershipPollInterval
        )
    }

    static func formattedSeconds(_ value: TimeInterval) -> String {
        if value == value.rounded() {
            return "\(Int(value))s"
        }

        return "\(value)s"
    }
}

enum CLIArgumentParserError: Error, Equatable {
    case helpRequested
    case missingForwardSourceValue
    case invalidForwardSourceValue(String)
    case missingProductNameValue
    case missingOwnershipPollIntervalValue
    case invalidOwnershipPollIntervalValue(String)
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
        case .missingOwnershipPollIntervalValue:
            return "The --ownership-poll-interval flag requires a value."
        case .invalidOwnershipPollIntervalValue(let value):
            return
                "Invalid --ownership-poll-interval value: \(value). Use a positive number of seconds or 0 to disable the timed backstop."
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
        var ownershipPollInterval: TimeInterval? = CLIArguments.defaultOwnershipPollInterval
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
            case "--ownership-poll-interval":
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else {
                    throw CLIArgumentParserError.missingOwnershipPollIntervalValue
                }

                ownershipPollInterval = try parseOwnershipPollInterval(arguments[nextIndex])
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

                if argument.hasPrefix("--ownership-poll-interval=") {
                    let value = String(argument.dropFirst("--ownership-poll-interval=".count))
                    ownershipPollInterval = try parseOwnershipPollInterval(value)
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
            allowedForwardSourceProductName: allowedForwardSourceProductName,
            ownershipPollInterval: ownershipPollInterval
        )
    }

    private func parseOwnershipPollInterval(_ rawValue: String) throws -> TimeInterval? {
        guard let parsedValue = Double(rawValue), parsedValue.isFinite, parsedValue >= 0 else {
            throw CLIArgumentParserError.invalidOwnershipPollIntervalValue(rawValue)
        }

        return parsedValue == 0 ? nil : parsedValue
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
          --ownership-poll-interval
                               Timed ownership-reclaim backstop in seconds.
                               Use 0 to disable timed reclaim while keeping event-driven reclaim enabled.
                               Default: \(CLIArguments.defaultOwnershipPollIntervalDescription)

        Notes:
          - This CLI uses the working Apple Music-only proxy path.
          - Momentum 4 or other remote play/pause commands are swallowed unless they correlate with the allowed HID source.
          - Event-driven ownership reclaim is enabled by default.
          - macOS Input Monitoring permission is required before HID observation can work.
          - macOS Automation permission for Music is required because forwarding uses AppleScript.
          - The CLI stays in the foreground until you stop it with Control-C.
        """
    }
}
