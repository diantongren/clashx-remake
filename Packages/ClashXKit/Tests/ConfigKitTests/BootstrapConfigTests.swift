import Foundation
import Testing
import Yams
@testable import ConfigKit

@Suite("BootstrapConfig")
struct BootstrapConfigTests {
    @Test("adopts ports, controller and secret from the profile")
    func adopt() {
        var config = BootstrapConfig(secret: "x")
        config.adopt(profileYAML: """
        external-controller: 0.0.0.0:19090
        secret: abc
        port: 7891
        socks-port: 7892
        """)
        #expect(config.externalControllerPort == 19090)
        #expect(config.secret == "abc")
        #expect(config.port == 7891)
        #expect(config.socksPort == 7892)
        #expect(config.mixedPort == nil)
    }

    @Test("mixed-port wins over port/socks-port and defaults to 7890")
    func mixedPort() {
        var a = BootstrapConfig(secret: "x")
        a.adopt(profileYAML: "mixed-port: 7000\nport: 7891\n")
        #expect(a.mixedPort == 7000)
        #expect(a.port == nil)

        var b = BootstrapConfig(secret: "x")
        b.adopt(profileYAML: "mode: rule\n")
        #expect(b.mixedPort == 7890)
    }

    @Test("port conflicts move to the next free port, controller is forced to loopback")
    func conflicts() {
        var config = BootstrapConfig(secret: "x")
        config.adopt(profileYAML: "external-controller: 0.0.0.0:9090\nmixed-port: 7890\n")
        config.resolvePortConflicts(using: .simulated(busy: [7890, 7891, 9090]))
        #expect(config.mixedPort == 7892)
        #expect(config.externalControllerPort == 9091)
        #expect(config.externalController == "127.0.0.1:9091")
    }

    @Test("distinct ports never collide with each other")
    func noSelfCollision() {
        var config = BootstrapConfig(secret: "x")
        config.port = 7890
        config.socksPort = 7890
        config.externalControllerPort = 7890
        config.resolvePortConflicts(using: .simulated(busy: []))
        let ports = Set([config.port!, config.socksPort!, config.externalControllerPort])
        #expect(ports.count == 3)
    }

    @Test("yaml output round-trips")
    func yaml() throws {
        var config = BootstrapConfig(secret: "s3cret", logLevel: .warning)
        config.mixedPort = 7890
        config.externalUI = "/tmp/ui"
        let yaml = try #require(try Yams.load(yaml: config.yamlString()) as? [String: Any])
        #expect(yaml["secret"] as? String == "s3cret")
        #expect(yaml["mixed-port"] as? Int == 7890)
        #expect(yaml["external-controller"] as? String == "127.0.0.1:9090")
        #expect(yaml["external-ui"] as? String == "/tmp/ui")
        #expect((yaml["rules"] as? [String])?.first == BootstrapConfig.placeholderRule)
    }
}
