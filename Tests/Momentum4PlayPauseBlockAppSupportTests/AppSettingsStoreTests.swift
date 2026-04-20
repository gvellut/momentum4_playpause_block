import Foundation
import Momentum4PlayPauseBlockAppSupport
import Momentum4PlayPauseBlockCommon
import Testing

@MainActor
struct AppSettingsStoreTests {
    @Test
    func defaultsUseAnyHIDAndDoNotEnableBlocking() {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        #expect(!store.blockingEnabled)
        #expect(store.showMenuBarIcon)
        #expect(!store.openAtLogin)
        #expect(store.allowedForwardSourceMode == .anyHID)
        #expect(store.allowedForwardSourceProductName.isEmpty)
        #expect(store.canEnableBlocking)
        #expect(proxyController.configurations.isEmpty)
    }

    @Test
    func specificProductModeRequiresNonEmptyNameBeforeEnabling() {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.allowedForwardSourceMode = .specificProductName
        store.blockingEnabled = true

        #expect(!store.blockingEnabled)
        #expect(!store.canEnableBlocking)
        #expect(
            proxyController.configurations.last
                == PlaybackProxyConfiguration(
                    enabled: false,
                    allowedForwardSourceMode: .specificProductName,
                    allowedForwardSourceProductName: ""
                )
        )
    }

    @Test
    func enablingWithDeniedPermissionSurfacesProxyStatus() async {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        proxyController.appliedStatus = .inputMonitoringDenied

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.blockingEnabled = true
        await Task.yield()

        #expect(store.blockingEnabled)
        #expect(store.proxyStatus == .inputMonitoringDenied)
        #expect(proxyController.configurations.last?.enabled == true)
    }

    @Test
    func sourceCaptureFillsProductNameAndSwitchesMode() async {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.toggleForwardSourceCapture()
        proxyController.resolveCapture(productName: "Keychron K1 Pro")
        await Task.yield()

        #expect(!store.isCapturingForwardSource)
        #expect(store.allowedForwardSourceMode == .specificProductName)
        #expect(store.allowedForwardSourceProductName == "Keychron K1 Pro")
        #expect(store.canEnableBlocking)
    }

    @Test
    func manualLaunchWithHiddenIconOpensSettingsWithoutRestoringIcon() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettingsKeys.showMenuBarIcon)

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: MockProxyController(),
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        #expect(
            store.shouldOpenSettingsOnLaunch(for: AppLaunchContext(launchedAsLoginItem: false))
        )
        #expect(!store.showMenuBarIcon)
        #expect(store.shouldOpenSettingsOnReopen())
    }

    @Test
    func openAtLoginRequestsAreStillForwardedToController() {
        let defaults = makeDefaults()
        let launchController = MockLaunchAtLoginController(status: .disabled)
        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: MockProxyController(),
            launchAtLoginController: launchController
        )

        store.openAtLogin = true

        #expect(store.openAtLogin)
        #expect(launchController.setEnabledCalls == [true])
        #expect(store.launchAtLoginStatus == .enabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class MockProxyController: PlaybackProxyControlling {
    var statusDidChange: ((PlaybackProxyStatus) -> Void)?
    var sourceCaptureDidResolve: ((String) -> Void)?
    var configurations: [PlaybackProxyConfiguration] = []
    var appliedStatus: PlaybackProxyStatus?
    var beginSourceCaptureResult = true
    var beginSourceCaptureCalls = 0
    var cancelSourceCaptureCalls = 0

    func apply(configuration: PlaybackProxyConfiguration) {
        configurations.append(configuration)

        if let appliedStatus {
            statusDidChange?(appliedStatus)
        }
    }

    func beginSourceCapture() -> Bool {
        beginSourceCaptureCalls += 1
        return beginSourceCaptureResult
    }

    func cancelSourceCapture() {
        cancelSourceCaptureCalls += 1
    }

    func resolveCapture(productName: String) {
        sourceCaptureDidResolve?(productName)
    }
}

private final class MockLaunchAtLoginController: LaunchAtLoginControlling {
    private let current: LaunchAtLoginStatus
    private(set) var setEnabledCalls: [Bool] = []

    init(status: LaunchAtLoginStatus) {
        self.current = status
    }

    func currentStatus() -> LaunchAtLoginStatus {
        current
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginStatus {
        setEnabledCalls.append(enabled)
        return enabled ? .enabled : .disabled
    }

    func openSystemSettings() {}
}
