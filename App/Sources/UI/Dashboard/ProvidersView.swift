import MihomoAPI
import SwiftUI

struct ProvidersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Proxy providers") {
                if model.proxyProviders.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(model.proxyProviders) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).font(.headline)
                            Text("\(provider.vehicleType.rawValue) · \(provider.proxies.count) nodes · updated \(Format.relative(provider.updatedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let info = provider.subscriptionInfo, let total = info.total, total > 0 {
                                let used = (info.upload ?? 0) + (info.download ?? 0)
                                ProgressView(value: Double(used), total: Double(total)) {
                                    Text("\(Format.bytes(used)) / \(Format.bytes(total))\(expiry(info))")
                                        .font(.caption2)
                                }
                            }
                        }
                        Spacer()
                        if provider.vehicleType == .http {
                            Button("Update") { Task { await model.updateProxyProvider(provider.name) } }
                        }
                        Button("Health check") { Task { try? await model.client?.healthCheckProxyProvider(provider.name); await model.refreshProxies() } }
                    }
                }
            }
            Section("Rule providers") {
                if model.ruleProviders.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(model.ruleProviders) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).font(.headline)
                            Text("\(provider.behavior) · \(provider.ruleCount) rules · updated \(Format.relative(provider.updatedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if provider.vehicleType == .http {
                            Button("Update") { Task { await model.updateRuleProvider(provider.name) } }
                        }
                    }
                }
            }
        }
        .toolbar {
            Button("Update All", systemImage: "arrow.triangle.2.circlepath") { Task { await model.updateAllProviders() } }
        }
        .task { await model.refreshProviders() }
    }

    private func expiry(_ info: SubscriptionInfo) -> String {
        guard let expire = info.expire, expire > 0 else { return "" }
        return " · expires \(Date(timeIntervalSince1970: TimeInterval(expire)).formatted(date: .abbreviated, time: .omitted))"
    }
}
