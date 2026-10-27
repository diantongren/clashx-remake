import Foundation

enum LaunchMode: String, Sendable, Equatable {
    /// Spawned as root by the SMAppService daemon: TUN and system proxy work.
    case privileged
    /// Spawned by the app itself: proxy ports only. Used when the helper is not installed.
    case userSpace

    var title: String {
        switch self {
        case .privileged: String(localized: "Privileged (helper)")
        case .userSpace: String(localized: "User space")
        }
    }
}

struct CoreRuntime: Sendable, Equatable {
    var controllerPort: Int
    var secret: String
    var version: String
    var launchMode: LaunchMode
    var pid: Int32?
    var startedAt: Date
}

enum CoreState: Sendable, Equatable {
    case stopped
    case starting(stage: String)
    case running(CoreRuntime)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var runtime: CoreRuntime? {
        if case let .running(runtime) = self { return runtime }
        return nil
    }

    var isTransitioning: Bool {
        if case .starting = self { return true }
        return false
    }
}

enum CoreError: Error, LocalizedError {
    case bundleMissingCore
    case checksumMismatch(expected: String, actual: String)
    case profileMissing(String)
    case helperUnavailable
    case startTimeout(logTail: String)
    case exitedEarly(status: Int32, logTail: String)
    case notRunning
    case requiresPrivilegedCore(String)

    var errorDescription: String? {
        switch self {
        case .bundleMissingCore:
            String(localized: "The application bundle does not contain a proxy core. Run scripts/fetch-core.sh and rebuild.")
        case let .checksumMismatch(expected, actual):
            String(localized: "The proxy core failed verification (expected \(expected.prefix(12))…, got \(actual.prefix(12))…).")
        case let .profileMissing(name):
            String(localized: "Profile “\(name)” does not exist.")
        case .helperUnavailable:
            String(localized: "The privileged helper is not available.")
        case let .startTimeout(logTail):
            String(localized: "The core did not come up in time.\n\(logTail)")
        case let .exitedEarly(status, logTail):
            String(localized: "The core exited with status \(status).\n\(logTail)")
        case .notRunning:
            String(localized: "The core is not running.")
        case let .requiresPrivilegedCore(feature):
            String(localized: "\(feature) needs the privileged helper. Install it in Settings → Helper.")
        }
    }
}
