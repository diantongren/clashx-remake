import Foundation
import os

// Privileged helper for ClashX Remake. Registered with SMAppService.daemon from the app bundle,
// started on demand by launchd, talks XPC, owns the proxy core process while it runs.

let logger = Logger(subsystem: "app.clashx.remake.helper", category: "main")
logger.notice("helper starting, uid \(getuid())")

let service = HelperService()
service.start()
RunLoop.main.run()
