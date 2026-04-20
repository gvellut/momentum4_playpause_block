@testable import Momentum4PlayPauseBlockCLI
import Momentum4PlayPauseBlockCommon
import Testing

struct CLIStatusInterpreterTests {
    private let interpreter = CLIStatusInterpreter()

    @Test
    func activeStatusKeepsProcessRunning() {
        #expect(interpreter.action(for: .active("all HID sources")) == .keepRunning)
    }

    @Test
    func requestingPermissionsKeepsProcessRunning() {
        #expect(interpreter.action(for: .requestingPermissions) == .keepRunning)
    }

    @Test
    func deniedPermissionsExitWithRuntimeFailure() {
        #expect(interpreter.action(for: .inputMonitoringDenied) == .exit(.runtimeFailure))
        #expect(interpreter.action(for: .musicAutomationDenied) == .exit(.runtimeFailure))
    }

    @Test
    func runtimeErrorsWriteToStandardError() {
        #expect(interpreter.writesToStandardError(.error("boom")))
        #expect(interpreter.writesToStandardError(.musicAutomationDenied))
        #expect(!interpreter.writesToStandardError(.active("all HID sources")))
    }
}
