import Foundation
import HelperProtocol
import SystemConfiguration

/// Writes proxy settings for every eligible network service. Runs as root, so plain
/// `SCPreferencesCreate` is enough — no Authorization dance needed.
enum SystemProxyConfigurator {
    private static let eligibleHardware: Set<String> = ["AirPort", "Wi-Fi", "Ethernet"]

    static func apply(_ configuration: SystemProxyConfiguration) throws {
        try mutate(filterInterfaces: configuration.filterInterfaces) { _ in
            var settings: [String: Any] = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: configuration.httpPort,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: configuration.httpPort,
                kCFNetworkProxiesSOCKSEnable as String: configuration.socksPort > 0 ? 1 : 0,
                kCFNetworkProxiesExcludeSimpleHostnames as String: 1,
                kCFNetworkProxiesExceptionsList as String: configuration.bypassList,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            ]
            if configuration.socksPort > 0 {
                settings[kCFNetworkProxiesSOCKSProxy as String] = "127.0.0.1"
                settings[kCFNetworkProxiesSOCKSPort as String] = configuration.socksPort
            }
            return settings
        }
    }

    static func clear(filterInterfaces: Bool) throws {
        try mutate(filterInterfaces: filterInterfaces) { _ in
            [
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesSOCKSEnable as String: 0,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                kCFNetworkProxiesExceptionsList as String: [String](),
            ]
        }
    }

    static func snapshot() -> [ServiceProxySnapshot] {
        guard let prefs = SCPreferencesCreate(nil, "app.clashx.remake.helper" as CFString, nil) else { return [] }
        return services(in: prefs, filterInterfaces: true).map { id, dictionary in
            let proxies = dictionary[kSCEntNetProxies as String] as? [String: Any] ?? [:]
            func flag(_ key: CFString) -> Bool { (proxies[key as String] as? Int ?? 0) != 0 }
            return ServiceProxySnapshot(
                serviceID: id,
                serviceName: dictionary["UserDefinedName"] as? String ?? id,
                httpEnabled: flag(kCFNetworkProxiesHTTPEnable),
                httpHost: proxies[kCFNetworkProxiesHTTPProxy as String] as? String,
                httpPort: proxies[kCFNetworkProxiesHTTPPort as String] as? Int,
                httpsEnabled: flag(kCFNetworkProxiesHTTPSEnable),
                httpsHost: proxies[kCFNetworkProxiesHTTPSProxy as String] as? String,
                httpsPort: proxies[kCFNetworkProxiesHTTPSPort as String] as? Int,
                socksEnabled: flag(kCFNetworkProxiesSOCKSEnable),
                socksHost: proxies[kCFNetworkProxiesSOCKSProxy as String] as? String,
                socksPort: proxies[kCFNetworkProxiesSOCKSPort as String] as? Int,
                pacEnabled: flag(kCFNetworkProxiesProxyAutoConfigEnable),
                pacURL: proxies[kCFNetworkProxiesProxyAutoConfigURLString as String] as? String,
                exceptions: proxies[kCFNetworkProxiesExceptionsList as String] as? [String] ?? []
            )
        }
    }

    // MARK: - Plumbing

    private static func services(in prefs: SCPreferences, filterInterfaces: Bool) -> [(String, [String: Any])] {
        guard let all = SCPreferencesGetValue(prefs, kSCPrefNetworkServices) as? [String: [String: Any]] else { return [] }
        return all.compactMap { id, dictionary in
            let hardware = (dictionary["Interface"] as? [String: Any])?["Hardware"] as? String ?? ""
            if filterInterfaces, !eligibleHardware.contains(hardware) { return nil }
            return (id, dictionary)
        }.sorted { $0.0 < $1.0 }
    }

    private static func mutate(filterInterfaces: Bool, settings: (String) -> [String: Any]) throws {
        guard let prefs = SCPreferencesCreate(nil, "app.clashx.remake.helper" as CFString, nil) else {
            throw HelperProtocolError.remote("SCPreferencesCreate failed")
        }
        guard SCPreferencesLock(prefs, true) else {
            throw HelperProtocolError.remote("Could not lock network preferences")
        }
        defer { SCPreferencesUnlock(prefs) }

        for (id, _) in services(in: prefs, filterInterfaces: filterInterfaces) {
            let path = "/\(kSCPrefNetworkServices)/\(id)/\(kSCEntNetProxies)" as CFString
            guard SCPreferencesPathSetValue(prefs, path, settings(id) as CFDictionary) else {
                throw HelperProtocolError.remote("Failed to set proxy for service \(id)")
            }
        }
        guard SCPreferencesCommitChanges(prefs) else { throw HelperProtocolError.remote("Commit failed") }
        guard SCPreferencesApplyChanges(prefs) else { throw HelperProtocolError.remote("Apply failed") }
    }
}
