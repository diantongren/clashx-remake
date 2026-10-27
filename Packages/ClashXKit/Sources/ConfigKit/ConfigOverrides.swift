import Foundation
import Yams

/// User intent that is layered on top of whatever profile is active.
public struct ConfigOverrides: Codable, Sendable, Equatable {
    public var mode: ProxyMode = .rule
    public var logLevel: LogLevel = .info
    /// `nil` keeps the profile's own value.
    public var allowLan: Bool?
    public var tunEnabled: Bool?
    public var snifferEnabled: Bool?
    public var ipv6: Bool?
    /// Listening ports decided at launch (after collision avoidance). When set, the profile's own
    /// `port` / `socks-port` / `mixed-port` are replaced so a reload can never move the proxy.
    public var ports: PortOverrides?

    public init(mode: ProxyMode = .rule, logLevel: LogLevel = .info, allowLan: Bool? = nil,
                tunEnabled: Bool? = nil, snifferEnabled: Bool? = nil, ipv6: Bool? = nil,
                ports: PortOverrides? = nil) {
        self.mode = mode
        self.logLevel = logLevel
        self.allowLan = allowLan
        self.tunEnabled = tunEnabled
        self.snifferEnabled = snifferEnabled
        self.ipv6 = ipv6
        self.ports = ports
    }
}

public struct PortOverrides: Codable, Sendable, Equatable {
    public var port: Int?
    public var socksPort: Int?
    public var mixedPort: Int?

    public init(port: Int? = nil, socksPort: Int? = nil, mixedPort: Int? = nil) {
        self.port = port
        self.socksPort = socksPort
        self.mixedPort = mixedPort
    }
}

public enum ConfigComposerError: Error, LocalizedError, Sendable {
    case notAMapping
    case invalidYAML(String)

    public var errorDescription: String? {
        switch self {
        case .notAMapping: "The configuration file is not a YAML mapping."
        case let .invalidYAML(message): "Invalid YAML: \(message)"
        }
    }
}

/// Applies `ConfigOverrides` to a profile and returns the YAML the core should load.
public enum ConfigComposer {
    public static func compose(profileYAML: String, overrides: ConfigOverrides) throws -> String {
        var root: Node = [:]
        do {
            if let parsed = try Yams.compose(yaml: profileYAML) { root = parsed }
        } catch let error as YamlError {
            throw ConfigComposerError.invalidYAML(error.description)
        }
        guard root.mapping != nil else { throw ConfigComposerError.notAMapping }
        return try serialize(apply(overrides, to: &root))
    }

    @discardableResult
    static func apply(_ overrides: ConfigOverrides, to root: inout Node) -> Node {
        root["mode"] = Node(overrides.mode.rawValue)
        root["log-level"] = Node(overrides.logLevel.rawValue)
        if let allowLan = overrides.allowLan { root["allow-lan"] = bool(allowLan) }
        if let ipv6 = overrides.ipv6 { root["ipv6"] = bool(ipv6) }
        applySniffer(overrides.snifferEnabled, to: &root)
        applyTun(overrides.tunEnabled, to: &root)
        applyPorts(overrides.ports, to: &root)
        stripControllerKeys(from: &root)
        return root
    }

    /// Keys the app owns through the bootstrap config. A profile must not be able to move or
    /// unprotect the controller, nor point `external-ui` at an arbitrary directory.
    static let managedKeys = ["external-controller", "external-controller-unix", "external-controller-tls",
                              "external-controller-pipe", "secret", "external-ui", "external-ui-url", "external-ui-name",
                              "external-doh-server"]

    /// `Node`'s own subscript ignores `nil`; removal has to go through the mapping.
    private static func remove(_ keys: [String], from root: inout Node) {
        guard var mapping = root.mapping else { return }
        for key in keys { mapping[key] = nil }
        root.mapping = mapping
    }

    private static func stripControllerKeys(from root: inout Node) {
        remove(managedKeys, from: &root)
    }

    private static func applyPorts(_ ports: PortOverrides?, to root: inout Node) {
        guard let ports else { return }
        remove(["port", "socks-port", "mixed-port"], from: &root)
        if let port = ports.port { root["port"] = Node(String(port), Tag(.int)) }
        if let socks = ports.socksPort { root["socks-port"] = Node(String(socks), Tag(.int)) }
        if let mixed = ports.mixedPort { root["mixed-port"] = Node(String(mixed), Tag(.int)) }
    }

    private static func applySniffer(_ enabled: Bool?, to root: inout Node) {
        if root["sniffer"]?.mapping != nil {
            if let enabled { root["sniffer"]?["enable"] = bool(enabled) }
            return
        }
        root["sniffer"] = [
            "enable": bool(enabled ?? false),
            "sniff": [
                "HTTP": ["ports": ["80", "8080-8880"], "override-destination": bool(true)],
                "TLS": ["ports": ["443", "8443"]],
                "QUIC": ["ports": ["443", "8443"]],
            ],
            "skip-domain": ["Mijia Cloud", "+.push.apple.com"],
        ]
    }

    private static func applyTun(_ enabled: Bool?, to root: inout Node) {
        if root["tun"]?.mapping != nil {
            if let enabled { root["tun"]?["enable"] = bool(enabled) }
            return
        }
        root["tun"] = [
            "enable": bool(enabled ?? false),
            "stack": "mixed",
            "auto-route": bool(true),
            "auto-detect-interface": bool(true),
            "dns-hijack": ["any:53", "tcp://any:53"],
        ]
    }

    private static func bool(_ value: Bool) -> Node {
        Node(value ? "true" : "false", Tag(.bool))
    }

    private static func serialize(_ node: Node) throws -> String {
        try Yams.serialize(node: node, allowUnicode: true)
    }
}
