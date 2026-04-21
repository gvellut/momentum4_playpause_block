import Momentum4PlayPauseBlockAppSupport

@MainActor
enum AppRuntime {
    static let sharedStore = AppSettingsStore()
    static let sharedActions = AppActionController()
}
