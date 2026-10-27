import Foundation

/// Identifiers shared by the app and the privileged helper daemon.
public enum HelperConstants {
    /// Bundle identifier of the main application.
    public static let appBundleIdentifier = "app.clashx.remake"
    /// Mach service name, launchd label and executable name of the helper.
    public static let machServiceName = "app.clashx.remake.helper"
    /// File name of the launchd plist embedded in `Contents/Library/LaunchDaemons`.
    public static let launchdPlistName = "\(machServiceName).plist"
    /// Bump this whenever the XPC protocol changes incompatibly.
    public static let protocolVersion = 1
}
