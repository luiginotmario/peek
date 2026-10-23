import AppKit
import SwiftUI

/// The icon in the menu bar and the panel it opens. The panel appears instantly, with no open
/// animation: it's summoned many times a day and should feel like it was already there.
final class MenuBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let search = Search()
    private lazy var panel = Panel(search: search)

    override init() {
        super.init()
        item.button?.image = Self.glyph()
        item.button?.setAccessibilityLabel("Peek")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        panel.onDismiss = { [weak self] in self?.close() }
        // development: `open build/Peek.app --env PEEK_OPEN="a query"` opens the panel and searches
        if let query = ProcessInfo.processInfo.environment["PEEK_OPEN"] {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                open()
                guard !query.isEmpty else { return }
                search.query = query
                search.submit()
                // and `PEEK_CLOSE_AFTER=5` closes it again, to measure what's left once it's put away
                if let seconds = ProcessInfo.processInfo.environment["PEEK_CLOSE_AFTER"].flatMap(Double.init) {
                    Task {
                        try? await Task.sleep(for: .seconds(seconds))
                        close()
                    }
                }
                // and `PEEK_SNAPSHOT=/tmp/panel` saves what the panel looks like as it goes
                if let path = ProcessInfo.processInfo.environment["PEEK_SNAPSHOT"] {
                    for (step, delay) in [0.3, 0.9, 1.4, 2.4, 3.5].enumerated() {
                        try? await Task.sleep(for: .seconds(step == 0 ? delay : delay - [0.3, 0.9, 1.4, 2.4, 3.5][step - 1]))
                        panel.snapshot(to: URL(filePath: "\(path)-\(step).png"))
                    }
                }
            }
        }
        // clicking into another app closes the panel; share sheets and airdrop keep peek active
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    @objc private func toggle() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            showMenu()
        } else if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    private func open() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.place(below: anchor)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        search.warmUp()
        Task { await search.prepareLibrary() }
    }

    private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        search.coolDown()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Peek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The mark from the app icon at menu bar size: a 3 × 3 mosaic with the found tile lifted out.
    static func glyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let tile: CGFloat = 4.2, gap: CGFloat = 1.5, origin: CGFloat = 1.8
            for row in 0..<3 {
                for column in 0..<3 {
                    let rect = NSRect(x: origin + CGFloat(column) * (tile + gap), y: origin + CGFloat(row) * (tile + gap),
                                      width: tile, height: tile)
                    if row == 1, column == 1 {
                        NSColor.black.setFill()
                        NSBezierPath(roundedRect: rect.offsetBy(dx: -0.6, dy: -1), xRadius: 1.2, yRadius: 1.2).fill()
                    } else {
                        NSColor.black.withAlphaComponent(0.42).setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 1.1, yRadius: 1.1).fill()
                    }
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A borderless, glassy panel that can take keyboard focus and grows downward with its content.
final class Panel: NSPanel {
    static let width: CGFloat = 640
    var onDismiss: () -> Void = {}
    private var top: CGFloat = 0

    init(search: Search) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.state = .active
        glass.blendingMode = .behindWindow
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true

        let host = NSHostingView(rootView: PanelView(search: search) { [weak self] height in self?.fit(height) })
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
        ])
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss() // escape
    }

    /// Development aid: the panel's own pixels as a png. Materials render flat, the layout is exact.
    func snapshot(to url: URL) {
        guard let view = contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Centres the panel under the menu bar icon, kept fully on screen.
    func place(below anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - Self.width / 2, visible.minX + 8), visible.maxX - Self.width - 8)
        top = anchor.minY - 6
        setFrame(NSRect(x: x, y: top - frame.height, width: Self.width, height: frame.height), display: false)
    }

    /// The SwiftUI content changed height: resize from the top edge so the input never moves.
    private func fit(_ height: CGFloat) {
        let height = ceil(height)
        guard abs(frame.height - height) > 0.5 else { return }
        if top == 0 { top = frame.maxY }
        setFrame(NSRect(x: frame.minX, y: top - height, width: Self.width, height: height), display: true)
    }
}
