import Momentum4PlayPauseBlockCore

@MainActor
enum AppRuntime {
    static let sharedStore = AppSettingsStore()
}
