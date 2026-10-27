import Foundation
import HelperProtocol
import SystemConfiguration

/// TUN mode needs the system resolver pointed at the core. We swap the DNS servers of every
/// eligible service and remember the originals on disk so they survive a helper restart.
actor DNSConfigurator {
    private static let stateFile = URL(fileURLWithPath: "/Library/Application Support/app.clashx.remake/saved-dns.json")
    private static let eligibleHardware: Set<String> = ["AirPort", "Wi-Fi", "Ethernet"]
    private var saved: [String: [String]]

    init() {
        saved = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: Self.stateFile))) ?? [:]
    }

    func hijack(servers: [String]) throws {
        let current = Self.currentDNS()
        // Trust what we saved only when the system still shows our hijacked value.
        var originals = [String: [String]]()
        for (id, system) in current {
            if system == servers, let previous = saved[id], previous != servers {
                originals[id] = previous
            } else {
                originals[id] = system
            }
        }
        saved = originals
        persist()
        guard !current.values.allSatisfy({ $0 == servers }) else { return }
        try Self.write(current.mapValues { _ in servers })
    }

    func restore() throws {
        guard !saved.isEmpty else { return }
        try Self.write(saved)
        saved.removeAll()
        persist()
    }

    func flushCache() async {
        await run("/usr/bin/dscacheutil", ["-flushcache"])
        await run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    // MARK: - Private

    private func persist() {
        let directory = Self.stateFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if saved.isEmpty {
            try? FileManager.default.removeItem(at: Self.stateFile)
        } else {
            try? JSONEncoder().encode(saved).write(to: Self.stateFile, options: .atomic)
        }
    }

    private func run(_ path: String, _ arguments: [String]) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = nil
        process.standardError = nil
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }

    private static func currentDNS() -> [String: [String]] {
        guard let prefs = SCPreferencesCreate(nil, "app.clashx.remake.helper.dns" as CFString, nil),
              let all = SCPreferencesGetValue(prefs, kSCPrefNetworkServices) as? [String: [String: Any]],
              let store = SCDynamicStoreCreate(nil, "app.clashx.remake.helper.dns" as CFString, nil, nil) else { return [:] }
        var result = [String: [String]]()
        for (id, dictionary) in all {
            let hardware = (dictionary["Interface"] as? [String: Any])?["Hardware"] as? String ?? ""
            guard eligibleHardware.contains(hardware) else { continue }
            let key = "Setup:/Network/Service/\(id)/DNS" as CFString
            let value = SCDynamicStoreCopyValue(store, key) as? [String: Any]
            result[id] = value?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
        }
        return result
    }

    private static func write(_ servers: [String: [String]]) throws {
        guard let prefs = SCPreferencesCreate(nil, "app.clashx.remake.helper.dns" as CFString, nil) else {
            throw HelperProtocolError.remote("SCPreferencesCreate failed")
        }
        guard SCPreferencesLock(prefs, true) else { throw HelperProtocolError.remote("Could not lock network preferences") }
        defer { SCPreferencesUnlock(prefs) }
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw HelperProtocolError.remote("No current network set")
        }
        for service in services {
            guard let id = SCNetworkServiceGetServiceID(service) as String?, let dns = servers[id],
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
            var configuration = (SCNetworkProtocolGetConfiguration(proto) as? [String: Any]) ?? [:]
            if dns.isEmpty {
                configuration.removeValue(forKey: kSCPropNetDNSServerAddresses as String)
            } else {
                configuration[kSCPropNetDNSServerAddresses as String] = dns
            }
            guard SCNetworkProtocolSetConfiguration(proto, configuration.isEmpty ? nil : configuration as CFDictionary) else {
                throw HelperProtocolError.remote("Failed to set DNS for \(id)")
            }
        }
        guard SCPreferencesCommitChanges(prefs) else { throw HelperProtocolError.remote("Commit failed") }
        guard SCPreferencesApplyChanges(prefs) else { throw HelperProtocolError.remote("Apply failed") }
    }
}
