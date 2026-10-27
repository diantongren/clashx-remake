import ConfigKit
import Foundation
import HelperProtocol
import MihomoAPI

/// Orchestrates one core lifecycle: binary → bootstrap config → launch → controller up → profile pushed.
final class CoreManager {
    let paths: ClashPaths
    private let preferences: Preferences
    private let helper: HelperClient
    private var launcher: (any CoreLauncher)?
    private(set) var client: MihomoClient?
    private(set) var runtime: CoreRuntime?
    private(set) var manifest: CoreManifest?
    private var bootstrap: BootstrapConfig?
    /// Set when the core is up but the profile could not be applied (bad YAML, missing geo data…).
    private(set) var profileLoadError: String?

    var logFile: URL { paths.logDirectory.appending(path: "core.log") }

    init(paths: ClashPaths, preferences: Preferences, helper: HelperClient) {
        self.paths = paths
        self.preferences = preferences
        self.helper = helper
    }

    // MARK: - Lifecycle

    func start(profile: String, progress: (String) -> Void) async throws -> CoreRuntime {
        try paths.ensureDirectories()

        progress(String(localized: "Verifying core…"))
        let prepared = try await CoreBinary.prepare(paths: paths)
        manifest = prepared.manifest

        progress(String(localized: "Preparing configuration…"))
        seedGeoDataIfMissing()
        let profileYAML = try loadProfile(named: profile)
        var bootstrap = BootstrapConfig(logLevel: preferences.overrides.logLevel)
        bootstrap.adopt(profileYAML: profileYAML)
        bootstrap.resolvePortConflicts(using: PortAllocator())
        let bootstrapURL = paths.composedConfigDirectory.appending(path: "bootstrap.yaml")
        try bootstrap.yamlString().write(to: bootstrapURL, atomically: true, encoding: .utf8)
        self.bootstrap = bootstrap

        let launcher = try await chooseLauncher()
        self.launcher = launcher
        progress(launcher.launchMode == .privileged
                 ? String(localized: "Starting core (privileged)…")
                 : String(localized: "Starting core (user space)…"))
        try? FileManager.default.removeItem(at: logFile)
        let request = CoreLaunchRequest(executablePath: prepared.executable.path,
                                        workingDirectory: paths.configDirectory.path,
                                        configFilePath: bootstrapURL.path,
                                        safePaths: [paths.composedConfigDirectory.path, paths.configDirectory.path],
                                        logFilePath: logFile.path)
        let status = try await launcher.launch(request)

        progress(String(localized: "Waiting for controller…"))
        let client = MihomoClient(port: bootstrap.externalControllerPort, secret: bootstrap.secret)
        let version = try await waitUntilReady(client: client, launcher: launcher)
        self.client = client

        let runtime = CoreRuntime(controllerPort: bootstrap.externalControllerPort,
                                  secret: bootstrap.secret,
                                  version: version.version,
                                  launchMode: launcher.launchMode,
                                  pid: status.pid,
                                  startedAt: .now)
        self.runtime = runtime

        // A broken profile must not take the controller down: keep the core running so the user
        // can switch profiles or read the logs, and report the failure separately.
        progress(String(localized: "Loading profile…"))
        do {
            try await push(profileYAML: profileYAML, named: profile, client: client)
        } catch {
            Log.core.error("profile load failed: \(error.localizedDescription)")
            profileLoadError = error.localizedDescription
        }
        return runtime
    }

    func stop() async {
        await launcher?.terminate()
        launcher = nil
        client = nil
        runtime = nil
        bootstrap = nil
    }

    /// Re-composes the active profile with current overrides and hot-reloads the core.
    func reload(profile: String) async throws {
        guard let client else { throw CoreError.notRunning }
        try await push(profileYAML: try loadProfile(named: profile), named: profile, client: client)
    }

    // MARK: - Steps

    private func chooseLauncher() async throws -> any CoreLauncher {
        if !preferences.preferUserSpaceCore, await helper.isReachable() {
            return PrivilegedCoreLauncher(helper: helper)
        }
        return UserSpaceCoreLauncher(pidFile: paths.caches.appending(path: "core.pid"))
    }

    func loadProfile(named name: String) throws -> String {
        let url = paths.configFile(named: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            if name == "config", let sample = Bundle.main.url(forResource: "sampleConfig", withExtension: "yaml") {
                try FileManager.default.copyItem(at: sample, to: url)
            } else {
                throw CoreError.profileMissing(name)
            }
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func push(profileYAML: String, named name: String, client: MihomoClient) async throws {
        var overrides = preferences.overrides
        overrides.ports = bootstrap?.portOverrides
        if launcher?.launchMode == .userSpace {
            overrides.tunEnabled = false // utun needs root; avoid a red line on every reload
        }
        let composed = try ConfigComposer.compose(profileYAML: profileYAML, overrides: overrides)
        let url = paths.composedConfigDirectory.appending(path: "\(name).composed.yaml")
        try composed.write(to: url, atomically: true, encoding: .utf8)
        try await client.reloadConfig(path: url.path)
        profileLoadError = nil
    }

    /// Geo databases the bundle ships (fetched by scripts/fetch-core.sh). Copied into the profile
    /// folder only when absent, so user-updated files are never overwritten.
    static let bundledGeoFiles = ["geosite.dat", "geoip.dat", "country.mmdb"]

    private func seedGeoDataIfMissing() {
        for name in Self.bundledGeoFiles {
            let destination = paths.configDirectory.appending(path: name)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let archive = Bundle.main.url(forResource: name, withExtension: "gz", subdirectory: "Core") else { continue }
            do {
                try Gunzip.decompress(from: archive, to: destination)
                Log.core.notice("seeded \(name) into profile folder")
            } catch {
                Log.core.error("could not seed \(name): \(error.localizedDescription)")
            }
        }
    }

    private func waitUntilReady(client: MihomoClient, launcher: any CoreLauncher) async throws -> CoreVersion {
        let deadline = ContinuousClock.now + .seconds(20)
        var lastError: Error?
        while ContinuousClock.now < deadline {
            let status = await launcher.status()
            if !status.isRunning {
                throw CoreError.exitedEarly(status: status.lastExitCode ?? -1, logTail: CoreBinary.tail(of: logFile))
            }
            do {
                return try await client.version()
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        Log.core.error("controller never answered: \(String(describing: lastError))")
        throw CoreError.startTimeout(logTail: CoreBinary.tail(of: logFile))
    }
}
