import SwiftUI
import WebKit

/// Loads one of the hosted official dashboards, pre-pointed at the local controller.
struct WebDashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Group {
            if let runtime = model.runtime, let url = preferences.webDashboard.url(port: runtime.controllerPort, secret: runtime.secret) {
                WebView(url: url).id(url)
            } else {
                ContentUnavailableView("Core is not running", systemImage: "network.slash")
            }
        }
        .toolbar {
            Picker("Dashboard", selection: $preferences.webDashboard) {
                ForEach(WebDashboard.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
