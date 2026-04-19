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
        #expect(!store.useGenericAudioHeadsetTarget)
        #expect(!store.canEnableBlocking)
        #expect(store.targetCheckResult == nil)
        #expect(blocker.configurations.isEmpty)
    }

    @Test
    func cannotEnableBlockingWithoutAddressInBluetoothAddressMode() {
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
        #expect(blocker.configurations.last?.target == nil)
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
                == BlockerConfiguration(
                    isEnabled: true,
                    target: .bluetoothAddress(targetAddress)
                )
        )
    }

    @Test
    func genericAudioHeadsetModeAllowsBlockingWithoutAddress() {
        let defaults = makeDefaults()
        let blocker = MockBlockerController()
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.useGenericAudioHeadsetTarget = true
        store.blockingEnabled = true

        #expect(store.blockingEnabled)
        #expect(store.canEnableBlocking)
        #expect(
            blocker.configurations.last
                == BlockerConfiguration(isEnabled: true, target: .genericAudioHeadset)
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
    func switchingBackToBluetoothAddressModeDisablesBlockingWithoutAddress() {
        let defaults = makeDefaults()
        let blocker = MockBlockerController()
        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.useGenericAudioHeadsetTarget = true
        store.blockingEnabled = true

        #expect(store.blockingEnabled)

        store.useGenericAudioHeadsetTarget = false

        #expect(!store.blockingEnabled)
        #expect(!store.canEnableBlocking)
        #expect(blocker.configurations.last == BlockerConfiguration(isEnabled: false, target: nil))
    }

    @Test
    func targetCheckUsesCurrentSelection() {
        let defaults = makeDefaults()
        let blocker = MockBlockerController()
        let expectedResult = BlockerCheckResult(
            target: .genericAudioHeadset,
            matchedDevice: HIDDeviceSnapshot(
                transport: "Audio",
                manufacturer: "Apple",
                product: "Headset",
                serialNumber: nil,
                usagePage: 12,
                usage: 1,
                locationID: nil
            ),
            message: "Found matching media-control HID endpoint for generic Audio / Headset."
        )
        blocker.nextCheckResult = expectedResult

        let store = AppSettingsStore(
            defaults: defaults,
            blocker: blocker,
            launchAtLoginController: MockLaunchAtLoginController(status: .disabled)
        )

        store.useGenericAudioHeadsetTarget = true
        store.runTargetCheck()

        #expect(blocker.checkedTargets == [.genericAudioHeadset])
        #expect(store.targetCheckResult == expectedResult)
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
    var checkedTargets: [BlockerTarget?] = []
    var nextCheckResult = BlockerCheckResult(
        target: nil,
        matchedDevice: nil,
        message: "No target configured."
    )

    func apply(configuration: BlockerConfiguration) {
        configurations.append(configuration)
        statusDidChange?(.disabled)
    }

    func check(target: BlockerTarget?) -> BlockerCheckResult {
        checkedTargets.append(target)
        return nextCheckResult
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
