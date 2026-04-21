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
        #expect(!store.blockingRequested)
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
        store.setBlockingEnabled(true)

        #expect(!store.blockingEnabled)
        #expect(!store.blockingRequested)
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
    func enablingWhilePermissionsArePendingKeepsRequestedStateOn() async {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        proxyController.appliedStatus = .requestingPermissions

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.setBlockingRequested(true)
        await Task.yield()

        #expect(!store.blockingEnabled)
        #expect(store.blockingRequested)
        #expect(store.proxyStatus == .requestingPermissions)
        #expect(!store.shouldOfferRelaunchToFinishEnable)
        #expect(proxyController.configurations.last?.enabled == true)
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

        store.setBlockingEnabled(true)
        await Task.yield()

        #expect(!store.blockingEnabled)
        #expect(store.blockingRequested)
        #expect(store.proxyStatus == .inputMonitoringDenied)
        #expect(store.shouldOfferRelaunchToFinishEnable)
        #expect(proxyController.configurations.last?.enabled == true)
    }

    @Test
    func activeStatusIsRequiredBeforeBlockingTurnsOn() async {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        proxyController.appliedStatus = .active("all HID sources")

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.setBlockingEnabled(true)
        await Task.yield()

        #expect(store.blockingEnabled)
        #expect(store.blockingRequested)
        #expect(!store.shouldOfferRelaunchToFinishEnable)
    }

    @Test
    func disablingClearsRequestedAndPendingActivationState() async {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        proxyController.appliedStatus = .inputMonitoringDenied

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.setBlockingRequested(true)
        await Task.yield()

        proxyController.appliedStatus = nil
        store.setBlockingRequested(false)

        #expect(!store.blockingEnabled)
        #expect(!store.blockingRequested)
        #expect(!store.shouldOfferRelaunchToFinishEnable)
        #expect(store.proxyStatus == .disabled)
        #expect(proxyController.configurations.last?.enabled == false)
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
    func captureFailureLeavesControlsUsableAndShowsInlineMessage() async {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.allowedForwardSourceMode = .specificProductName
        store.toggleForwardSourceCapture()
        proxyController.failCapture(message: "Could not read a product name from that source.")
        await Task.yield()

        #expect(!store.isCapturingForwardSource)
        #expect(store.captureFeedbackMessage == "Could not read a product name from that source.")
    }

    @Test
    func manualLaunchWithHiddenIconOpensSettingsWithoutRestoringIcon() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettingsKeys.showMenuBarIcon)
        defaults.set(
            true,
            forKey: AppSettingsKeys.hasExplicitlyConfiguredMenuBarIconVisibility
        )

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
    func legacyHiddenMenuBarStateIsIgnoredUntilUserExplicitlyChoosesIt() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettingsKeys.showMenuBarIcon)

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: MockProxyController(),
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        #expect(store.showMenuBarIcon)
    }

    @Test
    func relaunchRequiredStateRestoresRequestedStateFromDefaults() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: MockProxyController(),
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        #expect(!store.blockingEnabled)
        #expect(store.blockingRequested)
        #expect(store.shouldOfferRelaunchToFinishEnable)
        #expect(store.blockingStatusSummary == "Relaunch required to finish enabling.")
    }

    @Test
    func restartBlockingIfRequestedReappliesProxyAfterRuntimeModeChange() async {
        let defaults = makeDefaults()
        let proxyController = MockProxyController()
        proxyController.appliedStatus = .active("all HID sources")

        let store = AppSettingsStore(
            defaults: defaults,
            proxyController: proxyController,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.setBlockingRequested(true)
        await Task.yield()

        proxyController.appliedStatus = nil
        store.restartBlockingIfRequestedForRuntimeModeChange()

        #expect(proxyController.configurations.suffix(2).map(\.enabled) == [false, true])
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
    var sourceCaptureDidFail: ((String) -> Void)?
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

    func failCapture(message: String) {
        sourceCaptureDidFail?(message)
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
