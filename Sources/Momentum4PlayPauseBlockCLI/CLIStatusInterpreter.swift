import Foundation
import Momentum4PlayPauseBlockCommon

enum CLIExitCode: Int32 {
    case success = 0
    case runtimeFailure = 1
    case usageFailure = 64
}

enum CLIStatusAction: Equatable {
    case keepRunning
    case exit(CLIExitCode)
}

struct CLIStatusInterpreter {
    func action(for status: PlaybackProxyStatus) -> CLIStatusAction {
        switch status {
        case .requestingPermissions, .active:
            return .keepRunning
        case .disabled, .inputMonitoringDenied, .musicAutomationDenied, .error:
            return .exit(.runtimeFailure)
        }
    }

    func writesToStandardError(_ status: PlaybackProxyStatus) -> Bool {
        switch status {
        case .inputMonitoringDenied, .musicAutomationDenied, .error:
            return true
        case .disabled, .requestingPermissions, .active:
            return false
        }
    }
}
