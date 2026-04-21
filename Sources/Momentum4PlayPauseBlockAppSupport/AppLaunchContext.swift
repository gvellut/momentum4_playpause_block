import Carbon
import Foundation

public struct AppLaunchContext: Equatable, Sendable {
    public let launchedAsLoginItem: Bool

    public init(launchedAsLoginItem: Bool) {
        self.launchedAsLoginItem = launchedAsLoginItem
    }

    public static func detectFromCurrentAppleEvent() -> AppLaunchContext {
        let currentAppleEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchedAsLoginItem = currentAppleEvent?.paramDescriptor(
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        ) != nil

        return AppLaunchContext(launchedAsLoginItem: launchedAsLoginItem)
    }

    public func shouldForceShowMenuBarIcon(currentlyVisible: Bool) -> Bool {
        !launchedAsLoginItem && !currentlyVisible
    }

    public func shouldOpenSettingsWhenMenuBarIconHidden(currentlyVisible: Bool) -> Bool {
        !launchedAsLoginItem
    }
}
