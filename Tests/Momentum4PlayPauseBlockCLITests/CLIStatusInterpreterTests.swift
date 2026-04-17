@testable import Momentum4PlayPauseBlockCLI
import Momentum4PlayPauseBlockCommon
import Testing

struct CLIStatusInterpreterTests {
    private let interpreter = CLIStatusInterpreter()

    @Test
    func blockingStatusKeepsProcessRunning() {
        #expect(interpreter.action(for: .blocking("MOMENTUM 4")) == .keepRunning)
    }

    @Test
    func permissionDeniedExitsWithRuntimeFailure() {
        #expect(interpreter.action(for: .permissionDenied) == .exit(.runtimeFailure))
    }

    @Test
    func runtimeErrorsWriteToStandardError() {
        #expect(interpreter.writesToStandardError(.error("boom")))
        #expect(!interpreter.writesToStandardError(.waitingForTarget("waiting")))
    }
}
