import AppKit
import Momentum4PlayPauseBlockAppSupport
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let settingsWindowContentSize = NSSize(width: 460, height: 520)

    private var launchContext = AppLaunchContext(launchedAsLoginItem: false)
    private var settingsWindowController: NSWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchContext = AppLaunchContext.detectFromCurrentAppleEvent()
        setBackgroundActivationPolicy()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = AppRuntime.sharedStore
        AppRuntime.sharedActions.registerOpenSettingsHandler { [weak self] in
            self?.showSettingsWindow()
        }
        settingsStore.refreshRuntimeState()
        settingsStore.handleFirstLaunchIfNeeded { [weak self] in
            self?.openSettingsLater()
        }

        if settingsStore.shouldOpenSettingsOnLaunch(for: launchContext) {
            openSettingsLater()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppRuntime.sharedStore.shouldOpenSettingsOnReopen() {
            AppRuntime.sharedActions.openSettings()
        }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @MainActor
    private func showSettingsWindow() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = settingsWindowController ?? makeSettingsWindowController()
        settingsWindowController = controller

        controller.showWindow(nil)
        guard let window = controller.window else {
            return
        }

        applySettingsWindowSizing(to: window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        clearInitialTextFieldFocus(in: window)
    }

    @MainActor
    private func makeSettingsWindowController() -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: SettingsView(
                settingsStore: AppRuntime.sharedStore,
                appActions: AppRuntime.sharedActions
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Momentum4 PlayPause Block Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        applySettingsWindowSizing(to: window)
        window.initialFirstResponder = nil
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.center()

        return NSWindowController(window: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let window = notification.object as? NSWindow,
            window == settingsWindowController?.window
        else {
            return
        }

        AppRuntime.sharedStore.cancelForwardSourceCapture()
        settingsWindowController = nil
        setBackgroundActivationPolicy()
        AppRuntime.sharedStore.restartBlockingIfRequestedForRuntimeModeChange()
    }

    private func openSettingsLater() {
        DispatchQueue.main.async {
            AppRuntime.sharedActions.openSettings()
        }
    }

    @MainActor
    private func clearInitialTextFieldFocus(in window: NSWindow) {
        window.endEditing(for: nil)
        _ = window.makeFirstResponder(nil)

        DispatchQueue.main.async { [weak window] in
            guard let window else {
                return
            }

            window.endEditing(for: nil)
            _ = window.makeFirstResponder(nil)
        }
    }

    @MainActor
    private func applySettingsWindowSizing(to window: NSWindow) {
        window.setContentSize(Self.settingsWindowContentSize)
        window.minSize = Self.settingsWindowContentSize
    }

    @MainActor
    private func setBackgroundActivationPolicy() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }
}
