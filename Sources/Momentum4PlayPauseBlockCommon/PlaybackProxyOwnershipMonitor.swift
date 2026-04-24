import AppKit
import Foundation

enum PlaybackProxyOwnershipMonitorSignal: Equatable {
    case systemWillSleep
    case systemDidWake
    case screensDidSleep
    case screensDidWake
    case mediaRemoteNotification(String)
    case timedBackstopTick(TimeInterval)
}

struct PlaybackProxyOwnershipMonitoringConfiguration: Equatable {
    let eventDrivenReclaimEnabled: Bool
    let pollInterval: TimeInterval?

    var isEnabled: Bool {
        eventDrivenReclaimEnabled || pollInterval != nil
    }
}

@MainActor
protocol PlaybackProxyOwnershipMonitoring: AnyObject {
    func start(
        configuration: PlaybackProxyOwnershipMonitoringConfiguration,
        onSignal: @escaping (PlaybackProxyOwnershipMonitorSignal) -> Void
    )
    func stop()
}

@MainActor
final class SystemPlaybackProxyOwnershipMonitor: PlaybackProxyOwnershipMonitoring {
    private static let mediaRemoteNotificationNames = [
        "com.apple.MediaRemote.nowPlayingApplicationPlaybackStateDidChange",
        "com.apple.MediaRemote.nowPlayingApplicationIsPlayingDidChange",
        "com.apple.MediaRemote.nowPlayingActivePlayersIsPlayingDidChange",
    ]

    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: DistributedNotificationCenter
    private let mediaRemoteBridge: MediaRemoteNotificationRegistering

    private var workspaceObservers: [Any] = []
    private var distributedObservers: [Any] = []
    private var pollTimer: Timer?
    private var activeConfiguration: PlaybackProxyOwnershipMonitoringConfiguration?
    private var signalHandler: ((PlaybackProxyOwnershipMonitorSignal) -> Void)?

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: DistributedNotificationCenter = .default(),
        mediaRemoteBridge: MediaRemoteNotificationRegistering = MediaRemoteNotificationBridge()
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.mediaRemoteBridge = mediaRemoteBridge
    }

    func start(
        configuration: PlaybackProxyOwnershipMonitoringConfiguration,
        onSignal: @escaping (PlaybackProxyOwnershipMonitorSignal) -> Void
    ) {
        if activeConfiguration == configuration {
            signalHandler = onSignal
            return
        }

        stop()
        signalHandler = onSignal
        activeConfiguration = configuration

        if configuration.eventDrivenReclaimEnabled {
            installWorkspaceObservers()
            installMediaRemoteObservers()
        }

        if let pollInterval = configuration.pollInterval {
            installPollTimer(interval: pollInterval)
        }
    }

    func stop() {
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll(keepingCapacity: false)

        for observer in distributedObservers {
            distributedNotificationCenter.removeObserver(observer)
        }
        distributedObservers.removeAll(keepingCapacity: false)

        pollTimer?.invalidate()
        pollTimer = nil
        activeConfiguration = nil
        signalHandler = nil
    }

    private func installWorkspaceObservers() {
        for (name, signal) in [
            (NSWorkspace.willSleepNotification, PlaybackProxyOwnershipMonitorSignal.systemWillSleep),
            (NSWorkspace.didWakeNotification, PlaybackProxyOwnershipMonitorSignal.systemDidWake),
            (NSWorkspace.screensDidSleepNotification, PlaybackProxyOwnershipMonitorSignal.screensDidSleep),
            (NSWorkspace.screensDidWakeNotification, PlaybackProxyOwnershipMonitorSignal.screensDidWake),
        ] {
            let observer = workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.signalHandler?(signal)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func installMediaRemoteObservers() {
        _ = mediaRemoteBridge.registerForNowPlayingNotifications()

        for notificationName in Self.mediaRemoteNotificationNames {
            let observer = distributedNotificationCenter.addObserver(
                forName: Notification.Name(notificationName),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.signalHandler?(.mediaRemoteNotification(notificationName))
                }
            }
            distributedObservers.append(observer)
        }
    }

    private func installPollTimer(interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.signalHandler?(.timedBackstopTick(interval))
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

protocol MediaRemoteNotificationRegistering {
    func registerForNowPlayingNotifications() -> Bool
}

final class MediaRemoteNotificationBridge: MediaRemoteNotificationRegistering {
    private typealias RegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue)
        -> Void

    private let registerForNowPlayingNotificationsFunction:
        RegisterForNowPlayingNotificationsFunction?

    init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework"
        _ = Bundle(path: frameworkPath)?.load()
        _ = dlopen("\(frameworkPath)/MediaRemote", RTLD_NOW)

        registerForNowPlayingNotificationsFunction = Self.loadFunction(
            named: "MRMediaRemoteRegisterForNowPlayingNotifications"
        )
    }

    func registerForNowPlayingNotifications() -> Bool {
        guard let registerForNowPlayingNotificationsFunction else {
            return false
        }

        registerForNowPlayingNotificationsFunction(.main)
        return true
    }

    private static var globalSymbolHandle: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: -2)!
    }

    private static func loadFunction<T>(named symbol: String) -> T? {
        guard let symbolPointer = dlsym(globalSymbolHandle, symbol) else {
            return nil
        }

        return unsafeBitCast(symbolPointer, to: T.self)
    }
}
