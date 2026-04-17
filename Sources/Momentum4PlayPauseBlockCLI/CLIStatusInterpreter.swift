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
    func action(for status: BlockerStatus) -> CLIStatusAction {
        switch status {
        case .requestingPermission, .waitingForTarget, .blocking:
            return .keepRunning
        case .disabled, .permissionDenied, .error:
            return .exit(.runtimeFailure)
        }
    }

    func writesToStandardError(_ status: BlockerStatus) -> Bool {
        switch status {
        case .permissionDenied, .error:
            return true
        case .disabled, .requestingPermission, .waitingForTarget, .blocking:
            return false
        }
    }
}
