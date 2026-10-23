import AppKit

/// Hands files to AirDrop, Messages or the system share menu (which lists WhatsApp, Mail and
/// anything else installed). The engine exports the originals; this only shows the sheet.
enum Sharing {
    enum Destination {
        case airDrop, messages, menu
    }

    /// `anchor` is the button's frame in the panel's SwiftUI coordinates (top-left origin).
    static func share(_ files: [URL], to destination: Destination, anchor: CGRect) {
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
