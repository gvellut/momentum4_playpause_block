import Dispatch
import Foundation
import Momentum4PlayPauseBlockCommon

@main
struct Momentum4PlayPauseBlockCLIExecutable {
    @MainActor
    static func main() {
        let executableName = URL(fileURLWithPath: CommandLine.arguments.first ?? "Momentum4PlayPauseBlockCLI")
            .lastPathComponent

        let parsedArguments: CLIArguments
        do {
            parsedArguments = try CLIArgumentParser().parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as CLIArgumentParserError {
            if error == .helpRequested {
                print(CLIUsage.helpText(executableName: executableName))
                Foundation.exit(CLIExitCode.success.rawValue)
            }

            fputs("\(error.description)\n\n", stderr)
            fputs("\(CLIUsage.helpText(executableName: executableName))\n", stderr)
            Foundation.exit(CLIExitCode.usageFailure.rawValue)
        } catch {
            fputs("Unexpected CLI error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(CLIExitCode.runtimeFailure.rawValue)
        }

        let application = CLIApplication(arguments: parsedArguments)
        application.installSignalHandlers()
        application.start()
        RunLoop.main.run() 
    }
}

@MainActor
final class CLIApplication {
    private let arguments: CLIArguments
    private let blocker: HeadphoneBlockerControlling
    private let statusInterpreter = CLIStatusInterpreter()
    private var signalSources: [DispatchSourceSignal] = []
    private var lastReportedStatus: BlockerStatus?
    private var isStopping = false

    init(
        arguments: CLIArguments,
        blocker: HeadphoneBlockerControlling = HeadphoneBlockerService()
    ) {
        self.arguments = arguments
        self.blocker = blocker
    }

    func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.stop()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func start() {
        writeLine(startupMessage)

        blocker.statusDidChange = { [weak self] status in
            Task { @MainActor in
                self?.handle(status: status)
            }
        }
        blocker.inputEventDidReceive = { [weak self] event in
            Task { @MainActor in
                self?.handle(inputEvent: event)
            }
        }

        blocker.apply(
            configuration: BlockerConfiguration(
                isEnabled: true,
                target: arguments.target,
                operationMode: arguments.operationMode
            )
        )
    }

    private func handle(status: BlockerStatus) {
        guard !isStopping, lastReportedStatus != status else {
            return
        }

        lastReportedStatus = status
        writeLine(status.message, toStandardError: statusInterpreter.writesToStandardError(status))

        if case .exit(let exitCode) = statusInterpreter.action(for: status) {
            finish(exitCode)
        }
    }

    private func stop() {
        guard !isStopping else {
            return
        }

        isStopping = true
        writeLine("Stopping.")
        blocker.apply(
            configuration: BlockerConfiguration(
                isEnabled: false,
                target: arguments.target,
                operationMode: arguments.operationMode
            )
        )
        finish(.success)
    }

    private func finish(_ exitCode: CLIExitCode) {
        fflush(stdout)
        fflush(stderr)
        Foundation.exit(exitCode.rawValue)
    }

    private func writeLine(_ message: String, toStandardError: Bool = false) {
        let stream = toStandardError ? stderr : stdout
        fputs("\(message)\n", stream)
    }

    private var startupMessage: String {
        switch arguments.operationMode {
        case .block:
            return
                "Blocking consumer-control events for \(arguments.startupDescription). Press Control-C to stop."
        case .logEvents:
            return
                "Logging consumer-control events for \(arguments.startupDescription). Press Control-C to stop."
        }
    }

    private func handle(inputEvent: HIDInputEvent) {
        guard arguments.operationMode == .logEvents else {
            return
        }

        writeLine(formatted(inputEvent: inputEvent))
    }

    private func formatted(inputEvent: HIDInputEvent) -> String {
        let deviceSummary = inputEvent.device.displaySummary.isEmpty
            ? (inputEvent.device.product ?? "Unknown Device")
            : inputEvent.device.displaySummary
        let label = inputEvent.actionLabel ?? "Unknown"

        return
            "Event action=\(label) usagePage=\(inputEvent.usagePage) usage=\(inputEvent.usage) value=\(inputEvent.value) timestamp=\(inputEvent.timestamp) device=\(deviceSummary)"
    }
}
