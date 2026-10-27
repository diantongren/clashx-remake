import Foundation

// MARK: - Version / config

public struct CoreVersion: Codable, Sendable, Equatable {
    public var version: String
    public var meta: Bool?
    public var premium: Bool?
}

public struct TunConfig: Codable, Sendable, Equatable {
    public var enable: Bool
    public var stack: String?
    public var device: String?
    public var autoRoute: Bool?
    public var autoDetectInterface: Bool?
    public var dnsHijack: [String]?

    enum CodingKeys: String, CodingKey {
        case enable, stack, device
        case autoRoute = "auto-route"
        case autoDetectInterface = "auto-detect-interface"
        case dnsHijack = "dns-hijack"
    }
}

/// Response of `GET /configs`.
public struct ClashConfig: Codable, Sendable, Equatable {
    public var port: Int
    public var socksPort: Int
    public var mixedPort: Int
    public var redirPort: Int?
    public var tproxyPort: Int?
    public var allowLan: Bool
    public var bindAddress: String?
    public var mode: String
    public var logLevel: String
    public var ipv6: Bool?
    public var tun: TunConfig?
    public var sniffing: Bool?
    public var unifiedDelay: Bool?
    public var tcpConcurrent: Bool?
    public var interfaceName: String?

    enum CodingKeys: String, CodingKey {
        case port, mode, ipv6, tun, sniffing
        case socksPort = "socks-port"
        case mixedPort = "mixed-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case allowLan = "allow-lan"
        case bindAddress = "bind-address"
        case logLevel = "log-level"
        case unifiedDelay = "unified-delay"
        case tcpConcurrent = "tcp-concurrent"
        case interfaceName = "interface-name"
    }

    /// The HTTP proxy port clients should use (mixed port wins).
    public var effectiveHTTPPort: Int { mixedPort != 0 ? mixedPort : port }
    /// The SOCKS proxy port clients should use (mixed port wins).
    public var effectiveSocksPort: Int { mixedPort != 0 ? mixedPort : socksPort }
}

/// Body of `PATCH /configs`. Only non-nil fields are sent.
public struct ConfigPatch: Codable, Sendable, Equatable {
    public var mode: String?
    public var logLevel: String?
    public var allowLan: Bool?
    public var tun: TunPatch?
    public var sniffing: Bool?
    public var ipv6: Bool?

    public struct TunPatch: Codable, Sendable, Equatable {
        public var enable: Bool
        public init(enable: Bool) { self.enable = enable }
    }

    public init(mode: String? = nil, logLevel: String? = nil, allowLan: Bool? = nil,
                tun: TunPatch? = nil, sniffing: Bool? = nil, ipv6: Bool? = nil) {
        self.mode = mode
        self.logLevel = logLevel
        self.allowLan = allowLan
        self.tun = tun
        self.sniffing = sniffing
        self.ipv6 = ipv6
    }

    enum CodingKeys: String, CodingKey {
        case mode, tun, sniffing, ipv6
        case logLevel = "log-level"
        case allowLan = "allow-lan"
    }
}

// MARK: - Proxies

public enum ProxyType: String, Codable, Sendable, Hashable {
    // Groups
    case selector = "Selector"
    case urlTest = "URLTest"
    case fallback = "Fallback"
    case loadBalance = "LoadBalance"
    case relay = "Relay"
    // Built-ins
    case direct = "Direct"
    case reject = "Reject"
    case rejectDrop = "RejectDrop"
    case compatible = "Compatible"
    case pass = "Pass"
    case dns = "Dns"
    // Outbounds (not exhaustive, anything else decodes as `.other`)
    case shadowsocks = "Shadowsocks"
    case shadowsocksR = "ShadowsocksR"
    case snell = "Snell"
    case socks5 = "Socks5"
    case http = "Http"
    case vmess = "Vmess"
    case vless = "Vless"
    case trojan = "Trojan"
    case hysteria = "Hysteria"
    case hysteria2 = "Hysteria2"
    case wireGuard = "WireGuard"
    case tuic = "Tuic"
    case ssh = "Ssh"
    case mieru = "Mieru"
    case anyTLS = "AnyTLS"
    case other = "__other__"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProxyType(rawValue: raw) ?? .other
    }

    public var isGroup: Bool {
        switch self {
        case .selector, .urlTest, .fallback, .loadBalance, .relay: true
        default: false
        }
    }

    /// Groups whose active node the user can pick.
    public var isSelectable: Bool { self == .selector }
}

public struct DelayHistory: Codable, Sendable, Equatable, Hashable {
    public var time: Date
    public var delay: Int
}

