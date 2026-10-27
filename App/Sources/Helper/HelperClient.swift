import Foundation
import HelperProtocol
import ServiceManagement
import os

enum HelperInstallState: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case notFound
    case unknown

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .notRegistered: String(localized: "Not installed")
        case .requiresApproval: String(localized: "Waiting for approval in System Settings")
        case .enabled: String(localized: "Installed")
        case .notFound: String(localized: "Not found in bundle")
        case .unknown: String(localized: "Unknown")
        }
    }
}

/// Talks to the SMAppService daemon over XPC. Replaces SMJobBless + the hand-rolled install flow.
final class HelperClient {
    private let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    private var connection: NSXPCConnection?
    private let timeout: Duration = .seconds(15)

    var installState: HelperInstallState { HelperInstallState(service.status) }

    // MARK: - Registration

    func register() throws {
        try service.register()
        invalidate()
    }

    func unregister() async throws {
        _ = try? await request(HelperMessages.StopCore())
        try await service.unregister()
        invalidate()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when the daemon is registered *and* answers.
    func isReachable() async -> Bool {
        guard installState == .enabled else { return false }
        return (try? await version()) != nil
    }

    func version() async throws -> HelperVersion {
        try await request(HelperMessages.GetVersion())
    }

    // MARK: - Requests

    func request<M: HelperMessage>(_ message: M) async throws -> M.Response {
        let proxy = try remoteProxy()
        let payload = try HelperCodec.encodeRequest(message)
        let timeout = timeout
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let once = OnceContinuation(continuation)
                proxy.send(payload) { data, errorMessage in
                    if let errorMessage {
                        once.resume(.failure(HelperProtocolError.remote(errorMessage)))
                    } else if let data {
                        once.resume(.success(data))
                    } else {
                        once.resume(.failure(HelperProtocolError.unavailable))
                    }
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    once.resume(.failure(HelperProtocolError.timedOut))
                }
            }
            return try HelperCodec.decodeResponse(data, as: M.self)
        } catch {
            invalidate()
            throw error
        }
    }

    // MARK: - Connection

    private func remoteProxy() throws -> any HelperXPCProtocol {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            connection.resume()
            self.connection = connection
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Log.helper.error("XPC error: \(error.localizedDescription)")
            Task { @MainActor in self?.invalidate() }
        }) as? any HelperXPCProtocol else {
            throw HelperProtocolError.unavailable
        }
        return proxy
    }

    func invalidate() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }
}

/// Guarantees a continuation is resumed exactly once even when the XPC reply and the timeout race.
private nonisolated final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>

    init(_ continuation: CheckedContinuation<T, Error>) {
        state = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ result: Result<T, Error>) {
        let continuation = state.withLockUnchecked { stored -> CheckedContinuation<T, Error>? in
            let value = stored
            stored = nil
            return value
        }
        continuation?.resume(with: result)
    }
}
