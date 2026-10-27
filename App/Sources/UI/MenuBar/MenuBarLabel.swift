import AppKit
import SwiftUI

/// What sits in the menu bar. `MenuBarExtra` maps its label onto a plain status-bar button
/// (one image + one line of title), so icon and the two-line speed readout are composited
/// into a single template image.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let showSpeed = model.preferences.showSpeedInMenuBar && model.coreState.isRunning
        Image(nsImage: MenuBarIconRenderer.image(symbolName: symbolName,
                                                  speed: showSpeed ? (model.traffic.up, model.traffic.down) : nil))
    }

    private var symbolName: String {
        switch model.coreState {
        case .running:
            if model.tunActive { return "shield.lefthalf.filled" }
            return model.systemProxyActive ? "network.badge.shield.half.filled" : "network"
        case .starting: return "ellipsis.circle"
        case .stopped, .failed: return "network.slash"
        }
    }
}

enum MenuBarIconRenderer {
    private static let height: CGFloat = 20
    private static let iconWidth: CGFloat = 18
    private static let textWidth: CGFloat = 50
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    static func image(symbolName: String, speed: (up: Int64, down: Int64)?) -> NSImage {
        let width = iconWidth + (speed == nil ? 0 : textWidth + 3)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(x: (iconWidth - size.width) / 2, y: (height - size.height) / 2,
                                       width: size.width, height: size.height))
            }
            if let speed {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .right
                paragraph.maximumLineHeight = 10
                paragraph.minimumLineHeight = 10
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: paragraph,
                ]
                let text = "↑ \(Format.speed(speed.up))\n↓ \(Format.speed(speed.down))" as NSString
                text.draw(in: NSRect(x: iconWidth + 3, y: 0, width: textWidth, height: height), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
