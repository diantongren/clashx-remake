import Foundation
import HelperProtocol
import SystemConfiguration

/// Reads the effective system proxy (no privileges needed) and writes it through the helper.
final class SystemProxyController {
    struct Snapshot: Equatable, Sendable {
        var httpHost: String?
        var httpPort: Int?
        var socksHost: String?
        var socksPort: Int?

        /// True when the system points at a loopback proxy on the given ports.
        func pointsAt(httpPort: Int, socksPort: Int) -> Bool {
            let loopback: Set<String> = ["127.0.0.1", "localhost", "::1"]
            let httpMatch = httpHost.map(loopback.contains) == true && self.httpPort == httpPort
            let socksMatch = socksHost.map(loopback.contains) == true && self.socksPort == socksPort
            return httpMatch || socksMatch
        }

        var isAnyProxySet: Bool { httpPort != nil || socksPort != nil }
    }

    private let helper: HelperClient

    init(helper: HelperClient) {
        self.helper = helper
    }

    /// Current global proxy state as seen by every process on the machine.
    nonisolated static func currentSnapshot() -> Snapshot {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return Snapshot()
        }
        func enabled(_ key: CFString) -> Bool { (settings[key as String] as? Int ?? 0) != 0 }
        var snapshot = Snapshot()
        if enabled(kCFNetworkProxiesHTTPEnable) {
            snapshot.httpHost = settings[kCFNetworkProxiesHTTPProxy as String] as? String
            snapshot.httpPort = settings[kCFNetworkProxiesHTTPPort as String] as? Int
        }
        if enabled(kCFNetworkProxiesSOCKSEnable) {
            snapshot.socksHost = settings[kCFNetworkProxiesSOCKSProxy as String] as? String
            snapshot.socksPort = settings[kCFNetworkProxiesSOCKSPort as String] as? Int
        }
        return snapshot
    }

    func enable(httpPort: Int, socksPort: Int, bypass: [String], filterInterfaces: Bool) async throws {
        let configuration = SystemProxyConfiguration(httpPort: httpPort, socksPort: socksPort,
                                                     filterInterfaces: filterInterfaces, bypassList: bypass)
        _ = try await helper.request(HelperMessages.SetSystemProxy(configuration: configuration))
    }

    func disable(filterInterfaces: Bool) async throws {
        _ = try await helper.request(HelperMessages.ClearSystemProxy(filterInterfaces: filterInterfaces))
    }
}

/// Fires whenever the global proxy configuration changes (another app, VPN, Wi-Fi switch…).
final class NetworkProxyObserver {
    nonisolated(unsafe) private var store: SCDynamicStore?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(version: 0,
                                            info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let observer = Unmanaged<NetworkProxyObserver>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in observer.onChange() }
        }
        guard let store = SCDynamicStoreCreate(nil, "app.clashx.remake.proxy-observer" as CFString, callback, &context) else {
            return
        }
        let keys = ["State:/Network/Global/Proxies", "State:/Network/Global/IPv4"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)
        SCDynamicStoreSetDispatchQueue(store, DispatchQueue.global(qos: .utility))
        self.store = store
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}
