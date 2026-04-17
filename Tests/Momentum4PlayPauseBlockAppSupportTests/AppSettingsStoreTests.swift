import Foundation
import Momentum4PlayPauseBlockAppSupport
import Momentum4PlayPauseBlockCommon
import Testing

@MainActor
struct AppSettingsStoreTests {
    @Test
    func defaultsAreApplied() {
        let defaults = makeDefaults()

        let blocker = MockBlockerController()
        let launchController = MockLaunchAtLoginController(status: .disabled)
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: launchController
        )

        #expect(!store.blockingEnabled)
        #expect(store.showMenuBarIcon)
        #expect(!store.openAtLogin)
        #expect(store.targetBluetoothAddress.isEmpty)
        #expect(!store.canEnableBlocking)
        #expect(blocker.configurations.isEmpty)
    }

    @Test
    func cannotEnableBlockingWithoutAddress() {
        let defaults = makeDefaults()
        let blocker = MockBlockerController()
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.refreshRuntimeState()
        store.blockingEnabled = true

        #expect(!store.blockingEnabled)
        #expect(!store.canEnableBlocking)
        #expect(blocker.configurations.last?.isEnabled == false)
        #expect(blocker.configurations.last?.targetAddress == nil)
    }

    @Test
    func validAddressAllowsBlockingToBeEnabled() {
        let defaults = makeDefaults()
        let blocker = MockBlockerController()
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        let targetAddress = BluetoothAddress(normalizing: "11-22-33-44-55-66")!
        #expect(store.updateTargetBluetoothAddressDraft(targetAddress.rawValue))

        store.blockingEnabled = true

        #expect(store.blockingEnabled)
        #expect(store.canEnableBlocking)
        #expect(store.targetBluetoothAddress == targetAddress.rawValue)
        #expect(
            blocker.configurations.last
                == BlockerConfiguration(isEnabled: true, targetAddress: targetAddress)
        )
    }

    @Test
    func clearingAddressDisablesBlockingImmediately() {
        let defaults = makeDefaults()
        let blocker = MockBlockerController()
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        #expect(store.updateTargetBluetoothAddressDraft("11-22-33-44-55-66"))
        store.blockingEnabled = true

        #expect(store.blockingEnabled)

        _ = store.updateTargetBluetoothAddressDraft("")

        #expect(store.targetBluetoothAddress.isEmpty)
        #expect(!store.canEnableBlocking)
        #expect(!store.blockingEnabled)
        #expect(blocker.configurations.last?.isEnabled == false)
    }

    @Test
    func firstLaunchHandlerRunsOnlyOnce() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: MockBlockerController(),
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        var showSettingsCallCount = 0
        store.handleFirstLaunchIfNeeded {
            showSettingsCallCount += 1
        }
        store.handleFirstLaunchIfNeeded {
            showSettingsCallCount += 1
        }

        #expect(showSettingsCallCount == 1)
    }

    @Test
    func manualLaunchCanForceMenuBarIconVisibleAgain() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppSettingsKeys.showMenuBarIcon)

        let store = AppSettingsStore(
            defaults: defaults,
            blocker: MockBlockerController(),
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.restoreMenuBarIconIfNeeded(for: AppLaunchContext(launchedAsLoginItem: false))
        #expect(store.showMenuBarIcon)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
