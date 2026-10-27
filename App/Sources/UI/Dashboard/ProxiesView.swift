import MihomoAPI
import SwiftUI

struct ProxiesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let proxies = model.proxies {
                    ForEach(model.visibleGroups) { group in
                        ProxyGroupCard(group: group, proxies: proxies.proxies, filter: search)
                    }
                } else {
                    ContentUnavailableView("Core is not running", systemImage: "network.slash")
                }
            }
            .padding()
        }
        .searchable(text: $search, prompt: "Filter nodes")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshProxies() } }
        }
        .task { await model.refreshProxies() }
    }
}

struct ProxyGroupCard: View {
    @Environment(AppModel.self) private var model
    let group: Proxy
    let proxies: [String: Proxy]
    let filter: String

    private var nodes: [String] {
        (group.all ?? []).filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.headline)
                    Text("\(group.typeName) · \(group.now ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.testGroupDelay(group.name) }
                } label: {
                    if model.testingGroups.contains(group.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test", systemImage: "bolt")
                    }
                }
                .disabled(model.testingGroups.contains(group.name))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(nodes, id: \.self) { name in
                    ProxyNodeChip(name: name,
                                  node: proxies[name],
                                  isSelected: group.now == name,
                                  isSelectable: group.type.isSelectable) {
                        Task { await model.selectProxy(group: group.name, node: name) }
                    }
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProxyNodeChip: View {
    let name: String
    let node: Proxy?
    let isSelected: Bool
    let isSelectable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).lineLimit(1).font(.callout)
                HStack {
                    Text(node?.typeName ?? "").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.delay(node?.latestDelay))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(delayColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
    }

    private var delayColor: Color {
        guard let delay = node?.latestDelay else { return .secondary }
        switch delay {
        case 0: return .red
        case ..<200: return .green
        case ..<500: return .orange
        default: return .red
        }
    }
}
