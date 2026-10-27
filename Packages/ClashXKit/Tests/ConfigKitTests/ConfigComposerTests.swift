import Foundation
import Testing
import Yams
@testable import ConfigKit

@Suite("ConfigComposer")
struct ConfigComposerTests {
    private func load(_ yaml: String) throws -> [String: Any] {
        try #require(try Yams.load(yaml: yaml) as? [String: Any])
    }

    @Test("mode and log level are always overridden")
    func alwaysOverrides() throws {
        let profile = """
        mode: global
        log-level: debug
        proxies: []
        """
        let out = try ConfigComposer.compose(profileYAML: profile, overrides: .init(mode: .direct, logLevel: .warning))
        let yaml = try load(out)
        #expect(yaml["mode"] as? String == "direct")
        #expect(yaml["log-level"] as? String == "warning")
        #expect(yaml["proxies"] as? [Any] != nil)
    }

    @Test("optional overrides keep the profile value when nil")
    func optionalKeepsProfile() throws {
        let profile = "allow-lan: true\nipv6: true\n"
        let out = try ConfigComposer.compose(profileYAML: profile, overrides: .init())
        let yaml = try load(out)
        #expect(yaml["allow-lan"] as? Bool == true)
        #expect(yaml["ipv6"] as? Bool == true)
    }

    @Test("optional overrides replace the profile value when set")
    func optionalReplaces() throws {
        let profile = "allow-lan: true\n"
        let out = try ConfigComposer.compose(profileYAML: profile, overrides: .init(allowLan: false, ipv6: false))
        let yaml = try load(out)
        #expect(yaml["allow-lan"] as? Bool == false)
        #expect(yaml["ipv6"] as? Bool == false)
    }

    @Test("tun block is injected with sane defaults when missing")
    func tunInjected() throws {
        let out = try ConfigComposer.compose(profileYAML: "mode: rule\n", overrides: .init(tunEnabled: true))
        let yaml = try load(out)
        let tun = try #require(yaml["tun"] as? [String: Any])
        #expect(tun["enable"] as? Bool == true)
        #expect(tun["auto-route"] as? Bool == true)
        #expect((tun["dns-hijack"] as? [String])?.contains("any:53") == true)
    }

    @Test("existing tun block only gets its enable flag touched")
    func tunPreserved() throws {
        let profile = """
        tun:
          enable: true
          stack: gvisor
          mtu: 1400
        """
        let out = try ConfigComposer.compose(profileYAML: profile, overrides: .init(tunEnabled: false))
        let tun = try #require(try load(out)["tun"] as? [String: Any])
        #expect(tun["enable"] as? Bool == false)
        #expect(tun["stack"] as? String == "gvisor")
        #expect(tun["mtu"] as? Int == 1400)
    }

    @Test("existing tun block is untouched when no intent")
    func tunUntouched() throws {
        let profile = "tun:\n  enable: true\n  stack: system\n"
        let out = try ConfigComposer.compose(profileYAML: profile, overrides: .init())
        let tun = try #require(try load(out)["tun"] as? [String: Any])
        #expect(tun["enable"] as? Bool == true)
    }

    @Test("sniffer defaults are injected")
    func snifferInjected() throws {
        let out = try ConfigComposer.compose(profileYAML: "mode: rule\n", overrides: .init(snifferEnabled: true))
        let sniffer = try #require(try load(out)["sniffer"] as? [String: Any])
        #expect(sniffer["enable"] as? Bool == true)
        #expect((sniffer["sniff"] as? [String: Any])?["TLS"] != nil)
    }

    @Test("empty profile still produces a valid mapping")
    func emptyProfile() throws {
        let out = try ConfigComposer.compose(profileYAML: "", overrides: .init())
        let yaml = try load(out)
        #expect(yaml["mode"] as? String == "rule")
    }

    @Test("non-mapping profile is rejected")
    func rejectsSequence() {
        #expect(throws: ConfigComposerError.self) {
            try ConfigComposer.compose(profileYAML: "- a\n- b\n", overrides: .init())
        }
    }

    @Test("ports from the bootstrap replace the profile's and controller keys are stripped")
    func portsAndControllerKeys() throws {
        let profile = """
        mixed-port: 7890
        port: 1
        external-controller: 0.0.0.0:9090
        external-controller-unix: /tmp/x.sock
        secret: leaked
        external-ui: /etc
        rules: []
        """
        let out = try ConfigComposer.compose(profileYAML: profile,
                                             overrides: .init(ports: PortOverrides(mixedPort: 7891)))
        let yaml = try load(out)
        #expect(yaml["mixed-port"] as? Int == 7891)
        #expect(yaml["port"] == nil)
        #expect(yaml["external-controller"] == nil)
        #expect(yaml["external-controller-unix"] == nil)
        #expect(yaml["secret"] == nil)
        #expect(yaml["external-ui"] == nil)
        #expect(yaml["rules"] as? [Any] != nil)
    }

    @Test("without port overrides the profile ports survive, controller keys still stripped")
    func noPortOverrides() throws {
        let out = try ConfigComposer.compose(profileYAML: "mixed-port: 7000\nsecret: s\n", overrides: .init())
        let yaml = try load(out)
        #expect(yaml["mixed-port"] as? Int == 7000)
        #expect(yaml["secret"] == nil)
    }
}
