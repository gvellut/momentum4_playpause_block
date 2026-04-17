import Momentum4PlayPauseBlockCore
import SwiftUI

@main
struct Momentum4PlayPauseBlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore: AppSettingsStore

    init() {
        _settingsStore = StateObject(wrappedValue: AppRuntime.sharedStore)
    }

    var body: some Scene {
        MenuBarExtra(
            isInserted: Binding(
                get: { settingsStore.showMenuBarIcon },
                set: { settingsStore.showMenuBarIcon = $0 }
            )
        ) {
            MenuBarMenu(settingsStore: settingsStore)
        } label: {
            Image(systemName: MenuBarIcon.symbolName(blockingEnabled: settingsStore.blockingEnabled))
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel("Momentum4 PlayPause Block")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settingsStore: settingsStore)
        }
    }
}

private struct MenuBarMenu: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Preferences…") {
            openSettings()
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
