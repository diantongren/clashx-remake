import Foundation
import HelperProtocol
import Security
import os

/// Decides whether an XPC peer may talk to us. We run as root, so this is the security boundary.
///
/// Release builds carry `ClientCodeRequirement` (injected from `CLASHX_CLIENT_CODE_REQUIREMENT`)
/// and reject anything that does not satisfy it. When the requirement is empty the helper fails
/// closed, unless the build explicitly set `AllowUnverifiedClients` (Debug only); even then the
/// peer must be the main executable of the very bundle this helper was launched from.
struct ClientValidator: Sendable {
    struct Verdict: Sendable {
        var accepted: Bool
        var verified: Bool
        var reason: String
    }

    private let logger = Logger(subsystem: "app.clashx.remake.helper", category: "auth")

    private var requirementString: String {
        (Bundle.main.infoDictionary?["ClientCodeRequirement"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var allowsUnverifiedClients: Bool {
        switch Bundle.main.infoDictionary?["AllowUnverifiedClients"] {
        case let flag as Bool: flag
        case let text as String: ["YES", "TRUE", "1"].contains(text.uppercased())
        default: false
        }
    }

    func validate(_ connection: NSXPCConnection) -> Verdict {
        guard let code = peerCode(for: connection) else {
            return Verdict(accepted: false, verified: false, reason: "cannot obtain peer code object")
        }

        let requirementString = requirementString
        if !requirementString.isEmpty {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
                  let requirement else {
                return Verdict(accepted: false, verified: false, reason: "invalid ClientCodeRequirement")
            }
            let status = SecCodeCheckValidity(code, [], requirement)
            guard status == errSecSuccess else {
                return Verdict(accepted: false, verified: false, reason: "code requirement failed (\(status))")
            }
            // Also let XPC enforce it on every message, not just at accept time.
            connection.setCodeSigningRequirement(requirementString)
            return Verdict(accepted: true, verified: true, reason: "code requirement satisfied")
        }

        guard allowsUnverifiedClients else {
            return Verdict(accepted: false, verified: false,
                           reason: "no ClientCodeRequirement configured and unverified clients are not allowed")
        }

        // Development path: identifier must match *and* the peer must be the app that embeds this helper.
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else {
            return Verdict(accepted: false, verified: false, reason: "no signing information")
        }
        guard identifier == HelperConstants.appBundleIdentifier else {
            return Verdict(accepted: false, verified: false, reason: "unexpected identifier \(identifier)")
        }
        guard let peerPath = executablePath(of: connection.processIdentifier),
              peerPath == Self.embeddingAppExecutable else {
            return Verdict(accepted: false, verified: false,
                           reason: "peer is not the embedding app (\(executablePath(of: connection.processIdentifier) ?? "?"))")
        }
        return Verdict(accepted: true, verified: false, reason: "DEBUG: identifier + bundle path match only")
    }

    /// `<App>.app/Contents/MacOS/<App>` for the bundle that contains this helper binary.
    private static let embeddingAppExecutable: String? = {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundle = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app",
              let executable = Bundle(url: bundle)?.executableURL?.standardizedFileURL else { return nil }
        return executable.path
    }()

    private func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    private func peerCode(for connection: NSXPCConnection) -> SecCode? {
        var token = connection.auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }
}

private extension NSXPCConnection {
    /// `auditToken` is not exposed publicly but has been stable for a decade and is what Apple's
    /// own sample code uses via KVC. Zeroed when unavailable so validation fails closed.
    var auditToken: audit_token_t {
        var token = audit_token_t()
        if let value = value(forKey: "auditToken") as? NSValue {
            value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        }
        return token
    }
}
