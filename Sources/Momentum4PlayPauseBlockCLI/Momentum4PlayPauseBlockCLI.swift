import AppKit
import Dispatch
import Foundation
import Momentum4PlayPauseBlockCommon

@main
struct Momentum4PlayPauseBlockCLIExecutable {
    @MainActor
    static func main() {
        let cocoaApplication = NSApplication.shared
        cocoaApplication.setActivationPolicy(.prohibited)

        let executableName = URL(
            fileURLWithPath: CommandLine.arguments.first ?? "Momentum4PlayPauseBlockCLI"
        ).lastPathComponent

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
    private static let diagnosticTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private let arguments: CLIArguments
    private let proxyController: PlaybackProxyControlling
    private let statusInterpreter = CLIStatusInterpreter()
    private var signalSources: [DispatchSourceSignal] = []
    private var lastReportedStatus: PlaybackProxyStatus?
    private var isStopping = false

    init(
        arguments: CLIArguments,
        proxyController: PlaybackProxyControlling = PlaybackProxyService()
    ) {
        self.arguments = arguments
        self.proxyController = proxyController
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
        for line in startupMessages {
            writeLine(line)
        }

        if let proxyService = proxyController as? PlaybackProxyService {
            proxyService.diagnosticDidEmit = { [weak self] event in
                Task { @MainActor in
                    self?.handle(diagnosticEvent: event)
                }
            }
        }

        proxyController.statusDidChange = { [weak self] status in
            Task { @MainActor in
                self?.handle(status: status)
            }
        }

        proxyController.apply(configuration: arguments.configuration)
    }

    private func handle(status: PlaybackProxyStatus) {
        guard !isStopping, lastReportedStatus != status else {
            return
        }

        lastReportedStatus = status
        writeLine(status.message, toStandardError: statusInterpreter.writesToStandardError(status))

        if case .exit(let exitCode) = statusInterpreter.action(for: status) {
            finish(exitCode)
        }
    }

    private func handle(diagnosticEvent: PlaybackProxyDiagnosticEvent) {
        guard !isStopping else {
            return
        }

        writeLine(
            "[diag \(Self.diagnosticTimestampFormatter.string(from: Date()))] \(diagnosticMessage(for: diagnosticEvent))"
        )
    }

    private func stop() {
        guard !isStopping else {
            return
        }

        isStopping = true
        writeLine("Stopping.")
        proxyController.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: false,
                allowedForwardSourceMode: arguments.allowedForwardSourceMode,
                allowedForwardSourceProductName: arguments.allowedForwardSourceProductName
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

    private func diagnosticMessage(for event: PlaybackProxyDiagnosticEvent) -> String {
        switch event {
        case .systemWillSleep:
            return "system will sleep"
        case .systemDidWake:
            return "system did wake"
        case .screensDidSleep:
            return "screens did sleep"
        case .screensDidWake:
            return "screens did wake"
        case .mediaRemoteNotification(let notificationName):
            return "mediaremote notification \(notificationName)"
        case .timedBackstopTick(let interval):
            return "timed ownership backstop tick (\(CLIArguments.formattedSeconds(interval)))"
        case .ownershipReclaimStarted(let reason):
            return "ownership reclaim started: \(diagnosticReasonMessage(reason))"
        case .ownershipReclaimSkippedCooldown(let reason, let cooldown):
            return
                "ownership reclaim skipped due to cooldown (\(CLIArguments.formattedSeconds(cooldown))): \(diagnosticReasonMessage(reason))"
        case .ownershipReclaimSkippedSleepSuspended(let reason):
            return "ownership reclaim skipped while sleep suspended: \(diagnosticReasonMessage(reason))"
        case .ownershipReclaimSucceeded(let reason):
            return "ownership reclaim succeeded: \(diagnosticReasonMessage(reason))"
        case .ownershipReclaimFailed(let reason, let message):
            return "ownership reclaim failed: \(diagnosticReasonMessage(reason)); \(message)"
        }
    }

    private func diagnosticReasonMessage(_ reason: PlaybackProxyOwnershipReclaimReason) -> String {
        switch reason {
        case .forwardedCommand:
            return "post-forward reclaim"
        case .systemDidWake:
            return "system wake"
        case .screensDidWake:
            return "screens wake"
        case .mediaRemoteNotification(let notificationName):
            return "mediaremote notification \(notificationName)"
        case .timedBackstopTick(let interval):
            return "timed backstop tick (\(CLIArguments.formattedSeconds(interval)))"
        case .missingExpectedRemoteCommand(let sourceLabel, let correlationWindow):
            return
                "expected remote command did not arrive after HID press from \(sourceLabel) within \(CLIArguments.formattedSeconds(correlationWindow))"
        }
    }

    private var startupMessages: [String] {
        [
            "Running the Apple Music-only play/pause proxy. Forwarding is allowed from \(arguments.startupDescription). Press Control-C to stop.",
            arguments.ownershipReclaimDescription,
            "Sleep/wake diagnostics are enabled in this CLI so system sleep, screen sleep, wake, and reclaim reasons are logged.",
            "Hidden AppKit bootstrap is active so this CLI can own media commands through MPRemoteCommandCenter.",
        ]
    }
}
