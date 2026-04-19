import Combine
import Foundation
import Momentum4PlayPauseBlockCommon

@MainActor
public final class AppSettingsStore: ObservableObject {
    @Published public var blockingEnabled: Bool {
        didSet {
            guard !suppressSideEffects, oldValue != blockingEnabled else {
                return
            }

            guard !blockingEnabled || canEnableBlocking else {
                setBlockingEnabledWithoutSideEffects(false)
                defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
                applyBlockerConfiguration()
                return
            }

            defaults.set(blockingEnabled, forKey: AppSettingsKeys.blockingEnabled)
            applyBlockerConfiguration()
        }
    }

    @Published public var showMenuBarIcon: Bool {
        didSet {
            guard !suppressSideEffects, oldValue != showMenuBarIcon else {
                return
            }

            defaults.set(showMenuBarIcon, forKey: AppSettingsKeys.showMenuBarIcon)
        }
    }

    @Published public var openAtLogin: Bool {
        didSet {
            guard !suppressSideEffects, oldValue != openAtLogin else {
                return
            }

            handleLaunchAtLoginChange(requestedEnabled: openAtLogin)
        }
    }

    @Published public var useGenericAudioHeadsetTarget: Bool {
        didSet {
            guard !suppressSideEffects, oldValue != useGenericAudioHeadsetTarget else {
                return
            }

            defaults.set(
                useGenericAudioHeadsetTarget,
                forKey: AppSettingsKeys.useGenericAudioHeadsetTarget
            )
            targetCheckResult = nil

            if blockingEnabled && !canEnableBlocking {
                setBlockingEnabledWithoutSideEffects(false)
                defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
            }

            applyBlockerConfiguration()
        }
    }

    @Published public private(set) var targetBluetoothAddress: String {
        didSet {
            guard !suppressSideEffects, oldValue != targetBluetoothAddress else {
                return
            }

            defaults.set(targetBluetoothAddress, forKey: AppSettingsKeys.targetBluetoothAddress)
            targetCheckResult = nil

            if blockingEnabled && !canEnableBlocking {
                setBlockingEnabledWithoutSideEffects(false)
                defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
            }

            applyBlockerConfiguration()
        }
    }

    @Published public private(set) var blockerStatus: BlockerStatus = .disabled
    @Published public private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published public private(set) var targetCheckResult: BlockerCheckResult?

    public var canEnableBlocking: Bool {
        useGenericAudioHeadsetTarget || configuredTargetBluetoothAddress != nil
    }

    public var configuredTargetBluetoothAddress: BluetoothAddress? {
        BluetoothAddress(normalizing: targetBluetoothAddress)
    }

    public var selectedTarget: BlockerTarget? {
        if useGenericAudioHeadsetTarget {
            return .genericAudioHeadset
        }

        return configuredTargetBluetoothAddress.map(BlockerTarget.bluetoothAddress)
    }

    private let defaults: UserDefaults
    private let blocker: HeadphoneBlockerControlling
    private let launchAtLoginController: LaunchAtLoginControlling
    private var suppressSideEffects = false

    public init(
        defaults: UserDefaults = .standard,
        blocker: HeadphoneBlockerControlling? = nil,
        launchAtLoginController: LaunchAtLoginControlling? = nil
    ) {
        self.defaults = defaults
        self.blocker = blocker ?? HeadphoneBlockerService()
        self.launchAtLoginController = launchAtLoginController ?? LaunchAtLoginController()

        let storedAddress = BluetoothAddress.sanitizeUserEntry(
            defaults.string(forKey: AppSettingsKeys.targetBluetoothAddress) ?? ""
        )
        let storedUseGenericTarget =
            defaults.object(forKey: AppSettingsKeys.useGenericAudioHeadsetTarget) as? Bool ?? false
        let storedBlockingEnabled = defaults.object(forKey: AppSettingsKeys.blockingEnabled) as? Bool ?? false

        self.targetBluetoothAddress = storedAddress
        self.useGenericAudioHeadsetTarget = storedUseGenericTarget
        self.blockingEnabled =
            storedBlockingEnabled
            && (storedUseGenericTarget || BluetoothAddress(normalizing: storedAddress) != nil)
        self.showMenuBarIcon = defaults.object(forKey: AppSettingsKeys.showMenuBarIcon) as? Bool ?? true
        self.openAtLogin = defaults.object(forKey: AppSettingsKeys.openAtLogin) as? Bool ?? false
        self.launchAtLoginStatus = self.launchAtLoginController.currentStatus()

        if self.blockingEnabled != storedBlockingEnabled {
            defaults.set(self.blockingEnabled, forKey: AppSettingsKeys.blockingEnabled)
        }

        self.blocker.statusDidChange = { [weak self] status in
            Task { @MainActor in
                self?.blockerStatus = status
            }
        }
    }

