@testable import Momentum4PlayPauseBlockAppSupport
import Foundation
import Testing

@MainActor
struct AppActionControllerTests {
    @Test
    func openSettingsUsesSharedSettingsWindowAction() {
        let application = MockApplicationController()
        let relauncher = MockApplicationRelauncher()
        let controller = AppActionController(
            application: application,
            relauncher: relauncher
        )
        controller.registerOpenSettingsHandler {
            application.openSettingsCalls += 1
        }

        controller.openSettings()

        #expect(application.activateCalls == [true, true])
        #expect(application.openSettingsCalls == 1)
        #expect(application.beepCalls == 0)
    }

    @Test
    func pendingOpenSettingsRequestRunsAfterHandlerRegisters() {
        let application = MockApplicationController()
        let relauncher = MockApplicationRelauncher()
        let controller = AppActionController(
            application: application,
            relauncher: relauncher
        )

        controller.openSettings()
        #expect(application.openSettingsCalls == 0)

        controller.registerOpenSettingsHandler {
            application.openSettingsCalls += 1
        }

        #expect(application.openSettingsCalls == 1)
    }

    @Test
    func relaunchingBundleRequestsFreshInstanceBeforeTermination() async {
        let application = MockApplicationController()
        let workspace = MockWorkspaceApplicationOpener()
        let processSpawner = MockProcessSpawner()
        let bundleURL = URL(fileURLWithPath: "/Applications/Momentum4PlayPauseBlock.app")
        let relauncher = ApplicationRelauncher(
            application: application,
            workspace: workspace,
            processSpawner: processSpawner,
            bundleURLProvider: { bundleURL },
            executableURLProvider: { nil },
            launchArgumentsProvider: { ["/tmp/Momentum4PlayPauseBlock"] },
            environmentProvider: { [:] },
            currentDirectoryURLProvider: { URL(fileURLWithPath: "/tmp") }
        )

        #expect(relauncher.relaunch())

        let call = try! #require(workspace.openCalls.first)
        #expect(call.url == bundleURL)
        #expect(
            call.configuration
                == WorkspaceApplicationOpenConfiguration(
                    activates: true,
                    createsNewApplicationInstance: true
                )
        )
        #expect(application.terminateCalls == 0)
        #expect(processSpawner.spawnCalls.isEmpty)

        call.completionHandler(nil)
        await Task.yield()

        #expect(application.terminateCalls == 1)
        #expect(application.beepCalls == 0)
    }

    @Test
    func relaunchingDebugBinarySpawnsReplacementBeforeTermination() {
        let application = MockApplicationController()
        let workspace = MockWorkspaceApplicationOpener()
        let processSpawner = MockProcessSpawner()
        let executableURL = URL(fileURLWithPath: "/tmp/Momentum4PlayPauseBlock")
        let relauncher = ApplicationRelauncher(
            application: application,
            workspace: workspace,
            processSpawner: processSpawner,
            bundleURLProvider: { executableURL },
            executableURLProvider: { executableURL },
            launchArgumentsProvider: { ["/tmp/Momentum4PlayPauseBlock", "--flag"] },
            environmentProvider: { ["EXAMPLE": "1"] },
            currentDirectoryURLProvider: { URL(fileURLWithPath: "/tmp/project") }
        )

        #expect(relauncher.relaunch())

        let call = try! #require(processSpawner.spawnCalls.first)
        #expect(call.executableURL == executableURL)
        #expect(call.arguments == ["--flag"])
        #expect(call.environment == ["EXAMPLE": "1"])
        #expect(call.currentDirectoryURL == URL(fileURLWithPath: "/tmp/project"))
        #expect(application.terminateCalls == 1)
        #expect(application.beepCalls == 0)
        #expect(workspace.openCalls.isEmpty)
    }
}

@MainActor
private final class MockApplicationController: ApplicationControlling {
    private(set) var activateCalls: [Bool] = []
    var openSettingsCalls = 0
    private(set) var terminateCalls = 0
    private(set) var beepCalls = 0

    func activate(ignoringOtherApps: Bool) {
        activateCalls.append(ignoringOtherApps)
    }

    func terminate() {
        terminateCalls += 1
    }

    func beep() {
        beepCalls += 1
    }
}

@MainActor
private final class MockApplicationRelauncher: ApplicationRelaunching {
    private(set) var relaunchCalls = 0

    @discardableResult
    func relaunch() -> Bool {
        relaunchCalls += 1
        return true
    }
}

@MainActor
private final class MockWorkspaceApplicationOpener: WorkspaceApplicationOpening {
    struct OpenCall {
        let url: URL
        let configuration: WorkspaceApplicationOpenConfiguration
        let completionHandler: @Sendable (Error?) -> Void
    }

    private(set) var openCalls: [OpenCall] = []

    func openApplication(
        at url: URL,
        configuration: WorkspaceApplicationOpenConfiguration,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        openCalls.append(
            OpenCall(
                url: url,
                configuration: configuration,
                completionHandler: completionHandler
            )
        )
    }
}

private final class MockProcessSpawner: ProcessSpawning {
    struct SpawnCall: Equatable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectoryURL: URL
    }

    private(set) var spawnCalls: [SpawnCall] = []

    func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL
    ) throws {
        spawnCalls.append(
            SpawnCall(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL
            )
        )
    }
}
