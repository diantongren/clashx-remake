import ConfigKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            ProxySettingsView()
                .tabItem { Label("System Proxy", systemImage: "network") }
            CoreSettingsView()
                .tabItem { Label("Core & Helper", systemImage: "cpu") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
            Toggle("Show network speed in the menu bar", isOn: $preferences.showSpeedInMenuBar)
            Toggle("Hide groups that cannot be selected (url-test, fallback…)", isOn: $preferences.hideUnselectableGroups)
            TextField("Latency test URL", text: $preferences.benchmarkURL)
                .textFieldStyle(.roundedBorder)
            Picker("Web dashboard", selection: $preferences.webDashboard) {
                ForEach(WebDashboard.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Config folder") {
                HStack {
                    Text(model.paths.configDirectory.path)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Button("Open") { model.openConfigFolder() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProxySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var bypassText = ""

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Toggle("Only configure Wi-Fi and Ethernet services", isOn: $preferences.filterInterfaces)
            TextField("DNS server used while TUN is on", text: $preferences.tunDNS)
                .textFieldStyle(.roundedBorder)
            Section("Bypass proxy for these hosts & domains") {
                TextEditor(text: $bypassText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                HStack {
                    Button("Reset to defaults") {
                        bypassText = Preferences.defaultBypassList.joined(separator: "\n")
                    }
                    Spacer()
                    Button("Apply") {
                        preferences.bypassList = bypassText
                            .split(whereSeparator: { $0 == "\n" || $0 == "," })
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        if model.systemProxyActive { Task { await model.setSystemProxy(true) } }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { bypassText = preferences.bypassList.joined(separator: "\n") }
    }
}

struct CoreSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section("Core") {
                LabeledContent("Bundled core", value: model.core.manifest.map { "\($0.name) \($0.version)" } ?? "—")
                LabeledContent("State", value: stateDescription)
                if let runtime = model.runtime {
                    LabeledContent("Launch mode", value: runtime.launchMode.title)
                    LabeledContent("Controller", value: "127.0.0.1:\(runtime.controllerPort)")
                    if let pid = runtime.pid { LabeledContent("PID", value: String(pid)) }
                }
                Toggle("Always run the core in user space (no TUN, no system proxy)", isOn: $preferences.preferUserSpaceCore)
                HStack {
                    Button("Restart Core") { Task { await model.restartCore() } }
                    Button("Show Core Log") { model.openCoreLog() }
                }
            }
            Section("Privileged helper") {
                LabeledContent("Status", value: model.helperState.title)
                if let version = model.helperVersion {
                    LabeledContent("Helper version", value: "\(version.version) (\(version.build))")
                    LabeledContent("Client verification", value: version.clientVerified ? "code requirement" : "bundle identifier only (development build)")
                }
                Text("The helper is a launchd daemon registered through SMAppService. It runs the core as root so TUN mode and system proxy changes work. macOS asks you to allow it under System Settings → General → Login Items & Extensions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    switch model.helperState {
                    case .enabled:
                        Button("Uninstall Helper", role: .destructive) { Task { await model.uninstallHelper() } }
                    case .requiresApproval:
                        Button("Open Login Items Settings") { model.helper.openLoginItemsSettings() }
                        Button("Re-check") { Task { await model.refreshHelperStatus() } }
                    default:
                        Button("Install Helper") { Task { await model.installHelper() } }
                    }
                    Spacer()
                    Button("Refresh") { Task { await model.refreshHelperStatus() } }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshHelperStatus() }
    }

    private var stateDescription: String {
        switch model.coreState {
        case .stopped: String(localized: "Stopped")
        case let .starting(stage): stage
        case let .running(runtime): "Running (mihomo \(runtime.version))"
        case let .failed(message): "Failed: \(message)"
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
            Text("ClashX Remake")
                .font(.title.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                .foregroundStyle(.secondary)
            Text("A ground-up SwiftUI / Swift 6 rewrite of ClashX Meta on top of the mihomo core. Not affiliated with the MetaCubeX project.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Link("mihomo (MetaCubeX)", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
            Link("Original ClashX.Meta", destination: URL(string: "https://github.com/MetaCubeX/ClashX.Meta")!)
        }
        .padding(32)
    }
}
