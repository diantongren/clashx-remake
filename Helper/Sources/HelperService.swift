import Foundation
import HelperProtocol
import os

/// XPC front door. Validates clients, decodes envelopes and dispatches to the actors doing the work.
final class HelperService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
    private let logger = Logger(subsystem: "app.clashx.remake.helper", category: "xpc")
    private let supervisor = CoreSupervisor()
    private let dns = DNSConfigurator()
    private let validator = ClientValidator()
    private let connections = OSAllocatedUnfairLock(initialState: 0)

    func start() {
        listener.delegate = self
        listener.resume()
        logger.notice("listening on \(HelperConstants.machServiceName)")
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let verdict = validator.validate(connection)
        guard verdict.accepted else {
            logger.error("rejected connection from pid \(connection.processIdentifier): \(verdict.reason)")
            return false
        }
        logger.notice("accepted connection from pid \(connection.processIdentifier) (\(verdict.reason))")

        let exported = ExportedObject(service: self, clientVerified: verdict.verified)
        connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        connection.exportedObject = exported
        connections.withLock { $0 += 1 }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            let remaining = self.connections.withLock { $0 -= 1; return $0 }
            self.logger.notice("connection closed, \(remaining) remaining")
            if remaining == 0 {
                Task { await self.supervisor.scheduleOrphanCheck() }
            }
        }
        connection.resume()
        return true
    }

    // MARK: Dispatch

    fileprivate func handle(_ data: Data, clientVerified: Bool) async throws -> Data {
        let envelope = try HelperCodec.decodeRequestEnvelope(data)
        guard envelope.protocolVersion == HelperConstants.protocolVersion else {
            throw HelperProtocolError.unexpectedMessage("protocol v\(envelope.protocolVersion)")
        }
        switch envelope.kind {
        case HelperMessages.GetVersion.kind:
            let info = Bundle.main.infoDictionary ?? [:]
            let response = HelperVersion(version: info["CFBundleShortVersionString"] as? String ?? "0",
                                         build: info["CFBundleVersion"] as? String ?? "0",
                                         protocolVersion: HelperConstants.protocolVersion,
                                         clientVerified: clientVerified)
            return try HelperCodec.encodeResponse(response, for: HelperMessages.GetVersion.self)

        case HelperMessages.StartCore.kind:
            let message = try HelperCodec.decodeMessage(HelperMessages.StartCore.self, from: envelope)
            let status = try await supervisor.start(message.request)
            return try HelperCodec.encodeResponse(status, for: HelperMessages.StartCore.self)

        case HelperMessages.StopCore.kind:
            await supervisor.stop()
            return try HelperCodec.encodeResponse(Empty(), for: HelperMessages.StopCore.self)

        case HelperMessages.GetCoreStatus.kind:
            return try HelperCodec.encodeResponse(await supervisor.status(), for: HelperMessages.GetCoreStatus.self)

        case HelperMessages.SetSystemProxy.kind:
            let message = try HelperCodec.decodeMessage(HelperMessages.SetSystemProxy.self, from: envelope)
            try SystemProxyConfigurator.apply(message.configuration)
            return try HelperCodec.encodeResponse(Empty(), for: HelperMessages.SetSystemProxy.self)

        case HelperMessages.ClearSystemProxy.kind:
            let message = try HelperCodec.decodeMessage(HelperMessages.ClearSystemProxy.self, from: envelope)
            try SystemProxyConfigurator.clear(filterInterfaces: message.filterInterfaces)
            return try HelperCodec.encodeResponse(Empty(), for: HelperMessages.ClearSystemProxy.self)

        case HelperMessages.GetSystemProxy.kind:
            return try HelperCodec.encodeResponse(SystemProxyConfigurator.snapshot(), for: HelperMessages.GetSystemProxy.self)

        case HelperMessages.HijackDNS.kind:
            let message = try HelperCodec.decodeMessage(HelperMessages.HijackDNS.self, from: envelope)
            try await dns.hijack(servers: message.servers)
            return try HelperCodec.encodeResponse(Empty(), for: HelperMessages.HijackDNS.self)

        case HelperMessages.RestoreDNS.kind:
            try await dns.restore()
            return try HelperCodec.encodeResponse(Empty(), for: HelperMessages.RestoreDNS.self)

        case HelperMessages.FlushDNSCache.kind:
            await dns.flushCache()
            return try HelperCodec.encodeResponse(Empty(), for: HelperMessages.FlushDNSCache.self)

        default:
            throw HelperProtocolError.unexpectedMessage(envelope.kind)
        }
    }
}

/// One instance per connection so we can remember whether the client passed code-signing checks.
private final class ExportedObject: NSObject, HelperXPCProtocol, @unchecked Sendable {
    private unowned let service: HelperService
    private let clientVerified: Bool

    init(service: HelperService, clientVerified: Bool) {
        self.service = service
        self.clientVerified = clientVerified
    }

    func send(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task {
            do {
                reply(try await service.handle(request, clientVerified: clientVerified), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
}
