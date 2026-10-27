import Foundation

public enum ProxyMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case rule, global, direct

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rule: String(localized: "Rule", bundle: .module)
        case .global: String(localized: "Global", bundle: .module)
        case .direct: String(localized: "Direct", bundle: .module)
        }
    }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case debug, info, warning, error, silent

    public var id: String { rawValue }
}
