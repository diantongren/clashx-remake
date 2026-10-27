import Charts
import MihomoAPI
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                    StatTile(title: "Upload", value: Format.speed(model.traffic.up), detail: model.connections.map { "total \(Format.bytes($0.uploadTotal))" })
                    StatTile(title: "Download", value: Format.speed(model.traffic.down), detail: model.connections.map { "total \(Format.bytes($0.downloadTotal))" })
                    StatTile(title: "Connections", value: String(model.connections?.connections?.count ?? 0), detail: nil)
                    StatTile(title: "Memory", value: model.memory.map { Format.bytes($0.inuse) } ?? "—", detail: nil)
                }
                TrafficChart(samples: model.trafficHistory)
                    .frame(height: 220)
                    .padding()
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                coreCard
            }
            .padding()
        }
    }

    private var coreCard: some View {
        GroupBox("Core") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Version", model.runtime?.version ?? "—")
                row("Launch mode", model.runtime?.launchMode.title ?? "—")
                row("Mode", model.config?.mode.capitalized ?? "—")
                row("Profile", model.preferences.selectedProfile)
                row("HTTP / SOCKS port", model.config.map { "\($0.effectiveHTTPPort) / \($0.effectiveSocksPort)" } ?? "—")
                row("Controller", model.runtime.map { "127.0.0.1:\($0.controllerPort)" } ?? "—")
                row("System proxy", model.systemProxyActive ? "On" : (model.systemProxySetByOther ? "Set by another app" : "Off"))
                row("TUN", model.tunActive ? "On" : "Off")
                row("Uptime", model.runtime.map { Duration.seconds(Date.now.timeIntervalSince($0.startedAt)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)) } ?? "—")
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Two series, fixed colors, one axis, legend always present.
struct TrafficChart: View {
    let samples: [AppModel.TrafficSample]

    private var points: [(series: String, time: Date, value: Int64)] {
        samples.flatMap { [("Download", $0.time, $0.down), ("Upload", $0.time, $0.up)] }
    }

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value("Bytes/s", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.orange])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Int64.self) { Text(Format.speed(v)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .chartLegend(position: .top, alignment: .leading)
    }
}
