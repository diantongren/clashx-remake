import Foundation

enum Format {
    private static let byteCount: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .binary
        f.isAdaptive = true
        return f
    }()

    static func bytes(_ value: Int64) -> String { byteCount.string(fromByteCount: value) }

    /// Compact bytes-per-second suitable for the menu bar ("1.2M/s").
    static func speed(_ bytesPerSecond: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytesPerSecond)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let text = value >= 100 || unit == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(text)\(units[unit])/s"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: .now)
    }

    static func delay(_ delay: Int?) -> String {
        guard let delay else { return "" }
        return delay == 0 ? "timeout" : "\(delay) ms"
    }
}
