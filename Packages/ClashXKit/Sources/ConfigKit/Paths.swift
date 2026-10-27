import Foundation

/// Well-known file system locations. The config directory intentionally matches
/// ClashX Meta (`~/.config/clash.meta`) so existing profiles keep working.
public struct ClashPaths: Sendable, Equatable {
    public var configDirectory: URL
    public var applicationSupport: URL
    public var caches: URL

    public init(configDirectory: URL, applicationSupport: URL, caches: URL) {
        self.configDirectory = configDirectory
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    public static func standard(bundleIdentifier: String,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                configDirectoryOverride: URL? = nil) -> ClashPaths {
        let fm = FileManager.default
        let support = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                       ?? home.appending(path: "Library/Application Support"))
            .appending(path: bundleIdentifier)
        let caches = (fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                      ?? home.appending(path: "Library/Caches"))
            .appending(path: bundleIdentifier)
        return ClashPaths(configDirectory: configDirectoryOverride ?? home.appending(path: ".config/clash.meta"),
                          applicationSupport: support,
                          caches: caches)
    }

    public var coreDirectory: URL { applicationSupport.appending(path: "core") }
    public var composedConfigDirectory: URL { caches.appending(path: "composed") }
    public var logDirectory: URL { caches.appending(path: "logs") }

    public func configFile(named name: String) -> URL {
        configDirectory.appending(path: "\(name).yaml")
    }

    /// Creates every directory the app writes to.
    public func ensureDirectories() throws {
        for url in [configDirectory, coreDirectory, composedConfigDirectory, logDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Names (without extension) of every `*.yaml` profile in the config directory, sorted.
    public func profileNames() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: configDirectory,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { $0.pathExtension.lowercased() == "yaml" || $0.pathExtension.lowercased() == "yml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
