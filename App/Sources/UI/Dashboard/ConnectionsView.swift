import MihomoAPI
import SwiftUI

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\Connection.start, order: .reverse)]

    private var rows: [Connection] {
        let all = model.connections?.connections ?? []
        let filtered = search.isEmpty ? all : all.filter {
            $0.metadata.displayHost.localizedCaseInsensitiveContains(search)
                || ($0.metadata.process ?? "").localizedCaseInsensitiveContains(search)
                || $0.chains.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Host") { Text("\($0.metadata.displayHost):\($0.metadata.destinationPort)") }
            TableColumn("Network") { Text("\($0.metadata.network.uppercased()) · \($0.metadata.type)") }.width(110)
            TableColumn("Process") { Text($0.metadata.process ?? "—") }.width(min: 80, ideal: 120)
            TableColumn("Rule") { Text($0.rulePayload.isEmpty ? $0.rule : "\($0.rule) · \($0.rulePayload)") }
            TableColumn("Chain") { Text($0.chains.reversed().joined(separator: " → ")) }
            TableColumn("↑", value: \.upload) { Text(Format.bytes($0.upload)) }.width(80)
            TableColumn("↓", value: \.download) { Text(Format.bytes($0.download)) }.width(80)
            TableColumn("Started", value: \.start) { Text($0.start, style: .relative) }.width(90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Close \(ids.count) connection(s)") {
                Task { for id in ids { await model.closeConnection(id) } }
            }
        }
        .searchable(text: $search, prompt: "Filter by host, process or chain")
        .toolbar {
            Button("Close All", systemImage: "xmark.circle") { Task { await model.closeAllConnections() } }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No connections", systemImage: "arrow.left.arrow.right")
            }
        }
    }
}
