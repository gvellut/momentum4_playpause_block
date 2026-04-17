import Foundation
import Momentum4PlayPauseBlockCore
import Testing

@MainActor
struct AppSettingsStoreTests {
    @Test
    func defaultsAreApplied() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let blocker = MockBlockerController()
        let launchController = MockLaunchAtLoginController(status: .disabled)
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: launchController
        )

        #expect(store.blockingEnabled)
        #expect(store.showMenuBarIcon)
        #expect(!store.openAtLogin)
        #expect(store.targetBluetoothAddress == "80:C3:BA:82:06:6B")
    }

    @Test
    func changingBlockingEnabledReappliesBlockerConfiguration() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let blocker = MockBlockerController()
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.refreshRuntimeState()
        store.blockingEnabled = false

        #expect(blocker.configurations.last?.isEnabled == false)
    }

    @Test
    func validAddressDraftUpdatesStoredAddressImmediately() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let store = AppSettingsStore(
            defaults: defaults,
            blocker: MockBlockerController(),
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        #expect(store.updateTargetBluetoothAddress(from: "11-22-33-44-55-66"))
        #expect(store.targetBluetoothAddress == "11:22:33:44:55:66")
    }

    @Test
    func manualLaunchCanForceMenuBarIconVisibleAgain() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: AppSettingsKeys.showMenuBarIcon)

        let store = AppSettingsStore(
            defaults: defaults,
            blocker: MockBlockerController(),
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.restoreMenuBarIconIfNeeded(for: AppLaunchContext(launchedAsLoginItem: false))
        #expect(store.showMenuBarIcon)
    }
}

@MainActor
private final class MockBlockerController: HeadphoneBlockerControlling {
    var statusDidChange: ((BlockerStatus) -> Void)?
    var configurations: [BlockerConfiguration] = []

    func apply(configuration: BlockerConfiguration) {
        configurations.append(configuration)
        statusDidChange?(.disabled)
    }
}

private final class MockLaunchAtLoginController: LaunchAtLoginControlling {
    private let current: LaunchAtLoginStatus

    init(status: LaunchAtLoginStatus) {
        self.current = status
    }

    func currentStatus() -> LaunchAtLoginStatus {
        current
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginStatus {
        enabled ? .enabled : .disabled
    }

    func openSystemSettings() {}
}
