import Foundation

/// The single Objective-C visible XPC entry point. All typed messages travel as
/// Codable envelopes so the ObjC interface never has to change.
@objc(ClashXHelperXPCProtocol)
public protocol HelperXPCProtocol {
    func send(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

public enum HelperProtocolError: Error, LocalizedError, Sendable {
    case unexpectedMessage(String)
    case unexpectedResponse(expected: String, actual: String)
    case remote(String)
    case unavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .unexpectedMessage(kind): "Unexpected helper message: \(kind)"
        case let .unexpectedResponse(expected, actual): "Unexpected helper response: expected \(expected), got \(actual)"
        case let .remote(message): message
        case .unavailable: "The privileged helper is unavailable."
        case .timedOut: "The privileged helper did not answer in time."
        }
    }
}

/// A typed request/response pair.
public protocol HelperMessage: Codable, Sendable {
    associatedtype Response: Codable & Sendable
    static var kind: String { get }
}

public struct Empty: Codable, Sendable, Equatable {
    public init() {}
}

public struct RequestEnvelope: Codable, Sendable {
    public let protocolVersion: Int
    public let kind: String
    public let payload: Data
}

public struct ResponseEnvelope: Codable, Sendable {
    public let kind: String
    public let payload: Data
}

public enum HelperCodec {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }

    public static func encodeRequest<M: HelperMessage>(_ message: M) throws -> Data {
        let payload = try encoder.encode(message)
        return try encoder.encode(RequestEnvelope(protocolVersion: HelperConstants.protocolVersion,
                                                  kind: M.kind,
                                                  payload: payload))
    }

    public static func decodeRequestEnvelope(_ data: Data) throws -> RequestEnvelope {
        try decoder.decode(RequestEnvelope.self, from: data)
    }

    public static func decodeMessage<M: HelperMessage>(_: M.Type, from envelope: RequestEnvelope) throws -> M {
        guard envelope.kind == M.kind else {
            throw HelperProtocolError.unexpectedMessage(envelope.kind)
        }
        return try decoder.decode(M.self, from: envelope.payload)
    }

    public static func encodeResponse<M: HelperMessage>(_ response: M.Response, for _: M.Type) throws -> Data {
        let payload = try encoder.encode(response)
        return try encoder.encode(ResponseEnvelope(kind: M.kind, payload: payload))
    }

    public static func decodeResponse<M: HelperMessage>(_ data: Data, as _: M.Type) throws -> M.Response {
        let envelope = try decoder.decode(ResponseEnvelope.self, from: data)
        guard envelope.kind == M.kind else {
            throw HelperProtocolError.unexpectedResponse(expected: M.kind, actual: envelope.kind)
        }
        return try decoder.decode(M.Response.self, from: envelope.payload)
    }
}
