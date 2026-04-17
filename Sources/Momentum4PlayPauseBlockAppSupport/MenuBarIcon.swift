import Foundation

public enum MenuBarIcon {
    public static func symbolName(blockingEnabled: Bool) -> String {
        blockingEnabled ? "circle.fill" : "circle"
    }
}
