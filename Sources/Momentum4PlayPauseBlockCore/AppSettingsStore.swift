import Combine
import Foundation

@MainActor
public final class AppSettingsStore: ObservableObject {
    @Published public var blockingEnabled: Bool {
        didSet {
            guard !suppressSideEffects, oldValue != blockingEnabled else {
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

    @Published public private(set) var targetBluetoothAddress: String {
        didSet {
            guard !suppressSideEffects, oldValue != targetBluetoothAddress else {
                return
            }

            defaults.set(targetBluetoothAddress, forKey: AppSettingsKeys.targetBluetoothAddress)
            applyBlockerConfiguration()
        }
    }

    @Published public private(set) var blockerStatus: BlockerStatus = .disabled
    @Published public private(set) var launchAtLoginStatus: LaunchAtLoginStatus

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

        let storedAddress = defaults.string(forKey: AppSettingsKeys.targetBluetoothAddress)
        let initialAddress = BluetoothAddress(normalizing: storedAddress ?? "")
            ?? .defaultMomentum4

        self.blockingEnabled = defaults.object(forKey: AppSettingsKeys.blockingEnabled) as? Bool ?? true
        self.showMenuBarIcon = defaults.object(forKey: AppSettingsKeys.showMenuBarIcon) as? Bool ?? true
        self.openAtLogin = defaults.object(forKey: AppSettingsKeys.openAtLogin) as? Bool ?? false
        self.targetBluetoothAddress = initialAddress.rawValue
        self.launchAtLoginStatus = self.launchAtLoginController.currentStatus()

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

    public func updateTargetBluetoothAddress(from draft: String) -> Bool {
        guard let address = BluetoothAddress(normalizing: draft) else {
            return false
        }

        targetBluetoothAddress = address.rawValue
        return true
    }

    public func sanitizedTargetBluetoothAddressDraft(_ draft: String) -> String {
        BluetoothAddress.sanitizeUserEntry(draft)
    }

    public func targetBluetoothAddressValidationMessage(for draft: String) -> String {
        if let normalized = BluetoothAddress(normalizing: draft) {
            if normalized.rawValue == targetBluetoothAddress {
                return "Using \(normalized.rawValue) as the target headset address."
            }

            return "The blocker will switch to \(normalized.rawValue) as soon as you finish editing."
        }

        return "The blocker keeps using the last valid address: \(targetBluetoothAddress)."
    }

    public func openLoginItemsSystemSettings() {
        launchAtLoginController.openSystemSettings()
    }

    private func applyBlockerConfiguration() {
        let address = BluetoothAddress(normalizing: targetBluetoothAddress) ?? .defaultMomentum4
        blocker.apply(
            configuration: BlockerConfiguration(
                isEnabled: blockingEnabled,
                targetAddress: address
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

    private func setOpenAtLoginWithoutSideEffects(_ value: Bool) {
        suppressSideEffects = true
        openAtLogin = value
        suppressSideEffects = false
    }
}
