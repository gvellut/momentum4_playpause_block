import Momentum4PlayPauseBlockAppSupport

@MainActor
enum AppRuntime {
    static let sharedStore = AppSettingsStore()
}
