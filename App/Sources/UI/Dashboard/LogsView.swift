import MihomoAPI
import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var level = "all"

    private var rows: [LogEntry] {
        model.logs.filter {
            (level == "all" || $0.type == level)
                && (search.isEmpty || $0.payload.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(rows) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.type.uppercased())
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(color(for: entry.type))
                        .frame(width: 56, alignment: .leading)
                    Text(entry.payload)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: rows.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .searchable(text: $search, prompt: "Filter logs")
        .toolbar {
            Picker("Level", selection: $level) {
                Text("All").tag("all")
                ForEach(["debug", "info", "warning", "error"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Button("Clear", systemImage: "trash") { model.clearLogs() }
        }
        .overlay {
            if rows.isEmpty { ContentUnavailableView("No log entries", systemImage: "text.alignleft") }
        }
    }

    private func color(for type: String) -> Color {
        switch type {
        case "error": .red
        case "warning": .orange
        case "info": .blue
        default: .secondary
        }
    }
}