    public func refreshRuntimeState() {
        launchAtLoginStatus = launchAtLoginController.currentStatus()
        applyBlockerConfiguration()
    }

    public func handleFirstLaunchIfNeeded(showSettings: () -> Void) {
        let hasLaunchedBefore = defaults.bool(forKey: AppSettingsKeys.hasLaunchedBefore)
        guard !hasLaunchedBefore else {
            return
        }

        showSettings()
        defaults.set(true, forKey: AppSettingsKeys.hasLaunchedBefore)
    }

    public func restoreMenuBarIconIfNeeded(for launchContext: AppLaunchContext) {
        guard launchContext.shouldForceShowMenuBarIcon(currentlyVisible: showMenuBarIcon) else {
            return
        }

        showMenuBarIcon = true
    }

    public func handleApplicationReopen() {
        guard !showMenuBarIcon else {
            return
        }

        showMenuBarIcon = true
    }

    @discardableResult
    public func updateTargetBluetoothAddressDraft(_ draft: String) -> Bool {
        targetBluetoothAddress = BluetoothAddress.sanitizeUserEntry(draft)
        return canEnableBlocking
    }

    public func sanitizedTargetBluetoothAddressDraft(_ draft: String) -> String {
        BluetoothAddress.sanitizeUserEntry(draft)
    }

    public func targetBluetoothAddressValidationMessage(for draft: String) -> String {
        if useGenericAudioHeadsetTarget {
            return "Generic Audio / Headset mode ignores the Bluetooth address field."
        }

        let sanitizedDraft = BluetoothAddress.sanitizeUserEntry(draft)

        guard !sanitizedDraft.isEmpty else {
            return "Enter a Bluetooth address to enable blocking."
        }

        if let normalized = BluetoothAddress(normalizing: sanitizedDraft) {
            if normalized.rawValue == targetBluetoothAddress {
                return "Blocking can be enabled for \(normalized.rawValue)."
            }

            return "The blocker will use \(normalized.rawValue) once you enable it."
        }

        return "Enter a full Bluetooth address like 80:C3:BA:82:06:6B."
    }

    public func runTargetCheck() {
        targetCheckResult = blocker.check(target: selectedTarget)
    }

    public func openLoginItemsSystemSettings() {
        launchAtLoginController.openSystemSettings()
    }

    private func applyBlockerConfiguration() {
        blocker.apply(
            configuration: BlockerConfiguration(
                isEnabled: blockingEnabled && canEnableBlocking,
                target: selectedTarget
            )
        )
    }

    private func handleLaunchAtLoginChange(requestedEnabled: Bool) {
        defaults.set(requestedEnabled, forKey: AppSettingsKeys.openAtLogin)

        let status = launchAtLoginController.setEnabled(requestedEnabled)
        launchAtLoginStatus = status

        let shouldKeepRequestedValue: Bool
        if requestedEnabled {
            shouldKeepRequestedValue = status.isApprovedOrPendingApproval
        } else {
            shouldKeepRequestedValue = status == .disabled
        }

        guard shouldKeepRequestedValue else {
            setOpenAtLoginWithoutSideEffects(!requestedEnabled)
            defaults.set(!requestedEnabled, forKey: AppSettingsKeys.openAtLogin)
            return
        }
    }

    private func setBlockingEnabledWithoutSideEffects(_ value: Bool) {
        suppressSideEffects = true
        blockingEnabled = value
        suppressSideEffects = false
    }

    private func setOpenAtLoginWithoutSideEffects(_ value: Bool) {
        suppressSideEffects = true
        openAtLogin = value
        suppressSideEffects = false
    }
}
