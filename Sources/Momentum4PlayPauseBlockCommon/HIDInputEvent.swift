import Foundation
import IOKit.hid

public struct HIDInputEvent: Equatable, Sendable {
    public let device: HIDDeviceSnapshot
    public let timestamp: UInt64
    public let usagePage: Int
    public let usage: Int
    public let value: Int
    public let actionLabel: String?

    public init(
        device: HIDDeviceSnapshot,
        timestamp: UInt64,
        usagePage: Int,
        usage: Int,
        value: Int,
        actionLabel: String? = nil
    ) {
        self.device = device
        self.timestamp = timestamp
        self.usagePage = usagePage
        self.usage = usage
        self.value = value
        self.actionLabel = actionLabel ?? Self.defaultActionLabel(usagePage: usagePage, usage: usage)
    }

    public static func defaultActionLabel(usagePage: Int, usage: Int) -> String? {
        guard usagePage == Int(kHIDPage_Consumer) else {
            return nil
        }

        switch usage {
        case Int(kHIDUsage_Csmr_Play):
            return "Play"
        case Int(kHIDUsage_Csmr_Pause):
            return "Pause"
        case Int(kHIDUsage_Csmr_ScanNextTrack):
            return "Next Track"
        case Int(kHIDUsage_Csmr_ScanPreviousTrack):
            return "Previous Track"
        case Int(kHIDUsage_Csmr_PlayOrPause):
            return "Play/Pause"
        case Int(kHIDUsage_Csmr_Mute):
            return "Mute"
        case Int(kHIDUsage_Csmr_VolumeIncrement):
            return "Volume Up"
        case Int(kHIDUsage_Csmr_VolumeDecrement):
            return "Volume Down"
        default:
            return nil
        }
    }
}
