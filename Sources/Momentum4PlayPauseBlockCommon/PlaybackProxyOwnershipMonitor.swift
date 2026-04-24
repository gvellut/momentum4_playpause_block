import AppKit
import Foundation

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
        onOwnershipRiskDetected: @escaping () -> Void
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

    private var wakeObserver: Any?
    private var distributedObservers: [Any] = []
    private var pollTimer: Timer?
    private var activeConfiguration: PlaybackProxyOwnershipMonitoringConfiguration?
    private var ownershipRiskHandler: (() -> Void)?

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
        onOwnershipRiskDetected: @escaping () -> Void
    ) {
        if activeConfiguration == configuration {
            ownershipRiskHandler = onOwnershipRiskDetected
            return
        }

        stop()
        ownershipRiskHandler = onOwnershipRiskDetected
        activeConfiguration = configuration

        if configuration.eventDrivenReclaimEnabled {
            installWakeObserver()
            installMediaRemoteObservers()
        }

        if let pollInterval = configuration.pollInterval {
            installPollTimer(interval: pollInterval)
        }
    }

    func stop() {
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        for observer in distributedObservers {
            distributedNotificationCenter.removeObserver(observer)
        }
        distributedObservers.removeAll(keepingCapacity: false)

        pollTimer?.invalidate()
        pollTimer = nil
        activeConfiguration = nil
        ownershipRiskHandler = nil
    }

    private func installWakeObserver() {
        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ownershipRiskHandler?()
            }
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
                    self?.ownershipRiskHandler?()
                }
            }
            distributedObservers.append(observer)
        }
    }

    private func installPollTimer(interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ownershipRiskHandler?()
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
