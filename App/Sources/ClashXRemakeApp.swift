import AppKit
import SwiftUI

@main
struct ClashXRemakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Dashboard", id: WindowID.dashboard) {
            DashboardView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}

/// AppKit hooks that SwiftUI's `App` protocol does not expose: URL schemes and graceful shutdown.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSAppleEventManager.shared().setEventHandler(self,
                                                     andSelector: #selector(handleGetURL(event:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        Task { await AppModel.shared.bootstrap() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateLater }
        isShuttingDown = true
        Task {
            await AppModel.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func handleGetURL(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Task { await AppModel.shared.handle(url: url) }
    }
}
