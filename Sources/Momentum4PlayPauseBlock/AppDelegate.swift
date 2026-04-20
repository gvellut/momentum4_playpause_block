import AppKit
import Momentum4PlayPauseBlockAppSupport

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchContext = AppLaunchContext(launchedAsLoginItem: false)

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchContext = AppLaunchContext.detectFromCurrentAppleEvent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = AppRuntime.sharedStore
        settingsStore.refreshRuntimeState()
        settingsStore.handleFirstLaunchIfNeeded { [weak self] in
            self?.showSettingsWindow()
        }

        if settingsStore.shouldOpenSettingsOnLaunch(for: launchContext) {
            showSettingsWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppRuntime.sharedStore.shouldOpenSettingsOnReopen() {
            showSettingsWindow()
        }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @MainActor
    func showSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
