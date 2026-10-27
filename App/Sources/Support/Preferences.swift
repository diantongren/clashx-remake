import ConfigKit
import Foundation
import Observation

/// All user preferences, persisted to `UserDefaults` and observable from SwiftUI.
@Observable
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedProfile = defaults.string(forKey: Keys.selectedProfile) ?? "config"
        overrides = Self.decode(ConfigOverrides.self, defaults.data(forKey: Keys.overrides)) ?? ConfigOverrides()
        systemProxyEnabled = defaults.bool(forKey: Keys.systemProxyEnabled)
        showSpeedInMenuBar = defaults.object(forKey: Keys.showSpeed) as? Bool ?? true
        bypassList = defaults.stringArray(forKey: Keys.bypassList) ?? Self.defaultBypassList
        filterInterfaces = defaults.object(forKey: Keys.filterInterfaces) as? Bool ?? true
        benchmarkURL = defaults.string(forKey: Keys.benchmarkURL) ?? Self.defaultBenchmarkURL
        tunDNS = defaults.string(forKey: Keys.tunDNS) ?? "8.8.8.8"
        webDashboard = WebDashboard(rawValue: defaults.string(forKey: Keys.webDashboard) ?? "") ?? .zashboard
        hideUnselectableGroups = defaults.bool(forKey: Keys.hideUnselectable)
        preferUserSpaceCore = defaults.bool(forKey: Keys.preferUserSpaceCore)
        selectedProxies = Self.decode([String: String].self, defaults.data(forKey: Keys.selectedProxies)) ?? [:]
    }

    var selectedProfile: String { didSet { defaults.set(selectedProfile, forKey: Keys.selectedProfile) } }
    var overrides: ConfigOverrides { didSet { defaults.set(Self.encode(overrides), forKey: Keys.overrides) } }
    var systemProxyEnabled: Bool { didSet { defaults.set(systemProxyEnabled, forKey: Keys.systemProxyEnabled) } }
    var showSpeedInMenuBar: Bool { didSet { defaults.set(showSpeedInMenuBar, forKey: Keys.showSpeed) } }
    var bypassList: [String] { didSet { defaults.set(bypassList, forKey: Keys.bypassList) } }
    var filterInterfaces: Bool { didSet { defaults.set(filterInterfaces, forKey: Keys.filterInterfaces) } }
    var benchmarkURL: String {
        didSet {
            if benchmarkURL.trimmingCharacters(in: .whitespaces).isEmpty { benchmarkURL = Self.defaultBenchmarkURL }
            defaults.set(benchmarkURL, forKey: Keys.benchmarkURL)
        }
    }
    var tunDNS: String { didSet { defaults.set(tunDNS, forKey: Keys.tunDNS) } }
    var webDashboard: WebDashboard { didSet { defaults.set(webDashboard.rawValue, forKey: Keys.webDashboard) } }
    var hideUnselectableGroups: Bool { didSet { defaults.set(hideUnselectableGroups, forKey: Keys.hideUnselectable) } }
    /// Developer switch: run the core as the current user even when the helper is available.
    var preferUserSpaceCore: Bool { didSet { defaults.set(preferUserSpaceCore, forKey: Keys.preferUserSpaceCore) } }
    /// `"profile|group" -> node`, replayed after every reload like ClashX does.
    var selectedProxies: [String: String] { didSet { defaults.set(Self.encode(selectedProxies), forKey: Keys.selectedProxies) } }

    func rememberSelection(profile: String, group: String, node: String) {
        selectedProxies["\(profile)|\(group)"] = node
    }

    func rememberedSelections(profile: String) -> [String: String] {
        var result = [String: String]()
        let prefix = "\(profile)|"
        for (key, value) in selectedProxies where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    static let defaultBenchmarkURL = "https://cp.cloudflare.com/generate_204"
    static let defaultBypassList = [
        "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "127.0.0.1", "localhost", "*.local",
        "timestamp.apple.com", "sequoia.apple.com", "seed-sequoia.siri.apple.com",
    ]

    private enum Keys {
        static let selectedProfile = "selectedProfile"
        static let overrides = "configOverrides"
        static let systemProxyEnabled = "systemProxyEnabled"
        static let showSpeed = "showSpeedInMenuBar"
        static let bypassList = "bypassList"
        static let filterInterfaces = "filterInterfaces"
        static let benchmarkURL = "benchmarkURL"
        static let tunDNS = "tunDNS"
        static let webDashboard = "webDashboard"
        static let hideUnselectable = "hideUnselectableGroups"
        static let preferUserSpaceCore = "preferUserSpaceCore"
        static let selectedProxies = "selectedProxies"
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    private static func decode<T: Decodable>(_: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

enum WebDashboard: String, CaseIterable, Identifiable {
    case zashboard, metacubexd, yacd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zashboard: "zashboard"
        case .metacubexd: "metacubexd"
        case .yacd: "Yacd-meta"
        }
    }

    /// Hosted builds of the official dashboards, pre-filled with the local controller.
    /// The secret only ever travels in the URL fragment (never sent to the hosting server);
    /// yacd reads the query string instead, so it gets host and port only and the user pastes
    /// the secret once (there is a copy button in the Web Dashboard toolbar).
    func url(port: Int, secret: String) -> URL? {
        let secretEncoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret
        switch self {
        case .zashboard:
            return URL(string: "https://board.zash.run.place/#/setup?hostname=127.0.0.1&port=\(port)&secret=\(secretEncoded)")
        case .metacubexd:
            return URL(string: "https://metacubex.github.io/metacubexd/#/setup?hostname=127.0.0.1&port=\(port)&secret=\(secretEncoded)")
        case .yacd:
            return URL(string: "https://yacd.metacubex.one/?hostname=127.0.0.1&port=\(port)")
        }
    }

    var needsManualSecret: Bool { self == .yacd }
}
