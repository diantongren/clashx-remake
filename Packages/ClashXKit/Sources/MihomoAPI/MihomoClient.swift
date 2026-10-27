import Foundation

public enum MihomoError: Error, LocalizedError, Sendable {
    case invalidURL
    case http(status: Int, message: String?)
    case decoding(String)
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid controller URL."
        case let .http(status, message): "Controller returned HTTP \(status)\(message.map { ": \($0)" } ?? "")"
        case let .decoding(detail): "Could not decode controller response: \(detail)"
        case .unreachable: "The core is not reachable."
        }
    }
}

/// Minimal, dependency-free client for the mihomo external controller.
/// Plain `URLSession`; streaming endpoints use `bytes(for:)` + `lines`.
public struct MihomoClient: Sendable {
    public let baseURL: URL
    public let secret: String
    private let session: URLSession
    private let decoder = MihomoDates.makeDecoder()

    public init(host: String = "127.0.0.1", port: Int, secret: String, session: URLSession? = nil) {
        baseURL = URL(string: "http://\(host):\(port)")!
        self.secret = secret
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 60 * 60 * 24
            config.waitsForConnectivity = false
            config.connectionProxyDictionary = [:] // never go through the proxy we are controlling
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Request plumbing

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (any Encodable & Sendable)? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw MihomoError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw MihomoError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            throw MihomoError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw MihomoError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
            throw MihomoError.http(status: http.statusCode, message: message ?? String(data: data, encoding: .utf8))
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as _: T.Type = T.self) async throws -> T {
        let data = try await send(try request("GET", path, query: query))
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MihomoError.decoding("\(error)")
        }
    }

    @discardableResult
    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (any Encodable & Sendable)? = nil) async throws -> Data {
        try await send(try request(method, path, query: query, body: body))
    }

    // MARK: - Basic

    public func version() async throws -> CoreVersion { try await get("/version") }
    public func config() async throws -> ClashConfig { try await get("/configs") }

    public func patchConfig(_ patch: ConfigPatch) async throws {
        try await call("PATCH", "/configs", body: patch)
    }

    /// Reloads the core with the configuration file at `path` (`PUT /configs?force=true`).
    public func reloadConfig(path: String) async throws {
        try await call("PUT", "/configs", query: [URLQueryItem(name: "force", value: "true")], body: ["path": path])
    }

    public func updateGeoDatabases() async throws { try await call("POST", "/configs/geo") }
    public func flushFakeIPCache() async throws { try await call("POST", "/cache/fakeip/flush") }
    public func flushDNSCache() async throws { try await call("POST", "/cache/dns/flush") }
    public func restartCore() async throws { try await call("POST", "/restart") }

    // MARK: - Proxies

    public func proxies() async throws -> ProxiesResponse { try await get("/proxies") }

    public func selectProxy(group: String, name: String) async throws {
        try await call("PUT", "/proxies/\(group)", body: ["name": name])
    }

    public func unfixProxy(group: String) async throws {
        try await call("DELETE", "/proxies/\(group)")
    }

    public func delay(of proxy: String, testURL: String, timeout: Int = 5000) async throws -> Int {
        let response: DelayResponse = try await get("/proxies/\(proxy)/delay",
                                                    query: [URLQueryItem(name: "url", value: testURL),
                                                            URLQueryItem(name: "timeout", value: String(timeout))])
        return response.delay
    }

    /// Tests every node in a group; returns `[name: delay]` (timeouts are simply absent).
    public func groupDelay(_ group: String, testURL: String, timeout: Int = 5000) async throws -> [String: Int] {
        try await get("/group/\(group)/delay",
                      query: [URLQueryItem(name: "url", value: testURL),
                              URLQueryItem(name: "timeout", value: String(timeout))])
    }

    // MARK: - Providers

    public func proxyProviders() async throws -> ProxyProvidersResponse { try await get("/providers/proxies") }
    public func updateProxyProvider(_ name: String) async throws { try await call("PUT", "/providers/proxies/\(name)") }
    public func healthCheckProxyProvider(_ name: String) async throws { try await call("GET", "/providers/proxies/\(name)/healthcheck") }
    public func ruleProviders() async throws -> RuleProvidersResponse { try await get("/providers/rules") }
    public func updateRuleProvider(_ name: String) async throws { try await call("PUT", "/providers/rules/\(name)") }

    // MARK: - Rules / connections

    public func rules() async throws -> RulesResponse { try await get("/rules") }
    public func connections() async throws -> ConnectionsSnapshot { try await get("/connections") }
    public func closeConnection(id: String) async throws { try await call("DELETE", "/connections/\(id)") }
    public func closeAllConnections() async throws { try await call("DELETE", "/connections") }

    // MARK: - Streams

    public func trafficStream() -> AsyncThrowingStream<Traffic, Error> { stream("/traffic") }
    public func memoryStream() -> AsyncThrowingStream<MemoryUsage, Error> { stream("/memory") }

    public func logStream(level: String) -> AsyncThrowingStream<LogEntry, Error> {
        stream("/logs", query: [URLQueryItem(name: "level", value: level)])
    }

    public func connectionsStream(interval milliseconds: Int = 1000) -> AsyncThrowingStream<ConnectionsSnapshot, Error> {
        stream("/connections", query: [URLQueryItem(name: "interval", value: String(milliseconds))])
    }

    private func stream<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try self.request("GET", path, query: query)
                    request.timeoutInterval = 60 * 60 * 24
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw MihomoError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: nil)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                        continuation.yield(try decoder.decode(T.self, from: data))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) { encodeImpl = { try wrapped.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}
