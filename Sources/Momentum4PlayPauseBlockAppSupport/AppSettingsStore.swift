import Foundation
import Momentum4PlayPauseBlockCommon

@MainActor
public final class AppSettingsStore: ObservableObject {
    @Published public private(set) var blockingEnabled: Bool
    @Published public private(set) var blockingRequested: Bool

    @Published public var showMenuBarIcon: Bool {
        didSet {
            guard !suppressSideEffects, oldValue != showMenuBarIcon else {
                return
            }

            defaults.set(showMenuBarIcon, forKey: AppSettingsKeys.showMenuBarIcon)
            defaults.set(
                true,
                forKey: AppSettingsKeys.hasExplicitlyConfiguredMenuBarIconVisibility
            )
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

    @Published public var allowedForwardSourceMode: AllowedForwardSourceMode {
        didSet {
            guard !suppressSideEffects, oldValue != allowedForwardSourceMode else {
                return
            }

            defaults.set(
                allowedForwardSourceMode.rawValue,
                forKey: AppSettingsKeys.allowedForwardSourceMode
            )

            if blockingRequested && !canEnableBlocking {
                setBlockingRequestEnabled(false)
            }

            applyProxyConfiguration()
        }
    }

    @Published public private(set) var allowedForwardSourceProductName: String {
        didSet {
            guard !suppressSideEffects, oldValue != allowedForwardSourceProductName else {
                return
            }

            defaults.set(
                allowedForwardSourceProductName,
                forKey: AppSettingsKeys.allowedForwardSourceProductName
            )

            if blockingRequested && !canEnableBlocking {
                setBlockingRequestEnabled(false)
            }

            applyProxyConfiguration()
        }
    }

    @Published public private(set) var proxyStatus: PlaybackProxyStatus = .disabled
    @Published public private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published public private(set) var isCapturingForwardSource = false
    @Published public private(set) var pendingEnableAfterRelaunch = false
    @Published public private(set) var captureFeedbackMessage: String?
    @Published public private(set) var lastActivationFailure: String?

    public var canEnableBlocking: Bool {
        switch allowedForwardSourceMode {
        case .specificProductName:
            return !allowedForwardSourceProductName.isEmpty
        case .anyKeyboard, .anyHID:
            return true
        }
    }

    public var shouldOfferRelaunchToFinishEnable: Bool {
        pendingEnableAfterRelaunch && blockingRequested && !blockingEnabled
    }

    public var shouldShowPermissionActions: Bool {
        switch proxyStatus {
        case .inputMonitoringDenied, .musicAutomationDenied:
            return true
        case .disabled, .requestingPermissions, .active, .error:
            return shouldOfferRelaunchToFinishEnable
        }
    }

    public var blockingStatusSummary: String? {
        if !canEnableBlocking {
            return "Choose a forward source before enabling blocking."
        }

        return nil
    }

    public var shouldShowActivationNote: Bool {
        activationNote != nil
    }

    public var activationNote: String? {
        nil
    }

    private let defaults: UserDefaults
    private let proxyController: PlaybackProxyControlling
    private let launchAtLoginController: LaunchAtLoginControlling
    private var suppressSideEffects = false

    public init(
        defaults: UserDefaults = .standard,
        proxyController: PlaybackProxyControlling? = nil,
        launchAtLoginController: LaunchAtLoginControlling? = nil
    ) {
        self.defaults = defaults
        self.proxyController = proxyController ?? PlaybackProxyService()
        self.launchAtLoginController = launchAtLoginController ?? LaunchAtLoginController()

        let storedMode = AllowedForwardSourceMode(
            rawValue: defaults.string(forKey: AppSettingsKeys.allowedForwardSourceMode) ?? ""
        ) ?? .anyHID
        let storedProductName = defaults.string(
            forKey: AppSettingsKeys.allowedForwardSourceProductName
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedBlockingEnabled = defaults.object(forKey: AppSettingsKeys.blockingEnabled) as? Bool
            ?? false
        let storedPendingEnableAfterRelaunch = defaults.object(
            forKey: AppSettingsKeys.pendingEnableAfterRelaunch
        ) as? Bool ?? false
        let hasExplicitlyConfiguredMenuBarIconVisibility = defaults.object(
            forKey: AppSettingsKeys.hasExplicitlyConfiguredMenuBarIconVisibility
        ) as? Bool ?? false
        let resolvedBlockingEnabled =
            storedBlockingEnabled
            && (storedMode != .specificProductName || !storedProductName.isEmpty)
        let resolvedBlockingRequested =
            resolvedBlockingEnabled || storedPendingEnableAfterRelaunch

        self.allowedForwardSourceMode = storedMode
        self.allowedForwardSourceProductName = storedProductName
        self.blockingEnabled = resolvedBlockingEnabled
        self.pendingEnableAfterRelaunch = storedPendingEnableAfterRelaunch
        self.blockingRequested = resolvedBlockingRequested
        self.showMenuBarIcon =
            hasExplicitlyConfiguredMenuBarIconVisibility
            ? (defaults.object(forKey: AppSettingsKeys.showMenuBarIcon) as? Bool ?? true)
            : true
        self.openAtLogin = defaults.object(forKey: AppSettingsKeys.openAtLogin) as? Bool ?? false
        self.launchAtLoginStatus = self.launchAtLoginController.currentStatus()

        if self.blockingEnabled != storedBlockingEnabled {
            defaults.set(self.blockingEnabled, forKey: AppSettingsKeys.blockingEnabled)
        }

        if !hasExplicitlyConfiguredMenuBarIconVisibility {
            defaults.set(true, forKey: AppSettingsKeys.showMenuBarIcon)
        }

        self.proxyController.statusDidChange = { [weak self] status in
            Task { @MainActor in
                self?.handleProxyStatusChange(status)
            }
        }
        self.proxyController.sourceCaptureDidResolve = { [weak self] productName in
            Task { @MainActor in
                self?.applyCapturedForwardSourceProductName(productName)
            }
        }
        self.proxyController.sourceCaptureDidFail = { [weak self] message in
            Task { @MainActor in
                self?.handleSourceCaptureFailure(message)
            }
        }
    }

    public func refreshRuntimeState() {
        launchAtLoginStatus = launchAtLoginController.currentStatus()
        applyProxyConfiguration()
    }

    public func setBlockingRequested(_ enabled: Bool) {
        guard enabled else {
            setBlockingRequestEnabled(false)
            proxyStatus = .disabled
            applyProxyConfiguration()
            return
        }

        guard canEnableBlocking else {
            setBlockingRequestEnabled(false)
            proxyStatus = .disabled
            applyProxyConfiguration()
            return
        }

        setBlockingRequestEnabled(true)
        pendingEnableAfterRelaunch = false
        defaults.set(false, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)
        lastActivationFailure = nil
        applyProxyConfiguration()
    }

    public func setBlockingEnabled(_ enabled: Bool) {
        setBlockingRequested(enabled)
    }

    public func handleFirstLaunchIfNeeded(showSettings: () -> Void) {
        let hasLaunchedBefore = defaults.bool(forKey: AppSettingsKeys.hasLaunchedBefore)
        guard !hasLaunchedBefore else {
            return
        }

        showSettings()
        defaults.set(true, forKey: AppSettingsKeys.hasLaunchedBefore)
    }

    public func shouldOpenSettingsOnLaunch(for launchContext: AppLaunchContext) -> Bool {
        launchContext.shouldOpenSettingsWhenMenuBarIconHidden(currentlyVisible: showMenuBarIcon)
    }

    public func shouldOpenSettingsOnReopen() -> Bool {
        !showMenuBarIcon
    }

    public func updateAllowedForwardSourceProductNameDraft(_ draft: String) -> Bool {
        allowedForwardSourceProductName = sanitizedAllowedForwardSourceProductName(draft)
        return canEnableBlocking
    }

    public func sanitizedAllowedForwardSourceProductName(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func allowedForwardSourceValidationMessage(for draft: String) -> String {
        let sanitizedDraft = sanitizedAllowedForwardSourceProductName(draft)

        switch allowedForwardSourceMode {
        case .specificProductName:
            if sanitizedDraft.isEmpty {
                return "Enter an exact HID product name or capture it from a key press."
            }

            return "Only HID devices whose product name exactly matches \"\(sanitizedDraft)\" will be forwarded."
        case .anyKeyboard:
            return "Forward only play/pause events that correlate with a keyboard HID source."
        case .anyHID:
            return "Forward play/pause events that correlate with any HID source."
        }
    }

    public func toggleForwardSourceCapture() {
        if isCapturingForwardSource {
            cancelForwardSourceCapture()
            return
        }

        captureFeedbackMessage = nil
        isCapturingForwardSource = proxyController.beginSourceCapture()
        if isCapturingForwardSource {
            captureFeedbackMessage = "Waiting for a key press from the device to allow…"
        }
    }

    public func cancelForwardSourceCapture() {
        guard isCapturingForwardSource else {
            return
        }

        proxyController.cancelSourceCapture()
        isCapturingForwardSource = false
        captureFeedbackMessage = nil
    }

    public func openLoginItemsSystemSettings() {
        launchAtLoginController.openSystemSettings()
    }

    public func restartBlockingIfRequestedForRuntimeModeChange() {
        guard blockingRequested else {
            return
        }

        proxyController.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: false,
                allowedForwardSourceMode: allowedForwardSourceMode,
                allowedForwardSourceProductName: allowedForwardSourceProductName
            )
        )
        applyProxyConfiguration()
    }

    private func applyCapturedForwardSourceProductName(_ productName: String) {
        suppressSideEffects = true
        allowedForwardSourceMode = .specificProductName
        allowedForwardSourceProductName = sanitizedAllowedForwardSourceProductName(productName)
        suppressSideEffects = false

        defaults.set(
            allowedForwardSourceMode.rawValue,
            forKey: AppSettingsKeys.allowedForwardSourceMode
        )
        defaults.set(
            allowedForwardSourceProductName,
            forKey: AppSettingsKeys.allowedForwardSourceProductName
        )

        isCapturingForwardSource = false
        captureFeedbackMessage = nil
        applyProxyConfiguration()
    }

    private func handleSourceCaptureFailure(_ message: String) {
        isCapturingForwardSource = false
        captureFeedbackMessage = message
    }

    private func handleProxyStatusChange(_ status: PlaybackProxyStatus) {
        proxyStatus = status

        switch status {
        case .active:
            setBlockingRequestedWithoutSideEffects(true)
            setBlockingEnabledWithoutSideEffects(true)
            defaults.set(true, forKey: AppSettingsKeys.blockingEnabled)
            pendingEnableAfterRelaunch = false
            defaults.set(false, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)
            lastActivationFailure = nil
        case .disabled:
            setBlockingEnabledWithoutSideEffects(false)
            if !blockingRequested {
                defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
                pendingEnableAfterRelaunch = false
                defaults.set(false, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)
                lastActivationFailure = nil
            }
        case .requestingPermissions:
            setBlockingEnabledWithoutSideEffects(false)
            defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
            pendingEnableAfterRelaunch = false
            defaults.set(false, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)
            lastActivationFailure = nil
        case .inputMonitoringDenied, .musicAutomationDenied:
            setBlockingEnabledWithoutSideEffects(false)
            defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
            if blockingRequested {
                pendingEnableAfterRelaunch = true
                defaults.set(true, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)
            }
            lastActivationFailure = nil
        case .error:
            setBlockingEnabledWithoutSideEffects(false)
            defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
            pendingEnableAfterRelaunch = false
            defaults.set(false, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)
            lastActivationFailure = status.message
        }
    }

    private func applyProxyConfiguration() {
        proxyController.apply(
            configuration: PlaybackProxyConfiguration(
                enabled: blockingRequested && canEnableBlocking,
                allowedForwardSourceMode: allowedForwardSourceMode,
                allowedForwardSourceProductName: allowedForwardSourceProductName
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

    private func setBlockingRequestedWithoutSideEffects(_ value: Bool) {
        suppressSideEffects = true
        blockingRequested = value
        suppressSideEffects = false
    }

    private func setBlockingRequestEnabled(_ value: Bool) {
        setBlockingRequestedWithoutSideEffects(value)
        if !value {
            setBlockingEnabledWithoutSideEffects(false)
            pendingEnableAfterRelaunch = false
            defaults.set(false, forKey: AppSettingsKeys.pendingEnableAfterRelaunch)
            defaults.set(false, forKey: AppSettingsKeys.blockingEnabled)
            lastActivationFailure = nil
        }
    }

    private func setOpenAtLoginWithoutSideEffects(_ value: Bool) {
        suppressSideEffects = true
        openAtLogin = value
        suppressSideEffects = false
    }
}
