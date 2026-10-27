import Foundation
import Testing
@testable import MihomoAPI

@Suite("Model decoding")
struct ModelDecodingTests {
    private let decoder = MihomoDates.makeDecoder()

    @Test func decodesProxiesAndOrdersGroups() throws {
        let json = """
        {"proxies":{
          "GLOBAL":{"name":"GLOBAL","type":"Selector","all":["B","A","Node1"],"now":"A","history":[]},
          "A":{"name":"A","type":"Selector","all":["Node1"],"now":"Node1","history":[]},
          "B":{"name":"B","type":"URLTest","all":["Node1"],"now":"Node1","history":[],"hidden":true},
          "Node1":{"name":"Node1","type":"Hysteria2","history":[{"time":"2024-05-01T12:00:00.123456+08:00","delay":123}],"alive":true,"udp":true},
          "Weird":{"name":"Weird","type":"FutureProto","history":[]}
        }}
        """
        let response = try decoder.decode(ProxiesResponse.self, from: Data(json.utf8))
        #expect(response.orderedGroups.map(\.name) == ["B", "A"])
        #expect(response.proxies["Node1"]?.latestDelay == 123)
        #expect(response.proxies["Node1"]?.type == .hysteria2)
        #expect(response.proxies["Weird"]?.type == .other)
        #expect(response.proxies["Weird"]?.typeName == "FutureProto")
        #expect(response.proxies["B"]?.hidden == true)
    }

    @Test func decodesConfig() throws {
        let json = """
        {"port":0,"socks-port":0,"mixed-port":7890,"allow-lan":false,"mode":"rule","log-level":"info",
         "tun":{"enable":false,"stack":"mixed","auto-route":true,"dns-hijack":["any:53"]},"sniffing":true}
        """
        let config = try decoder.decode(ClashConfig.self, from: Data(json.utf8))
        #expect(config.effectiveHTTPPort == 7890)
        #expect(config.tun?.autoRoute == true)
        #expect(config.sniffing == true)
    }

    @Test func decodesConnectionsWithGoDates() throws {
        let json = """
        {"downloadTotal":10,"uploadTotal":5,"connections":[
          {"id":"x","metadata":{"network":"tcp","type":"HTTP","sourceIP":"127.0.0.1","destinationIP":"","sourcePort":"5000","destinationPort":"443","host":"example.com","process":"curl"},
           "upload":1,"download":2,"start":"2024-05-01T12:00:00Z","chains":["Node1","A"],"rule":"Match","rulePayload":""}
        ],"memory":1234}
        """
        let snap = try decoder.decode(ConnectionsSnapshot.self, from: Data(json.utf8))
        #expect(snap.connections?.first?.metadata.displayHost == "example.com")
        #expect(snap.connections?.first?.chains.last == "A")
    }

    @Test func patchOmitsNilFields() throws {
        let data = try JSONEncoder().encode(ConfigPatch(mode: "global", tun: .init(enable: true)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mode"] as? String == "global")
        #expect(object["allow-lan"] == nil)
        #expect((object["tun"] as? [String: Any])?["enable"] as? Bool == true)
    }

    @Test func decodesTrafficAndLogs() throws {
        #expect(try decoder.decode(Traffic.self, from: Data("{\"up\":1,\"down\":2}".utf8)) == Traffic(up: 1, down: 2))
        let log = try decoder.decode(LogEntry.self, from: Data("{\"type\":\"info\",\"payload\":\"hi\"}".utf8))
        #expect(log.payload == "hi")
    }
}
