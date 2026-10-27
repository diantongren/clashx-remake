import Foundation
import Yams

/// The tiny configuration the core is *launched* with. The real profile is pushed
/// through the REST API afterwards, exactly like ClashX Meta does, so a broken
/// profile can never prevent the controller from coming up.
public struct BootstrapConfig: Sendable, Equatable {
    public var externalControllerHost = "127.0.0.1"
    public var externalControllerPort = 9090
    public var secret: String
    public var externalUI: String?
    public var port: Int?
    public var socksPort: Int?
    public var mixedPort: Int?
    public var logLevel: LogLevel
    public var geodataMode: Bool?
    public var geoxURL: [String: String]?

    /// A rule that can never match, so the core is idle until the profile arrives.
    public static let placeholderRule = "DOMAIN-KEYWORD,clashx-remake-bootstrap-placeholder,REJECT"

    public init(secret: String = BootstrapConfig.randomSecret(), logLevel: LogLevel = .info) {
        self.secret = secret
        self.logLevel = logLevel
    }

    public var externalController: String { "\(externalControllerHost):\(externalControllerPort)" }

    /// The ports a composed profile must use so it matches what the core was launched with.
    public var portOverrides: PortOverrides { PortOverrides(port: port, socksPort: socksPort, mixedPort: mixedPort) }

    public static func randomSecret(length: Int = 32) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Picks up ports, controller address and geo settings from the user's profile.
    public mutating func adopt(profileYAML: String) {
        guard let yaml = try? Yams.load(yaml: profileYAML) as? [String: Any] else { return }
        if let ec = yaml["external-controller"] as? String {
            let parts = ec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if let last = parts.last, let port = Int(last) {
                externalControllerPort = port
            }
        }
        if let secret = yaml["secret"] as? String, !secret.isEmpty { self.secret = secret }
        if let mixed = yaml["mixed-port"] as? Int {
            mixedPort = mixed
        } else {
            port = yaml["port"] as? Int
            socksPort = yaml["socks-port"] as? Int
        }
        if port == nil && mixedPort == nil { mixedPort = 7890 }
        if let urls = yaml["geox-url"] as? [String: String] { geoxURL = urls }
        if let mode = yaml["geodata-mode"] as? Bool { geodataMode = mode }
    }

    /// Moves every configured port off the given set of occupied ports.
    public mutating func resolvePortConflicts(using allocator: PortAllocator) {
        var allocator = allocator
        port = port.map { allocator.claim(preferring: $0) }
        socksPort = socksPort.map { allocator.claim(preferring: $0) }
        mixedPort = mixedPort.map { allocator.claim(preferring: $0) }
        externalControllerPort = allocator.claim(preferring: externalControllerPort)
        externalControllerHost = "127.0.0.1"
    }

    public func yamlString() throws -> String {
        var root: [String: Any] = [
            "external-controller": externalController,
            "secret": secret,
            "log-level": logLevel.rawValue,
            "rules": [Self.placeholderRule],
        ]
        if let externalUI { root["external-ui"] = externalUI }
        if let port { root["port"] = port }
        if let socksPort { root["socks-port"] = socksPort }
        if let mixedPort { root["mixed-port"] = mixedPort }
        if let geodataMode { root["geodata-mode"] = geodataMode }
        if let geoxURL { root["geox-url"] = geoxURL }
        return try Yams.dump(object: root, sortKeys: true)
    }
}
