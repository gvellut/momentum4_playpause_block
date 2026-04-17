import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable(String)

    public var message: String? {
        switch self {
        case .enabled:
            return "The app is registered to open at login."
        case .disabled:
            return nil
        case .requiresApproval:
            return "macOS needs approval in System Settings > General > Login Items before automatic launch can take effect."
        case .unavailable(let message):
            return message
        }
    }

    public var isApprovedOrPendingApproval: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unavailable:
            return false
        }
    }

    public var showsSystemSettingsButton: Bool {
        if case .requiresApproval = self {
            return true
        }

        return false
    }
}

public protocol LaunchAtLoginControlling: AnyObject {
    func currentStatus() -> LaunchAtLoginStatus
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginStatus
    func openSystemSettings()
}

public final class LaunchAtLoginController: LaunchAtLoginControlling {
    public init() {}

    public func currentStatus() -> LaunchAtLoginStatus {
        mapStatus(SMAppService.mainApp.status)
    }

    public func setEnabled(_ enabled: Bool) -> LaunchAtLoginStatus {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let mappedStatus = currentStatus()
            if case .disabled = mappedStatus, enabled {
                return .unavailable(error.localizedDescription)
            }

            if case .enabled = mappedStatus, !enabled {
                return .unavailable(error.localizedDescription)
            }

            return mappedStatus
        }

        return currentStatus()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func mapStatus(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable(
                "Launch at Login is unavailable. Build and open the signed .app bundle before enabling it."
            )
        @unknown default:
            return .unavailable("Launch at Login returned an unknown system state.")
        }
    }
}