public struct Proxy: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var type: ProxyType
    public var typeName: String
    public var now: String?
    public var all: [String]?
    public var history: [DelayHistory]
    public var alive: Bool?
    public var hidden: Bool?
    public var udp: Bool?
    public var xudp: Bool?
    public var tfo: Bool?
    public var icon: String?
    public var testUrl: String?
    public var expectedStatus: String?
    public var fixed: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, type, now, all, history, alive, hidden, udp, xudp, tfo, icon, fixed
        case testUrl, expectedStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        typeName = try c.decode(String.self, forKey: .type)
        type = ProxyType(rawValue: typeName) ?? .other
        now = try c.decodeIfPresent(String.self, forKey: .now)
        all = try c.decodeIfPresent([String].self, forKey: .all)
        history = try c.decodeIfPresent([DelayHistory].self, forKey: .history) ?? []
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        udp = try c.decodeIfPresent(Bool.self, forKey: .udp)
        xudp = try c.decodeIfPresent(Bool.self, forKey: .xudp)
        tfo = try c.decodeIfPresent(Bool.self, forKey: .tfo)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        testUrl = try c.decodeIfPresent(String.self, forKey: .testUrl)
        expectedStatus = try c.decodeIfPresent(String.self, forKey: .expectedStatus)
        fixed = try c.decodeIfPresent(String.self, forKey: .fixed)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(typeName, forKey: .type)
        try c.encodeIfPresent(now, forKey: .now)
        try c.encodeIfPresent(all, forKey: .all)
        try c.encode(history, forKey: .history)
        try c.encodeIfPresent(alive, forKey: .alive)
        try c.encodeIfPresent(hidden, forKey: .hidden)
        try c.encodeIfPresent(udp, forKey: .udp)
        try c.encodeIfPresent(xudp, forKey: .xudp)
        try c.encodeIfPresent(tfo, forKey: .tfo)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(testUrl, forKey: .testUrl)
        try c.encodeIfPresent(expectedStatus, forKey: .expectedStatus)
        try c.encodeIfPresent(fixed, forKey: .fixed)
    }

    /// Most recent latency sample, `nil` when never tested, `0` when the last test failed.
    public var latestDelay: Int? { history.last?.delay }
}

public struct ProxiesResponse: Codable, Sendable, Equatable {
    public var proxies: [String: Proxy]

    /// Groups in the order the core reports them inside `GLOBAL.all`, falling back to name order.
    public var orderedGroups: [Proxy] {
        let groups = proxies.values.filter { $0.type.isGroup && $0.name != "GLOBAL" }
        if let order = proxies["GLOBAL"]?.all {
            let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            return groups.sorted { (index[$0.name] ?? .max, $0.name) < (index[$1.name] ?? .max, $1.name) }
        }
        return groups.sorted { $0.name < $1.name }
    }
}

public struct DelayResponse: Codable, Sendable, Equatable {
    public var delay: Int
}

// MARK: - Providers

public enum VehicleType: String, Codable, Sendable {
    case http = "HTTP"
    case file = "File"
    case inline = "Inline"
    case compatible = "Compatible"
    case other = "__other__"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VehicleType(rawValue: raw) ?? .other
    }
}

public struct SubscriptionInfo: Codable, Sendable, Equatable {
    public var upload: Int64?
    public var download: Int64?
    public var total: Int64?
    public var expire: Int64?

    enum CodingKeys: String, CodingKey {
        case upload = "Upload", download = "Download", total = "Total", expire = "Expire"
    }
}

public struct ProxyProvider: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var type: String
    public var vehicleType: VehicleType
    public var proxies: [Proxy]
    public var updatedAt: Date?
    public var subscriptionInfo: SubscriptionInfo?
    public var testUrl: String?

    public var id: String { name }
}

public struct ProxyProvidersResponse: Codable, Sendable, Equatable {
    public var providers: [String: ProxyProvider]
}

public struct RuleProvider: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var type: String
    public var behavior: String
    public var format: String?
    public var vehicleType: VehicleType
    public var ruleCount: Int
    public var updatedAt: Date?

    public var id: String { name }
}

public struct RuleProvidersResponse: Codable, Sendable, Equatable {
    public var providers: [String: RuleProvider]
}

// MARK: - Rules / connections

public struct Rule: Codable, Sendable, Identifiable, Equatable {
    public var type: String
    public var payload: String
    public var proxy: String
    public var size: Int?

    public var id: String { "\(type)|\(payload)|\(proxy)" }
}

public struct RulesResponse: Codable, Sendable, Equatable {
    public var rules: [Rule]
}

public struct ConnectionMetadata: Codable, Sendable, Equatable, Hashable {
    public var network: String
    public var type: String
    public var sourceIP: String
    public var destinationIP: String
    public var sourcePort: String
    public var destinationPort: String
    public var host: String
    public var dnsMode: String?
    public var process: String?
    public var processPath: String?
    public var remoteDestination: String?
    public var sniffHost: String?

    public var displayHost: String {
        if !host.isEmpty { return host }
        if !destinationIP.isEmpty { return destinationIP }
        return remoteDestination ?? ""
    }
}

public struct Connection: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var metadata: ConnectionMetadata
    public var upload: Int64
    public var download: Int64
    public var start: Date
    public var chains: [String]
    public var rule: String
    public var rulePayload: String
}

public struct ConnectionsSnapshot: Codable, Sendable, Equatable {
    public var downloadTotal: Int64
    public var uploadTotal: Int64
    public var connections: [Connection]?
    public var memory: Int64?
}

// MARK: - Streams

public struct Traffic: Codable, Sendable, Equatable {
    public var up: Int64
    public var down: Int64
    public static let zero = Traffic(up: 0, down: 0)
    public init(up: Int64, down: Int64) { self.up = up; self.down = down }
}

public struct MemoryUsage: Codable, Sendable, Equatable {
    public var inuse: Int64
    public var oslimit: Int64?
}

public struct LogEntry: Codable, Sendable, Identifiable, Equatable {
    public var type: String
    public var payload: String
    public var id = UUID()

    enum CodingKeys: String, CodingKey { case type, payload }

    public init(type: String, payload: String) {
        self.type = type
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        payload = try c.decode(String.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(payload, forKey: .payload)
    }
}

// MARK: - Date handling

enum MihomoDates {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parse(raw) { return date }
            // The zero value Go emits for "never" ("0001-01-01T00:00:00Z") parses fine, anything else is an error.
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(raw)")
        }
        return decoder
    }
}
