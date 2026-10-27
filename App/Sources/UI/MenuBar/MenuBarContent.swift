import ConfigKit
import MihomoAPI
import SwiftUI

/// The status-bar menu. Plain `Menu`/`Button`/`Toggle` items only — `.menu` style
/// cannot host custom views, so latency is appended to the item title instead.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        statusSection
        Divider()
        switches
        Divider()
        proxyModeMenu
        proxyGroups
        Divider()
        configMenu
        coreMenu
        if !model.proxyProviders.isEmpty || !model.ruleProviders.isEmpty {
            providersMenu
        }
        Divider()
        Button("Dashboard…") {
            openWindow(id: WindowID.dashboard)
            NSApp.activate()
        }
        .keyboardShortcut("d")
        portsSection
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }))
        Button("Quit ClashX Remake") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        switch model.coreState {
        case .stopped:
            Text("Core stopped")
            Button("Start Core") { Task { await model.startCore() } }
        case let .starting(stage):
            Text(stage)
        case let .running(runtime):
            Text("mihomo \(runtime.version) · \(runtime.launchMode.title)")
            if model.systemProxySetByOther {
                Text("⚠︎ System proxy was changed by another app")
            }
        case let .failed(message):
            Text("Core failed: \(message.split(separator: "\n").first.map(String.init) ?? message)")
            Button("Retry") { Task { await model.startCore() } }
            Button("Show Core Log") { model.openCoreLog() }
        }
        if let error = model.lastError, !model.coreState.isTransitioning {
            Text("⚠︎ \(error.split(separator: "\n").first.map(String.init) ?? error)")
        }
    }

    @ViewBuilder private var switches: some View {
        Toggle("Set as System Proxy", isOn: Binding(
            get: { model.systemProxyActive },
            set: { enabled in Task { await model.setSystemProxy(enabled) } }))
            .disabled(!model.coreState.isRunning)
        Toggle("TUN Mode", isOn: Binding(
            get: { model.tunActive },
            set: { enabled in Task { await model.setTun(enabled) } }))
            .disabled(!model.coreState.isRunning)
    }

    private var proxyModeMenu: some View {
        Menu("Proxy Mode: \(ProxyMode(rawValue: model.config?.mode ?? "")?.displayName ?? "—")") {
            Picker("Proxy Mode", selection: Binding(
                get: { ProxyMode(rawValue: model.config?.mode ?? "") ?? model.preferences.overrides.mode },
                set: { mode in Task { await model.setMode(mode) } })) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
        }
        .disabled(!model.coreState.isRunning)
    }

    @ViewBuilder private var proxyGroups: some View {
        if model.coreState.isRunning, let proxies = model.proxies {
            ForEach(model.visibleGroups) { group in
                ProxyGroupMenu(group: group, proxies: proxies.proxies)
            }
        }
    }

    private var configMenu: some View {
        Menu("Config") {
            ForEach(model.profiles, id: \.self) { profile in
                Toggle(profile, isOn: Binding(
                    get: { model.preferences.selectedProfile == profile },
                    set: { _ in Task { await model.selectProfile(profile) } }))
            }
            Divider()
            Button("Reload Config") { Task { await model.reloadConfig() } }
                .keyboardShortcut("r")
            Button("Open Config Folder") { model.openConfigFolder() }
            Divider()
            Toggle("Allow Connections from LAN", isOn: Binding(
                get: { model.config?.allowLan ?? false },
                set: { allow in Task { await model.setAllowLan(allow) } }))
                .disabled(!model.coreState.isRunning)
            Toggle("Sniffing", isOn: Binding(
                get: { model.config?.sniffing ?? false },
                set: { enabled in Task { await model.setSniffing(enabled) } }))
                .disabled(!model.coreState.isRunning)
            Menu("Log Level") {
                Picker("Log Level", selection: Binding(
                    get: { model.preferences.overrides.logLevel },
                    set: { level in Task { await model.setLogLevel(level) } })) {
                    ForEach(LogLevel.allCases) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        .onAppear { model.refreshProfiles() }
    }

    private var coreMenu: some View {
        Menu("Core") {
            if model.coreState.isRunning {
                Button("Restart Core") { Task { await model.restartCore() } }
                Button("Stop Core") { Task { await model.stopCore() } }
            } else {
                Button("Start Core") { Task { await model.startCore() } }
                    .disabled(model.coreState.isTransitioning)
            }
            Divider()
            Button("Update GEO Databases") { Task { await model.updateGeoDatabases() } }
            Button("Flush Fake-IP Cache") { Task { await model.flushFakeIPCache() } }
            Button("Flush DNS Cache") { Task { await model.flushDNSCache() } }
            Divider()
            Button("Show Core Log") { model.openCoreLog() }
        }
    }

    private var providersMenu: some View {
        Menu("Providers") {
            Button("Update All Providers") { Task { await model.updateAllProviders() } }
            if !model.proxyProviders.isEmpty {
                Divider()
                Text("Proxy Providers")
                ForEach(model.proxyProviders) { provider in
                    Button("\(provider.name) · \(Format.relative(provider.updatedAt))") {
                        Task { await model.updateProxyProvider(provider.name) }
                    }
                }
            }
            if !model.ruleProviders.isEmpty {
                Divider()
                Text("Rule Providers")
                ForEach(model.ruleProviders) { provider in
                    Button("\(provider.name) · \(Format.relative(provider.updatedAt))") {
                        Task { await model.updateRuleProvider(provider.name) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var portsSection: some View {
        if let config = model.config, let runtime = model.runtime {
            Text("HTTP \(config.effectiveHTTPPort) · SOCKS \(config.effectiveSocksPort) · API \(runtime.controllerPort)")
            Button("Copy Shell Export Command") { model.copyExportCommand(useLANAddress: false) }
                .keyboardShortcut("c")
            Button("Copy Shell Export Command (LAN IP)") { model.copyExportCommand(useLANAddress: true) }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }
    }
}

/// One proxy group as a submenu. Selector groups are interactive, the rest are read-only.
struct ProxyGroupMenu: View {
    @Environment(AppModel.self) private var model
    let group: Proxy
    let proxies: [String: Proxy]

    var body: some View {
        Menu {
            ForEach(group.all ?? [], id: \.self) { name in
                let node = proxies[name]
                Toggle(isOn: Binding(
                    get: { group.now == name },
                    set: { _ in Task { await model.selectProxy(group: group.name, node: name) } })) {
                    Text(title(for: name, node: node))
                }
                .disabled(!group.type.isSelectable)
            }
            Divider()
            Button(model.testingGroups.contains(group.name) ? "Testing…" : "Test Latency") {
                Task { await model.testGroupDelay(group.name) }
            }
            .disabled(model.testingGroups.contains(group.name))
        } label: {
            Text("\(group.name)   ‹\(group.now ?? group.typeName)›")
        }
    }

    private func title(for name: String, node: Proxy?) -> String {
        guard let node else { return name }
        var parts = [name]
        if let delay = node.latestDelay {
            parts.append(delay == 0 ? "(timeout)" : "(\(delay) ms)")
        }
        if node.type.isGroup, let now = node.now {
            parts.append("→ \(now)")
        }
        return parts.joined(separator: " ")
    }
}
