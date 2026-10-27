import MihomoAPI
import SwiftUI

struct RulesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    private var rows: [Rule] {
        search.isEmpty ? model.rules : model.rules.filter {
            $0.payload.localizedCaseInsensitiveContains(search)
                || $0.proxy.localizedCaseInsensitiveContains(search)
                || $0.type.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Table(rows) {
            TableColumn("#") { rule in
                Text(String((model.rules.firstIndex(of: rule) ?? 0) + 1)).foregroundStyle(.secondary)
            }.width(44)
            TableColumn("Type", value: \.type).width(130)
            TableColumn("Payload", value: \.payload)
            TableColumn("Target", value: \.proxy).width(min: 100, ideal: 160)
            TableColumn("Size") { rule in Text(rule.size.map(String.init) ?? "") }.width(60)
        }
        .searchable(text: $search, prompt: "Filter rules")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshRules() } }
        }
        .task { await model.refreshRules() }
    }
}
