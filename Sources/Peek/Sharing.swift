import AppKit
import PeekCore

/// Hands photos to AirDrop, Messages or the system share menu (which lists WhatsApp, Mail and
/// anything else installed). Photos are exported to temporary files first, since that's what every
/// sharing service accepts.
enum Sharing {
    enum Destination {
        case airDrop, messages, menu
    }

    /// `anchor` is the button's frame in the panel's SwiftUI coordinates (top-left origin).
    static func share(_ ids: [String], to destination: Destination, anchor: CGRect) async {
        let assets = Library.assets(withIDs: ids)
        var files: [URL] = []
        for id in ids {
            guard let asset = assets[id], let file = try? await Library.export(asset) else { continue }
            files.append(file)
        }
        guard !files.isEmpty else { return }

        switch destination {
        case .airDrop:
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: files)
        case .messages:
            NSSharingService(named: .composeMessage)?.perform(withItems: files)
        case .menu:
            // the hosting view is flipped, so swiftui's frame can be used as is
            guard let host = NSApp.windows.first(where: { $0 is Panel })?.contentView?.subviews.first else { return }
            NSSharingServicePicker(items: files).show(relativeTo: anchor, of: host, preferredEdge: .minY)
        }
    }
}
