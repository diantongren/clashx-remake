import ConfigKit
import Foundation

/// Extracts the bundled core into Application Support and verifies it against the manifest.
enum CoreBinary {
    struct Prepared: Sendable {
        var executable: URL
        var manifest: CoreManifest
    }

    nonisolated static func bundledManifestURL() -> URL? {
        Bundle.main.url(forResource: "core-manifest", withExtension: "json", subdirectory: "Core")
    }

    /// Returns the ready-to-run executable, extracting and verifying it when needed.
    @concurrent
    nonisolated static func prepare(paths: ClashPaths) async throws -> Prepared {
        guard let manifestURL = bundledManifestURL(),
              let archiveURL = Bundle.main.url(forResource: "mihomo", withExtension: "gz", subdirectory: "Core") else {
            throw CoreError.bundleMissingCore
        }
        let manifest = try CoreManifest.load(from: manifestURL)
        let executable = paths.coreDirectory.appending(path: "\(manifest.name)-\(manifest.version)")
        let fm = FileManager.default

        if fm.fileExists(atPath: executable.path) {
            let actual = try CoreManifest.sha256(of: executable)
            if actual == manifest.sha256 {
                try markExecutable(executable)
                return Prepared(executable: executable, manifest: manifest)
            }
            Log.core.warning("Cached core checksum mismatch, re-extracting")
            try fm.removeItem(at: executable)
        }

        // Remove stale versions so Application Support does not grow forever.
        for item in (try? fm.contentsOfDirectory(at: paths.coreDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }

        try Gunzip.decompress(from: archiveURL, to: executable)
        let actual = try CoreManifest.sha256(of: executable)
        guard actual == manifest.sha256 else {
            try? fm.removeItem(at: executable)
            throw CoreError.checksumMismatch(expected: manifest.sha256, actual: actual)
        }
        try markExecutable(executable)
        return Prepared(executable: executable, manifest: manifest)
    }

    private nonisolated static func markExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Last `lines` of a log file, for error messages.
    nonisolated static func tail(of url: URL, lines: Int = 12) -> String {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}
