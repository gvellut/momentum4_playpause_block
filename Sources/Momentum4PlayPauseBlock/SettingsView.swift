import AppKit
import Momentum4PlayPauseBlockAppSupport
import Momentum4PlayPauseBlockCommon
import SwiftUI

struct SettingsView: View {
    private enum FocusedField: Hashable {
        case allowedForwardSourceProductName
    }

    @ObservedObject var settingsStore: AppSettingsStore
    let appActions: any AppActionHandling
    @State private var allowedForwardSourceProductNameDraft: String
    @FocusState private var focusedField: FocusedField?

    init(
        settingsStore: AppSettingsStore,
        appActions: any AppActionHandling
    ) {
        self.settingsStore = settingsStore
        self.appActions = appActions
        _allowedForwardSourceProductNameDraft = State(
            initialValue: settingsStore.allowedForwardSourceProductName
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionCard(title: "Blocking") {
                Toggle("Enable block", isOn: blockingRequestedBinding)
                    .toggleStyle(.switch)
                    .disabled(!settingsStore.canEnableBlocking && !settingsStore.blockingRequested)

                if let blockingStatusSummary = settingsStore.blockingStatusSummary {
                    Text(blockingStatusSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(blockingStatusColor)
                }

                if settingsStore.shouldShowPermissionActions {
                    HStack(spacing: 10) {
                        Button(systemSettingsButtonTitle) {
                            openRelevantSystemSettings()
                        }

                        if settingsStore.shouldOfferRelaunchToFinishEnable {
                            Button("Relaunch App") {
                                appActions.relaunchApplication()
                            }
                        }
                    }
                }
            }

            Divider()

            SettingsSectionCard(title: "Forward Source") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Source to allow forward")
                            .font(.subheadline.weight(.medium))

                        Picker("Source to allow forward", selection: allowedForwardSourceModeBinding) {
                            ForEach(AllowedForwardSourceMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: allowedForwardSourcePickerWidth, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if settingsStore.allowedForwardSourceMode.requiresProductName {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Exact HID product name")
                                .font(.subheadline.weight(.medium))

                            TextField(
                                "Keychron K1 Pro",
                                text: $allowedForwardSourceProductNameDraft
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .allowedForwardSourceProductName)
                            .disabled(settingsStore.isCapturingForwardSource)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: allowedForwardSourceProductNameDraft) { _, newValue in
                                let sanitized =
                                    settingsStore.sanitizedAllowedForwardSourceProductName(
                                        newValue
                                    )
                                if sanitized != newValue {
                                    allowedForwardSourceProductNameDraft = sanitized
                                    return
                                }

                                _ = settingsStore.updateAllowedForwardSourceProductNameDraft(
                                    sanitized
                                )
                            }

                            HStack(spacing: 10) {
                                Button(
                                    settingsStore.isCapturingForwardSource
                                        ? "Cancel Capture" : "Capture From Key Press"
                                ) {
                                    dismissFieldFocus()
                                    settingsStore.toggleForwardSourceCapture()
                                }

                                if let captureMessage = settingsStore.captureFeedbackMessage {
                                    Text(captureMessage)
                                        .font(.footnote)
                                        .foregroundStyle(
                                            settingsStore.isCapturingForwardSource
                                                ? AnyShapeStyle(.secondary)
                                                : AnyShapeStyle(Color.red)
                                        )
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                }
            }

            Divider()

            SettingsSectionCard(title: "App") {
                Toggle("Show icon in menubar", isOn: showMenuBarIconBinding)
                    .toggleStyle(.switch)

                Toggle("Open at Login", isOn: openAtLoginBinding)
                    .toggleStyle(.switch)

                if let message = settingsStore.launchAtLoginStatus.message {
                    HStack(spacing: 10) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if settingsStore.launchAtLoginStatus.showsSystemSettingsButton {
                            Button("Open Login Items Settings") {
                                settingsStore.openLoginItemsSystemSettings()
                            }
                        }
                    }
                }

                if !settingsStore.showMenuBarIcon {
                    Text(
                        "If you open the app manually while the menu bar icon is hidden, Settings will open without restoring the icon. Re-enable the icon here if you want it back."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 460, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: settingsStore.allowedForwardSourceProductName) { _, newValue in
            if allowedForwardSourceProductNameDraft != newValue {
                allowedForwardSourceProductNameDraft = newValue
            }
        }
        .onChange(of: settingsStore.isCapturingForwardSource) { _, isCapturing in
            if isCapturing {
                dismissFieldFocus()
            }
        }
    }

    private var blockingRequestedBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.blockingRequested },
            set: {
                guard settingsStore.blockingRequested != $0 else {
                    return
                }

                settingsStore.setBlockingRequested($0)
            }
        )
    }

    private var allowedForwardSourceModeBinding: Binding<AllowedForwardSourceMode> {
        Binding(
            get: { settingsStore.allowedForwardSourceMode },
            set: {
                guard settingsStore.allowedForwardSourceMode != $0 else {
                    return
                }

                settingsStore.allowedForwardSourceMode = $0
            }
        )
    }

    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.showMenuBarIcon },
            set: {
                guard settingsStore.showMenuBarIcon != $0 else {
                    return
                }

                settingsStore.showMenuBarIcon = $0
            }
        )
    }

    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.openAtLogin },
            set: {
                guard settingsStore.openAtLogin != $0 else {
                    return
                }

                settingsStore.openAtLogin = $0
            }
        )
    }

    private var blockingStatusColor: Color {
        switch settingsStore.proxyStatus {
        case .active:
            return .green
        case .inputMonitoringDenied, .musicAutomationDenied, .error:
            return .red
        case .disabled:
            return settingsStore.shouldOfferRelaunchToFinishEnable ? .orange : .secondary
        case .requestingPermissions:
            return .secondary
        }
    }

    private var allowedForwardSourcePickerWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widestOptionWidth =
            AllowedForwardSourceMode.allCases
            .map { mode in
                (mode.displayName as NSString).size(withAttributes: [.font: font]).width
            }
            .max() ?? 0

        // Leave room for the popup bezel and disclosure arrow while keeping the control contained.
        return min(max(160, ceil(widestOptionWidth + 46)), 280)
    }

    private func dismissFieldFocus() {
        focusedField = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var systemSettingsButtonTitle: String {
        switch settingsStore.proxyStatus {
        case .inputMonitoringDenied:
            return "Open Input Monitoring"
        case .musicAutomationDenied:
            return "Open Automation"
        case .disabled, .requestingPermissions, .active, .error:
            return "Open System Settings"
        }
    }

    private func openRelevantSystemSettings() {
        let candidateURLs: [URL]

        switch settingsStore.proxyStatus {
        case .inputMonitoringDenied:
            candidateURLs = [
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
                URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            ].compactMap { $0 }
        case .musicAutomationDenied:
            candidateURLs = [
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
                URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            ].compactMap { $0 }
        case .disabled, .requestingPermissions, .active, .error:
            candidateURLs = [URL(fileURLWithPath: "/System/Applications/System Settings.app")]
        }

        for url in candidateURLs where NSWorkspace.shared.open(url) {
            return
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
