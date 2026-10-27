import AppKit
import ConfigKit
import Foundation
import HelperProtocol
import MihomoAPI
import Observation

/// Single source of truth for the UI. Everything here is MainActor-isolated;
/// long-running work lives in `CoreManager`, `MihomoClient` and the helper.
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Dependencies

    let preferences: Preferences
    let paths: ClashPaths
    let helper: HelperClient
    let core: CoreManager
    let systemProxy: SystemProxyController
    @ObservationIgnored private var proxyObserver: NetworkProxyObserver?
    @ObservationIgnored private var profileDirectoryWatcher: PathWatcher?
    @ObservationIgnored private var profileFileWatcher: PathWatcher?
    @ObservationIgnored private var loadedProfileModification: Date?

    // MARK: Observable state

    private(set) var coreState: CoreState = .stopped
    private(set) var config: ClashConfig?
    private(set) var proxies: ProxiesResponse?
    private(set) var traffic: Traffic = .zero
    private(set) var memory: MemoryUsage?
    private(set) var connections: ConnectionsSnapshot?
    private(set) var rules: [Rule] = []
    private(set) var proxyProviders: [ProxyProvider] = []
    private(set) var ruleProviders: [RuleProvider] = []
    private(set) var logs: [LogEntry] = []
    private(set) var profiles: [String] = []
    private(set) var helperState: HelperInstallState = .unknown
    private(set) var helperVersion: HelperVersion?
    private(set) var systemProxySnapshot = SystemProxyController.Snapshot()
    private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    private(set) var testingGroups: Set<String> = []
    var lastError: String?
    var trafficHistory: [TrafficSample] = []

    struct TrafficSample: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let up: Int64
        let down: Int64
    }

    @ObservationIgnored private var streamTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var logBufferLimit = 1000

    // MARK: Derived

    var runtime: CoreRuntime? { coreState.runtime }
    var client: MihomoClient? { core.client }
    var httpPort: Int { config?.effectiveHTTPPort ?? 0 }
    var socksPort: Int { config?.effectiveSocksPort ?? 0 }

    /// The system currently routes through our ports.
    var systemProxyActive: Bool {
        guard coreState.isRunning, httpPort > 0 else { return false }
        return systemProxySnapshot.pointsAt(httpPort: httpPort, socksPort: socksPort)
    }

    /// Another process set a proxy that is not ours.
    var systemProxySetByOther: Bool {
        systemProxySnapshot.isAnyProxySet && !systemProxyActive
    }

    var tunActive: Bool { config?.tun?.enable ?? false }
    var isPrivileged: Bool { runtime?.launchMode == .privileged }

    var visibleGroups: [Proxy] {
        guard let proxies else { return [] }
        return proxies.orderedGroups.filter { group in
            if group.hidden == true { return false }
            if preferences.hideUnselectableGroups, !group.type.isSelectable { return false }
            if group.name == "GLOBAL", config?.mode != ProxyMode.global.rawValue { return false }
            return true
        }
    }

    // MARK: Init

    private init() {
        preferences = Preferences()
        paths = ClashPaths.standard(bundleIdentifier: Bundle.main.bundleIdentifier ?? HelperConstants.appBundleIdentifier,
                                    configDirectoryOverride: ProcessInfo.processInfo.environment["CLASHX_CONFIG_DIR"].map { URL(fileURLWithPath: $0) })
        helper = HelperClient()
        core = CoreManager(paths: paths, preferences: preferences, helper: helper)
        systemProxy = SystemProxyController(helper: helper)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        proxyObserver = NetworkProxyObserver { [weak self] in self?.refreshSystemProxySnapshot() }
        refreshSystemProxySnapshot()
        try? paths.ensureDirectories()
        profileDirectoryWatcher = PathWatcher(url: paths.configDirectory) { [weak self] in self?.profileDirectoryChanged() }
        refreshProfiles()
        await refreshHelperStatus()
        await startCore()
    }

    func shutdown() async {
        stopStreams()
        if systemProxyActive, helperState == .enabled {
            try? await systemProxy.disable(filterInterfaces: preferences.filterInterfaces)
        }
        if tunActive, isPrivileged {
            _ = try? await helper.request(HelperMessages.RestoreDNS())
        }
        await core.stop()
        coreState = .stopped
    }

    // MARK: - Core

    func startCore() async {
        guard !coreState.isRunning, !coreState.isTransitioning else { return }
        lastError = nil
        coreState = .starting(stage: String(localized: "Starting…"))
        do {
            let runtime = try await core.start(profile: preferences.selectedProfile) { [weak self] stage in
                self?.coreState = .starting(stage: stage)
            }
            coreState = .running(runtime)
            loadedProfileModification = profileModificationDate()
            watchActiveProfile()
            if let message = core.profileLoadError { lastError = message }
            await afterConfigLoaded()
            startStreams()
            if preferences.systemProxyEnabled {
                await applySystemProxy(enabled: true, persist: false)
            }
        } catch {
            Log.core.error("start failed: \(error.localizedDescription)")
            coreState = .failed(message: error.localizedDescription)
            lastError = error.localizedDescription
            await core.stop()
        }
    }

    func stopCore() async {
        stopStreams()
        if systemProxyActive, helperState == .enabled {
            try? await systemProxy.disable(filterInterfaces: preferences.filterInterfaces)
        }
        await core.stop()
        coreState = .stopped
        config = nil
        proxies = nil
        traffic = .zero
        connections = nil
        memory = nil
    }

    func restartCore() async {
        await stopCore()
        await startCore()
    }

    func reloadConfig() async {
        guard coreState.isRunning else { await startCore(); return }
        refreshProfiles()
        do {
            try await core.reload(profile: preferences.selectedProfile)
            loadedProfileModification = profileModificationDate()
            watchActiveProfile()
            lastError = nil
            await afterConfigLoaded()
        } catch {
            report(error)
        }
    }

    /// Something in the profile folder (or the active file) changed: refresh the list and hot-reload
    /// if the active profile's contents changed. Atomic saves replace the file, so re-arm the watcher.
    private func profileDirectoryChanged() {
        refreshProfiles()
        watchActiveProfile()
        guard coreState.isRunning, let modified = profileModificationDate(), modified != loadedProfileModification else { return }
        Log.app.notice("active profile changed on disk, reloading")
        Task { await reloadConfig() }
    }

    private func watchActiveProfile() {
        profileFileWatcher = PathWatcher(url: paths.configFile(named: preferences.selectedProfile)) { [weak self] in
            self?.profileDirectoryChanged()
        }
    }

    private func profileModificationDate() -> Date? {
        let url = paths.configFile(named: preferences.selectedProfile)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func selectProfile(_ name: String) async {
        guard name != preferences.selectedProfile || !coreState.isRunning else { return }
        preferences.selectedProfile = name
        if coreState.isRunning {
            await reloadConfig()
            try? await client?.closeAllConnections()
        } else {
            await startCore()
        }
    }

    private func afterConfigLoaded() async {
        await refreshConfig()
        await replayRememberedSelections()
        await refreshProxies()
        await refreshRules()
        await refreshProviders()
    }

    // MARK: - Overrides / modes

    func setMode(_ mode: ProxyMode) async {
        preferences.overrides.mode = mode
        guard let client else { return }
        do {
            try await client.patchConfig(ConfigPatch(mode: mode.rawValue))
            await refreshConfig()
            await refreshProxies()
        } catch { report(error) }
    }

    func setLogLevel(_ level: LogLevel) async {
        preferences.overrides.logLevel = level
        guard let client else { return }
        do {
            try await client.patchConfig(ConfigPatch(logLevel: level.rawValue))
            await refreshConfig()
            restartLogStream()
        } catch { report(error) }
    }

    func setAllowLan(_ allow: Bool) async {
        preferences.overrides.allowLan = allow
        guard let client else { return }
        do {
            try await client.patchConfig(ConfigPatch(allowLan: allow))
            await refreshConfig()
        } catch { report(error) }
    }

    func setSniffing(_ enabled: Bool) async {
        preferences.overrides.snifferEnabled = enabled
        guard let client else { return }
        do {
            try await client.patchConfig(ConfigPatch(sniffing: enabled))
            await refreshConfig()
        } catch { report(error) }
    }

    func setTun(_ enabled: Bool) async {
        guard let client else { return }
        if enabled, !isPrivileged {
            lastError = CoreError.requiresPrivilegedCore(String(localized: "TUN mode")).localizedDescription
            return
        }
        preferences.overrides.tunEnabled = enabled
        do {
            try await client.patchConfig(ConfigPatch(tun: .init(enable: enabled)))
            if isPrivileged {
                if enabled {
                    _ = try await helper.request(HelperMessages.HijackDNS(servers: [preferences.tunDNS]))
                } else {
                    _ = try await helper.request(HelperMessages.RestoreDNS())
                }
            }
            await refreshConfig()
        } catch { report(error) }
    }

    // MARK: - System proxy

    func setSystemProxy(_ enabled: Bool) async {
        await applySystemProxy(enabled: enabled, persist: true)
    }

    private func applySystemProxy(enabled: Bool, persist: Bool) async {
        if persist { preferences.systemProxyEnabled = enabled }
        guard helperState == .enabled else {
            if enabled {
                lastError = CoreError.requiresPrivilegedCore(String(localized: "Setting the system proxy")).localizedDescription
            }
            return
        }
        do {
            if enabled {
                guard coreState.isRunning, httpPort > 0 else { return }
                try await systemProxy.enable(httpPort: httpPort, socksPort: socksPort,
                                             bypass: preferences.bypassList,
                                             filterInterfaces: preferences.filterInterfaces)
            } else {
                try await systemProxy.disable(filterInterfaces: preferences.filterInterfaces)
            }
            refreshSystemProxySnapshot()
        } catch { report(error) }
    }

    func refreshSystemProxySnapshot() {
        systemProxySnapshot = SystemProxyController.currentSnapshot()
    }

    // MARK: - Proxies

    func selectProxy(group: String, node: String) async {
        guard let client else { return }
        do {
            try await client.selectProxy(group: group, name: node)
            preferences.rememberSelection(profile: preferences.selectedProfile, group: group, node: node)
            await refreshProxies()
            // Drop connections that were routed through the old node.
            if let active = connections?.connections {
                for connection in active where connection.chains.contains(group) {
                    try? await client.closeConnection(id: connection.id)
                }
            }
        } catch { report(error) }
    }

    func testGroupDelay(_ group: String) async {
        guard let client, !testingGroups.contains(group) else { return }
        testingGroups.insert(group)
        defer { testingGroups.remove(group) }
        do {
            _ = try await client.groupDelay(group, testURL: preferences.benchmarkURL)
        } catch { report(error) }
        await refreshProxies()
    }

    func testProxyDelay(_ name: String) async {
        guard let client else { return }
        _ = try? await client.delay(of: name, testURL: preferences.benchmarkURL)
        await refreshProxies()
    }

    private func replayRememberedSelections() async {
        guard let client else { return }
        let remembered = preferences.rememberedSelections(profile: preferences.selectedProfile)
        guard !remembered.isEmpty, let proxies = try? await client.proxies() else { return }
        for (group, node) in remembered {
            guard let proxy = proxies.proxies[group], proxy.type.isSelectable,
                  proxy.all?.contains(node) == true, proxy.now != node else { continue }
            try? await client.selectProxy(group: group, name: node)
        }
    }

    // MARK: - Providers / maintenance

    func updateProxyProvider(_ name: String) async {
        guard let client else { return }
        do { try await client.updateProxyProvider(name) } catch { report(error) }
        await refreshProviders()
        await refreshProxies()
    }

    func updateRuleProvider(_ name: String) async {
        guard let client else { return }
        do { try await client.updateRuleProvider(name) } catch { report(error) }
        await refreshProviders()
    }

    func updateAllProviders() async {
        guard let client else { return }
        for provider in proxyProviders where provider.vehicleType == .http {
            try? await client.updateProxyProvider(provider.name)
        }
        for provider in ruleProviders where provider.vehicleType == .http {
            try? await client.updateRuleProvider(provider.name)
        }
        await refreshProviders()
        await refreshProxies()
    }

    func updateGeoDatabases() async {
        guard let client else { return }
        do { try await client.updateGeoDatabases() } catch { report(error) }
    }

    func flushFakeIPCache() async {
        guard let client else { return }
        do { try await client.flushFakeIPCache() } catch { report(error) }
    }

    func flushDNSCache() async {
        guard let client else { return }
        try? await client.flushDNSCache()
        if helperState == .enabled {
            _ = try? await helper.request(HelperMessages.FlushDNSCache())
        }
    }

    func closeConnection(_ id: String) async {
        try? await client?.closeConnection(id: id)
    }

    func closeAllConnections() async {
        try? await client?.closeAllConnections()
    }

    // MARK: - Refreshers

    func refreshConfig() async {
        guard let client else { return }
        do { config = try await client.config() } catch { Log.api.error("config: \(error.localizedDescription)") }
    }

    func refreshProxies() async {
        guard let client else { return }
        do { proxies = try await client.proxies() } catch { Log.api.error("proxies: \(error.localizedDescription)") }
    }

    func refreshRules() async {
        guard let client else { return }
        rules = (try? await client.rules().rules) ?? []
    }

    func refreshProviders() async {
        guard let client else { return }
        proxyProviders = ((try? await client.proxyProviders().providers.values) ?? [:].values)
            .filter { $0.vehicleType != .compatible }
            .sorted { $0.name < $1.name }
        ruleProviders = ((try? await client.ruleProviders().providers.values) ?? [:].values)
            .sorted { $0.name < $1.name }
    }

    func refreshProfiles() {
        profiles = paths.profileNames()
        if profiles.isEmpty { profiles = ["config"] }
    }

    func refreshHelperStatus() async {
        helperState = helper.installState
        helperVersion = helperState == .enabled ? try? await helper.version() : nil
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - Helper install

    func installHelper() async {
        do {
            try helper.register()
        } catch {
            report(error)
        }
        await refreshHelperStatus()
        if helperState == .requiresApproval {
            helper.openLoginItemsSettings()
        }
    }

    func uninstallHelper() async {
        do {
            try await helper.unregister()
        } catch { report(error) }
        await refreshHelperStatus()
    }

    // MARK: - Misc actions

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
        } catch { report(error) }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func copyExportCommand(useLANAddress: Bool) {
        let host = useLANAddress ? (primaryIPv4Address() ?? "127.0.0.1") : "127.0.0.1"
        let command = "export https_proxy=http://\(host):\(httpPort) http_proxy=http://\(host):\(httpPort) all_proxy=socks5://\(host):\(socksPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func openConfigFolder() {
        try? FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.configDirectory)
    }

    func openCoreLog() {
        NSWorkspace.shared.open(core.logFile)
    }

    func report(_ error: Error) {
        Log.app.error("\(error.localizedDescription)")
        lastError = error.localizedDescription
    }

    // MARK: - URL scheme (clash://, clashx://)

    func handle(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        switch components.host {
        case "update-config":
            await reloadConfig()
        case "install-config":
            guard let remote = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let remoteURL = URL(string: remote) else { return }
            let name = components.queryItems?.first(where: { $0.name == "name" })?.value
            await importProfile(from: remoteURL, name: name)
        default:
            break
        }
    }

    /// Downloads a remote profile into the config directory and switches to it.
    /// Reached from `clash://install-config?url=` (any web page can trigger that), so the user
    /// confirms source and target first and an existing profile is never replaced silently.
    func importProfile(from remoteURL: URL, name: String?) async {
        guard let scheme = remoteURL.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = remoteURL.host(), !host.isEmpty else {
            lastError = String(localized: "Only http(s) profile URLs can be imported.")
            return
        }
        let profileName = Self.sanitizedProfileName(name) ?? host
        let destination = paths.configFile(named: profileName)
        let exists = FileManager.default.fileExists(atPath: destination.path)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Import remote profile?")
        alert.informativeText = exists
            ? String(localized: "“\(profileName)” already exists and will be replaced, then become the active profile.\n\nSource: \(remoteURL.absoluteString)")
            : String(localized: "It will be saved as “\(profileName)” and become the active profile.\n\nSource: \(remoteURL.absoluteString)")
        alert.addButton(withTitle: exists ? String(localized: "Replace and Import") : String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            var request = URLRequest(url: remoteURL)
            request.setValue("clash-verge/1.6 ClashXRemake", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw MihomoError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: nil)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw MihomoError.decoding("not UTF-8") }
            _ = try ConfigComposer.compose(profileYAML: text, overrides: preferences.overrides) // validates YAML
            try paths.ensureDirectories()
            try data.write(to: destination, options: .atomic)
            refreshProfiles()
            await selectProfile(profileName)
        } catch { report(error) }
    }

    /// A profile name is a single path component; anything else is rejected.
    static func sanitizedProfileName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
        guard !cleaned.isEmpty, !cleaned.hasPrefix("."), cleaned != "config" || raw == "config" else { return nil }
        return cleaned
    }

    // MARK: - Streams

    private func startStreams() {
        stopStreams()
        guard let client else { return }
        streamTasks.append(Task { [weak self] in
            do {
                for try await sample in client.trafficStream() {
                    guard let self else { return }
                    self.traffic = sample
                    self.trafficHistory.append(TrafficSample(time: .now, up: sample.up, down: sample.down))
                    if self.trafficHistory.count > 120 { self.trafficHistory.removeFirst(self.trafficHistory.count - 120) }
                }
            } catch { Log.api.debug("traffic stream ended: \(error.localizedDescription)") }
            await self?.handleStreamEnded()
        })
        streamTasks.append(Task { [weak self] in
            do {
                for try await usage in client.memoryStream() {
                    self?.memory = usage
                }
            } catch { Log.api.debug("memory stream ended: \(error.localizedDescription)") }
        })
        streamTasks.append(Task { [weak self] in
            do {
                for try await snapshot in client.connectionsStream(interval: 1000) {
                    self?.connections = snapshot
                }
            } catch { Log.api.debug("connections stream ended: \(error.localizedDescription)") }
        })
        startLogStream()
    }

    private func startLogStream() {
        guard let client else { return }
        let level = preferences.overrides.logLevel.rawValue
        streamTasks.append(Task { [weak self] in
            do {
                for try await entry in client.logStream(level: level) {
                    guard let self else { return }
                    self.logs.append(entry)
                    if self.logs.count > self.logBufferLimit { self.logs.removeFirst(self.logs.count - self.logBufferLimit) }
                }
            } catch { Log.api.debug("log stream ended: \(error.localizedDescription)") }
        })
    }

    private func restartLogStream() {
        // Simplest correct approach: restart everything; streams are cheap.
        startStreams()
    }

    private func stopStreams() {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
    }

    /// The traffic stream only ends when the core goes away.
    private func handleStreamEnded() async {
        guard coreState.isRunning, let client else { return }
        try? await Task.sleep(for: .seconds(1))
        if (try? await client.version()) == nil {
            Log.core.error("core vanished")
            stopStreams()
            await core.stop()
            coreState = .failed(message: String(localized: "The core stopped unexpectedly."))
        }
    }

    // MARK: - Network helpers

    private func primaryIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidate: String?
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = item.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if candidate == nil || name == "en0" { candidate = value }
            }
        }
        return candidate
    }
}
