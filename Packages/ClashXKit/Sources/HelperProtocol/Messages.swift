import Foundation

// MARK: - Shared payloads

/// Everything the helper needs to spawn the proxy core as root.
public struct CoreLaunchRequest: Codable, Sendable, Equatable {
    /// Absolute path of the verified core executable.
    public var executablePath: String
    /// `-d` argument: the directory holding config, geo data and cache.
    public var workingDirectory: String
    /// `-f` argument: the composed configuration file to load.
    public var configFilePath: String
    /// Value of the `SAFE_PATHS` environment variable (colon separated).
    public var safePaths: [String]
    /// Where stdout/stderr of the core should be appended.
    public var logFilePath: String

    public init(executablePath: String, workingDirectory: String, configFilePath: String,
                safePaths: [String], logFilePath: String) {
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.configFilePath = configFilePath
        self.safePaths = safePaths
        self.logFilePath = logFilePath
    }
}

public struct CoreStatus: Codable, Sendable, Equatable {
    public var isRunning: Bool
    public var pid: Int32?
    public var executablePath: String?
    public var lastExitCode: Int32?

    public init(isRunning: Bool, pid: Int32? = nil, executablePath: String? = nil, lastExitCode: Int32? = nil) {
        self.isRunning = isRunning
        self.pid = pid
        self.executablePath = executablePath
        self.lastExitCode = lastExitCode
    }
}

public struct HelperVersion: Codable, Sendable, Equatable {
    public var version: String
    public var build: String
    public var protocolVersion: Int
    public var clientVerified: Bool

    public init(version: String, build: String, protocolVersion: Int, clientVerified: Bool) {
        self.version = version
        self.build = build
        self.protocolVersion = protocolVersion
        self.clientVerified = clientVerified
    }
}

/// Desired system proxy configuration for every eligible network service.
public struct SystemProxyConfiguration: Codable, Sendable, Equatable {
    public var httpPort: Int
    public var socksPort: Int
    /// Only touch Wi-Fi / Ethernet style services when true.
    public var filterInterfaces: Bool
    public var bypassList: [String]

    public init(httpPort: Int, socksPort: Int, filterInterfaces: Bool, bypassList: [String]) {
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.filterInterfaces = filterInterfaces
        self.bypassList = bypassList
    }
}

/// Proxy settings of a single network service as currently stored in the system.
public struct ServiceProxySnapshot: Codable, Sendable, Equatable {
    public var serviceID: String
    public var serviceName: String
    public var httpEnabled: Bool
    public var httpHost: String?
    public var httpPort: Int?
    public var httpsEnabled: Bool
    public var httpsHost: String?
    public var httpsPort: Int?
    public var socksEnabled: Bool
    public var socksHost: String?
    public var socksPort: Int?
    public var pacEnabled: Bool
    public var pacURL: String?
    public var exceptions: [String]

    public init(serviceID: String, serviceName: String,
                httpEnabled: Bool, httpHost: String?, httpPort: Int?,
                httpsEnabled: Bool, httpsHost: String?, httpsPort: Int?,
                socksEnabled: Bool, socksHost: String?, socksPort: Int?,
                pacEnabled: Bool, pacURL: String?, exceptions: [String]) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.httpEnabled = httpEnabled
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsEnabled = httpsEnabled
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
        self.socksEnabled = socksEnabled
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.pacEnabled = pacEnabled
        self.pacURL = pacURL
        self.exceptions = exceptions
    }
}

// MARK: - Messages

public enum HelperMessages {
    public struct GetVersion: HelperMessage {
        public typealias Response = HelperVersion
        public static let kind = "getVersion"
        public init() {}
    }

    public struct StartCore: HelperMessage {
        public typealias Response = CoreStatus
        public static let kind = "startCore"
        public var request: CoreLaunchRequest
        public init(request: CoreLaunchRequest) { self.request = request }
    }

    public struct StopCore: HelperMessage {
        public typealias Response = Empty
        public static let kind = "stopCore"
        public init() {}
    }

    public struct GetCoreStatus: HelperMessage {
        public typealias Response = CoreStatus
        public static let kind = "getCoreStatus"
        public init() {}
    }

    public struct SetSystemProxy: HelperMessage {
        public typealias Response = Empty
        public static let kind = "setSystemProxy"
        public var configuration: SystemProxyConfiguration
        public init(configuration: SystemProxyConfiguration) { self.configuration = configuration }
    }

    public struct ClearSystemProxy: HelperMessage {
        public typealias Response = Empty
        public static let kind = "clearSystemProxy"
        public var filterInterfaces: Bool
        public init(filterInterfaces: Bool) { self.filterInterfaces = filterInterfaces }
    }

    public struct GetSystemProxy: HelperMessage {
        public typealias Response = [ServiceProxySnapshot]
        public static let kind = "getSystemProxy"
        public init() {}
    }

    /// Point every eligible service's DNS at the given servers (TUN mode) and remember the originals.
    public struct HijackDNS: HelperMessage {
        public typealias Response = Empty
        public static let kind = "hijackDNS"
        public var servers: [String]
        public init(servers: [String]) { self.servers = servers }
    }

    public struct RestoreDNS: HelperMessage {
        public typealias Response = Empty
        public static let kind = "restoreDNS"
        public init() {}
    }

    public struct FlushDNSCache: HelperMessage {
        public typealias Response = Empty
        public static let kind = "flushDNSCache"
        public init() {}
    }
}
