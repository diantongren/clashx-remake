import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, proxies, connections, logs, rules, providers, web

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .proxies: "Proxies"
        case .connections: "Connections"
        case .logs: "Logs"
        case .rules: "Rules"
        case .providers: "Providers"
        case .web: "Web Dashboard"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .connections: "arrow.left.arrow.right"
        case .logs: "text.alignleft"
        case .rules: "list.bullet.rectangle"
        case .providers: "shippingbox"
        case .web: "safari"
        }
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var section: DashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch section ?? .overview {
            case .overview: OverviewView()
            case .proxies: ProxiesView()
            case .connections: ConnectionsView()
            case .logs: LogsView()
            case .rules: RulesView()
            case .providers: ProvidersView()
            case .web: WebDashboardView()
            }
        }
        .navigationTitle("ClashX Remake")
        .toolbar {
            ToolbarItem(placement: .status) {
                CoreStatusBadge()
            }
        }
    }
}

struct CoreStatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch model.coreState {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    private var text: String {
        switch model.coreState {
        case let .running(runtime): "mihomo \(runtime.version)"
        case let .starting(stage): stage
        case .stopped: String(localized: "Stopped")
        case .failed: String(localized: "Failed")
        }
    }
}
