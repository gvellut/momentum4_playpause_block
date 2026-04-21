import Momentum4PlayPauseBlockAppSupport
import SwiftUI

@main
struct Momentum4PlayPauseBlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore: AppSettingsStore
    private let appActions: AppActionController

    init() {
        _settingsStore = StateObject(wrappedValue: AppRuntime.sharedStore)
        appActions = AppRuntime.sharedActions
    }

    var body: some Scene {
        MenuBarExtra(
            isInserted: Binding(
                get: { settingsStore.showMenuBarIcon },
                set: { _ in }
            )
        ) {
            MenuBarMenu(appActions: appActions)
        } label: {
            Image(systemName: MenuBarIcon.symbolName(blockingEnabled: settingsStore.blockingEnabled))
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Momentum4 PlayPause Block")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarMenu: View {
    let appActions: any AppActionHandling

    var body: some View {
        Button("Preferences…") {
            DispatchQueue.main.async {
                appActions.openSettings()
            }
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
