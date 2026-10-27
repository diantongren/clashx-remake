import Foundation
import HelperProtocol
import Security
import os

/// Decides whether an XPC peer may talk to us.
///
/// The requirement string comes from the helper's Info.plist (`ClientCodeRequirement`) and is
/// filled in at build time. When it is empty (local, ad-hoc signed builds) we fall back to a
/// bundle-identifier check and report `verified == false` so the app can tell the user.
struct ClientValidator: Sendable {
    struct Verdict: Sendable {
        var accepted: Bool
        var verified: Bool
        var reason: String
    }

    private let logger = Logger(subsystem: "app.clashx.remake.helper", category: "auth")

    func validate(_ connection: NSXPCConnection) -> Verdict {
        let requirementString = (Bundle.main.infoDictionary?["ClientCodeRequirement"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let code = peerCode(for: connection) else {
            return Verdict(accepted: false, verified: false, reason: "cannot obtain peer code object")
        }

        if !requirementString.isEmpty {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
                  let requirement else {
                return Verdict(accepted: false, verified: false, reason: "invalid ClientCodeRequirement")
            }
            let status = SecCodeCheckValidity(code, [], requirement)
            if status == errSecSuccess {
                return Verdict(accepted: true, verified: true, reason: "code requirement satisfied")
            }
            return Verdict(accepted: false, verified: false, reason: "code requirement failed (\(status))")
        }

        // Unsigned / ad-hoc development path.
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
        return Verdict(accepted: true, verified: false, reason: "identifier match only; set ClientCodeRequirement for release builds")
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
