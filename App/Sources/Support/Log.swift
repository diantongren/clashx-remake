import Foundation
import os

nonisolated enum Log {
    static let app = Logger(subsystem: "app.clashx.remake", category: "app")
    static let core = Logger(subsystem: "app.clashx.remake", category: "core")
    static let helper = Logger(subsystem: "app.clashx.remake", category: "helper")
    static let api = Logger(subsystem: "app.clashx.remake", category: "api")
}
