@preconcurrency import AppKit
import Foundation

@MainActor
public protocol AppActionHandling: AnyObject {
    func openSettings()
    func relaunchApplication()
    func registerOpenSettingsHandler(_ handler: @escaping @MainActor () -> Void)
}

public struct WorkspaceApplicationOpenConfiguration: Equatable, Sendable {
    public var activates: Bool
    public var createsNewApplicationInstance: Bool

    public init(
        activates: Bool = true,
        createsNewApplicationInstance: Bool = false
    ) {
        self.activates = activates
        self.createsNewApplicationInstance = createsNewApplicationInstance
    }
}

@MainActor
public protocol ApplicationControlling: AnyObject {
    func activate(ignoringOtherApps: Bool)
    func terminate()
    func beep()
}

@MainActor
public protocol WorkspaceApplicationOpening: AnyObject {
    func openApplication(
        at url: URL,
        configuration: WorkspaceApplicationOpenConfiguration,
        completionHandler: @escaping @Sendable (Error?) -> Void
    )
}

public protocol ProcessSpawning: AnyObject {
    func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL
    ) throws
}

@MainActor
public protocol ApplicationRelaunching: AnyObject {
    @discardableResult
    func relaunch() -> Bool
}

@MainActor
public final class AppActionController: AppActionHandling {
    private let application: any ApplicationControlling
    private let relauncher: any ApplicationRelaunching
    private var openSettingsHandler: (@MainActor () -> Void)?
    private var hasPendingOpenSettingsRequest = false

    public convenience init() {
        let application = SystemApplicationController()
        self.init(
            application: application,
            relauncher: ApplicationRelauncher(application: application)
        )
    }

    init(
        application: any ApplicationControlling,
        relauncher: any ApplicationRelaunching
    ) {
        self.application = application
        self.relauncher = relauncher
    }

    public func registerOpenSettingsHandler(_ handler: @escaping @MainActor () -> Void) {
        openSettingsHandler = handler

        guard hasPendingOpenSettingsRequest else {
            return
        }

        hasPendingOpenSettingsRequest = false
        openSettings()
    }

    public func openSettings() {
        application.activate(ignoringOtherApps: true)

        guard let openSettingsHandler else {
            hasPendingOpenSettingsRequest = true
            return
        }

        openSettingsHandler()
        application.activate(ignoringOtherApps: true)
    }

    public func relaunchApplication() {
        _ = relauncher.relaunch()
    }
}

@MainActor
public final class ApplicationRelauncher: ApplicationRelaunching {
    private let application: any ApplicationControlling
    private let workspace: any WorkspaceApplicationOpening
    private let processSpawner: any ProcessSpawning
    private let bundleURLProvider: () -> URL
    private let executableURLProvider: () -> URL?
    private let launchArgumentsProvider: () -> [String]
    private let environmentProvider: () -> [String: String]
    private let currentDirectoryURLProvider: () -> URL

    public convenience init(application: any ApplicationControlling) {
        self.init(
            application: application,
            workspace: SystemWorkspaceApplicationOpener(),
            processSpawner: SystemProcessSpawner(),
            bundleURLProvider: { Bundle.main.bundleURL },
            executableURLProvider: { Bundle.main.executableURL },
            launchArgumentsProvider: { ProcessInfo.processInfo.arguments },
            environmentProvider: { ProcessInfo.processInfo.environment },
            currentDirectoryURLProvider: {
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            }
        )
    }

    init(
        application: any ApplicationControlling,
        workspace: any WorkspaceApplicationOpening,
        processSpawner: any ProcessSpawning,
        bundleURLProvider: @escaping () -> URL,
        executableURLProvider: @escaping () -> URL?,
        launchArgumentsProvider: @escaping () -> [String],
        environmentProvider: @escaping () -> [String: String],
        currentDirectoryURLProvider: @escaping () -> URL
    ) {
        self.application = application
        self.workspace = workspace
        self.processSpawner = processSpawner
        self.bundleURLProvider = bundleURLProvider
        self.executableURLProvider = executableURLProvider
        self.launchArgumentsProvider = launchArgumentsProvider
        self.environmentProvider = environmentProvider
        self.currentDirectoryURLProvider = currentDirectoryURLProvider
    }

    @discardableResult
    public func relaunch() -> Bool {
        let bundleURL = bundleURLProvider()
        let applicationHandle = SendableApplicationHandle(application: application)

        if bundleURL.pathExtension == "app" {
            workspace.openApplication(
                at: bundleURL,
                configuration: WorkspaceApplicationOpenConfiguration(
                    activates: true,
                    createsNewApplicationInstance: true
                )
            ) { [applicationHandle] error in
                Task { @MainActor in
                    if error == nil {
                        applicationHandle.application.terminate()
                    } else {
                        applicationHandle.application.beep()
                    }
                }
            }
            return true
        }

        let launchArguments = launchArgumentsProvider()
        let executableURL =
            executableURLProvider()
            ?? URL(
                fileURLWithPath: launchArguments.first
                    ?? ProcessInfo.processInfo.arguments[0]
            )

        do {
            try processSpawner.spawn(
                executableURL: executableURL,
                arguments: Array(launchArguments.dropFirst()),
                environment: environmentProvider(),
                currentDirectoryURL: currentDirectoryURLProvider()
            )
            application.terminate()
            return true
        } catch {
            application.beep()
            return false
        }
    }
}

private struct SendableApplicationHandle: @unchecked Sendable {
    let application: any ApplicationControlling
}

@MainActor
private final class SystemApplicationController: ApplicationControlling {
    func activate(ignoringOtherApps: Bool) {
        NSApplication.shared.activate(ignoringOtherApps: ignoringOtherApps)
    }

    func terminate() {
        NSApplication.shared.terminate(nil)
    }

    func beep() {
        NSSound.beep()
    }
}

@MainActor
private final class SystemWorkspaceApplicationOpener: WorkspaceApplicationOpening {
    func openApplication(
        at url: URL,
        configuration: WorkspaceApplicationOpenConfiguration,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = configuration.activates
        openConfiguration.createsNewApplicationInstance =
            configuration.createsNewApplicationInstance

        NSWorkspace.shared.openApplication(at: url, configuration: openConfiguration) {
            _, error in
            completionHandler(error)
        }
    }
}

private final class SystemProcessSpawner: ProcessSpawning {
    func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        try process.run()
    }
}
