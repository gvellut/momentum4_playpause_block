import AppKit
import Foundation
import IOKit.pwr_mgt

enum PlaybackProxyOwnershipMonitorSignal: Equatable {
    case systemCanSleep
    case systemWillSleep
    case systemWillNotSleep
    case systemDidWake
    case screensDidSleep
    case screensDidWake
    case screenDidLock
    case screenDidUnlock
    case screenSaverDidStart
    case screenSaverDidStop
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
    private enum PowerMessage {
        static let systemCanSleep: UInt32 = 0xE000_0270
        static let systemWillSleep: UInt32 = 0xE000_0280
        static let systemWillNotSleep: UInt32 = 0xE000_0290
        static let systemHasPoweredOn: UInt32 = 0xE000_0300
    }
    private static let distributedNotificationSignals: [(Notification.Name, PlaybackProxyOwnershipMonitorSignal)] = [
        (Notification.Name("com.apple.screenIsLocked"), .screenDidLock),
        (Notification.Name("com.apple.screenIsUnlocked"), .screenDidUnlock),
        (Notification.Name("com.apple.screensaver.didstart"), .screenSaverDidStart),
        (Notification.Name("com.apple.screensaver.didstop"), .screenSaverDidStop),
    ]

    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: DistributedNotificationCenter
    private let mediaRemoteBridge: MediaRemoteNotificationRegistering

    private var workspaceObservers: [Any] = []
    private var distributedObservers: [Any] = []
    private var powerNotificationPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = IO_OBJECT_NULL
    private var rootPowerPort: io_connect_t = IO_OBJECT_NULL
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
            installPowerObserver()
            installWorkspaceObservers()
            installDistributedNotificationObservers()
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

        uninstallPowerObserver()

        pollTimer?.invalidate()
        pollTimer = nil
        activeConfiguration = nil
        signalHandler = nil
    }

    private func installPowerObserver() {
        uninstallPowerObserver()

        var notificationPort: IONotificationPortRef?
        var notifier: io_object_t = IO_OBJECT_NULL
        let rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notificationPort,
            Self.powerCallback,
            &notifier
        )

        guard rootPort != IO_OBJECT_NULL, let notificationPort else {
            return
        }

        rootPowerPort = rootPort
        powerNotificationPort = notificationPort
        powerNotifier = notifier

        guard let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort) else {
            uninstallPowerObserver()
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource.takeUnretainedValue(), .commonModes)
    }

    private func uninstallPowerObserver() {
        if powerNotifier != IO_OBJECT_NULL {
            IOObjectRelease(powerNotifier)
            powerNotifier = IO_OBJECT_NULL
        }

        if rootPowerPort != IO_OBJECT_NULL {
            IOServiceClose(rootPowerPort)
            rootPowerPort = IO_OBJECT_NULL
        }

        if let powerNotificationPort {
            IONotificationPortDestroy(powerNotificationPort)
            self.powerNotificationPort = nil
        }
    }

    private nonisolated static let powerCallback: IOServiceInterestCallback = {
        refcon,
        _,
        messageType,
        messageArgument in
        guard let refcon else {
            return
        }

        let monitor = Unmanaged<SystemPlaybackProxyOwnershipMonitor>
            .fromOpaque(refcon)
            .takeUnretainedValue()
        let notificationID = messageArgument.map { Int(bitPattern: $0) }
        MainActor.assumeIsolated {
            monitor.handlePowerMessage(
                messageType: messageType,
                notificationID: notificationID
            )
        }
    }

    private func handlePowerMessage(
        messageType: UInt32,
        notificationID: Int?
    ) {
        switch messageType {
        case Self.PowerMessage.systemCanSleep:
            signalHandler?(.systemCanSleep)
            allowPowerChange(notificationID: notificationID)

        case Self.PowerMessage.systemWillSleep:
            signalHandler?(.systemWillSleep)
            allowPowerChange(notificationID: notificationID)

        case Self.PowerMessage.systemWillNotSleep:
            signalHandler?(.systemWillNotSleep)

        case Self.PowerMessage.systemHasPoweredOn:
            signalHandler?(.systemDidWake)

        default:
            break
        }
    }

    private func allowPowerChange(notificationID: Int?) {
        guard rootPowerPort != IO_OBJECT_NULL, let notificationID else {
            return
        }

        IOAllowPowerChange(rootPowerPort, notificationID)
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

    private func installDistributedNotificationObservers() {
        for (name, signal) in Self.distributedNotificationSignals {
            let observer = distributedNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.signalHandler?(signal)
                }
            }
            distributedObservers.append(observer)
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
