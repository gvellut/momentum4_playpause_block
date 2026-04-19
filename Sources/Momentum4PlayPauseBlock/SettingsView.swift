import Momentum4PlayPauseBlockAppSupport
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: AppSettingsStore
    @State private var targetAddressDraft: String

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        _targetAddressDraft = State(initialValue: settingsStore.targetBluetoothAddress)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable / disable block", isOn: $settingsStore.blockingEnabled)
                    .disabled(!settingsStore.canEnableBlocking)

                Text(settingsStore.blockerStatus.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !settingsStore.canEnableBlocking && !settingsStore.useGenericAudioHeadsetTarget {
                    Text("Enter a full Bluetooth address below before blocking can be enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
            }

            Section("Advanced") {
                Toggle(
                    "Use generic Audio / Headset target",
                    isOn: $settingsStore.useGenericAudioHeadsetTarget
                )

                TextField("Target Bluetooth Address", text: $targetAddressDraft)
                    .font(.system(.body, design: .monospaced))
                    .disabled(settingsStore.useGenericAudioHeadsetTarget)
                    .onChange(of: targetAddressDraft) { _, newValue in
                        let sanitized = settingsStore.sanitizedTargetBluetoothAddressDraft(newValue)
                        if sanitized != newValue {
                            targetAddressDraft = sanitized
                            return
                        }

                        _ = settingsStore.updateTargetBluetoothAddressDraft(sanitized)
                    }

                Text(settingsStore.targetBluetoothAddressValidationMessage(for: targetAddressDraft))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Check") {
                    settingsStore.runTargetCheck()
                }
                .disabled(settingsStore.selectedTarget == nil)

                if let checkResult = settingsStore.targetCheckResult {
                    Text(checkResult.message)
                        .font(.footnote)
                        .foregroundStyle(checkResult.isMatchFound ? .primary : .secondary)

                    if let matchedDevice = checkResult.matchedDevice {
                        Text(matchedDevice.displaySummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(checkResult.rejectionMessages, id: \.self) { rejection in
                        Text(rejection)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
        .onChange(of: settingsStore.targetBluetoothAddress) { _, newValue in
            if targetAddressDraft != newValue {
                targetAddressDraft = newValue
            }
        }
    }
}
