import Momentum4PlayPauseBlockAppSupport
import Momentum4PlayPauseBlockCommon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @State private var allowedForwardSourceProductNameDraft: String

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        _allowedForwardSourceProductNameDraft = State(
            initialValue: settingsStore.allowedForwardSourceProductName
        )
    }

    var body: some View {
        Form {
            Section("Blocking") {
                Toggle("Enable / disable block", isOn: $settingsStore.blockingEnabled)
                    .disabled(!settingsStore.canEnableBlocking)

                Text(settingsStore.proxyStatus.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !settingsStore.canEnableBlocking {
                    Text("Choose a forward source before enabling blocking.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Apple Music only. The working path forwards approved play/pause commands to Music through AppleScript.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("The app needs Input Monitoring to see HID presses and Music Automation permission to control Apple Music. macOS may still require one relaunch after you grant both.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Forward Source") {
                Picker("Source to allow forward", selection: $settingsStore.allowedForwardSourceMode) {
                    ForEach(AllowedForwardSourceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                if settingsStore.allowedForwardSourceMode.requiresProductName {
                    TextField(
                        "Exact HID product name",
                        text: $allowedForwardSourceProductNameDraft
                    )
                    .onChange(of: allowedForwardSourceProductNameDraft) { _, newValue in
                        let sanitized = settingsStore.sanitizedAllowedForwardSourceProductName(newValue)
                        if sanitized != newValue {
                            allowedForwardSourceProductNameDraft = sanitized
                            return
                        }

                        _ = settingsStore.updateAllowedForwardSourceProductNameDraft(sanitized)
                    }
                }

                HStack {
                    Button(settingsStore.isCapturingForwardSource ? "Stop Capture" : "Capture From Key Press") {
                        settingsStore.toggleForwardSourceCapture()
                    }

                    if settingsStore.isCapturingForwardSource {
                        Text("Press a key on the source you want to allow.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    settingsStore.allowedForwardSourceValidationMessage(
                        for: allowedForwardSourceProductNameDraft
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Show / Hide icon in menubar", isOn: $settingsStore.showMenuBarIcon)
                Toggle("Open at Login", isOn: $settingsStore.openAtLogin)

                if let message = settingsStore.launchAtLoginStatus.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if settingsStore.launchAtLoginStatus.showsSystemSettingsButton {
                    Button("Open Login Items Settings") {
                        settingsStore.openLoginItemsSystemSettings()
                    }
                }

                if !settingsStore.showMenuBarIcon {
                    Text("If you open the app manually while the menu bar icon is hidden, Settings will open without restoring the icon. Re-enable the icon here if you want it back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
        .onChange(of: settingsStore.allowedForwardSourceProductName) { _, newValue in
            if allowedForwardSourceProductNameDraft != newValue {
                allowedForwardSourceProductNameDraft = newValue
            }
        }
    }
}
