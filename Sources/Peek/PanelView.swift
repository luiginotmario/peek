import AppKit
import PeekCore
import SwiftUI

// motion tokens: a steep start and a long tail (easeOutQuint) for everything the system does
private let glide = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.35)
private let gatherSpring = Animation.spring(duration: 0.55, bounce: 0)

struct PanelView: View {
    let search: Search
    let onHeight: (CGFloat) -> Void
    @FocusState private var focused: Bool
    @Namespace private var tiles

    var body: some View {
        @Bindable var search = search
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: MenuBar.glyph())
                    .foregroundStyle(.secondary)
                TextField("describe a photo", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .focused($focused)
                    .onSubmit { search.submit() }
                    .onChange(of: search.query) { _, text in
                        if text.isEmpty { search.clear() }
                    }
                StatusLabel(status: search.status)
            }
            .padding(.horizontal, 18)
            .frame(height: 60)

            if search.phase != .idle {
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                content
                    .padding(14)
                    .transition(.opacity)
            }
        }
        .frame(width: Panel.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .onAppear { focused = true }
    }

    @ViewBuilder private var content: some View {
        switch search.phase {
        case .idle:
            EmptyView()
        case .looking(let count), .scanning(_, let count):
            // the skeleton holds the grid's shape from the first frame, so results land in place
            VStack(alignment: .leading, spacing: 12) {
                Text("looking through \(count.formatted()) photos" + search.filters.map { " · \($0)" }.joined() + "…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ZStack {
                    Skeleton(pulsing: search.phase == .looking(count))
                    if case .scanning(let results, _) = search.phase {
                        ScanGrid(results: results, thumbnails: search.thumbnails, namespace: tiles) {
                            withAnimation(gatherSpring) { search.gather() }
                        }
                    }
                }
            }
        case .found(let matches):
            Found(matches: matches, filters: search.filters, thumbnails: search.thumbnails, namespace: tiles)
        case .nothing:
            Nothing(status: search.status)
        }
    }
}

// MARK: - Scan

/// The candidates land, then a scan line passes from top to bottom; as it crosses each row the
/// misses fade back and the matches get an outline. When it's through, the matches gather.
private struct ScanGrid: View {
    let results: [Result]
    let thumbnails: [String: CGImage]
    let namespace: Namespace.ID
    let onDone: () -> Void

    static let columns = 6
    static let scan = 0.8 // seconds for the line to cross the grid: constant motion, so linear

    @State private var landed = false
    @State private var scanned = false
    @State private var line: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: Int { (results.count + Self.columns - 1) / Self.columns }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: Self.columns), spacing: 6) {
            ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
                let row = position / Self.columns
                let miss = scanned && !result.isMatch
                Tile(image: thumbnails[result.id], result: result, corner: 9, outlined: scanned && result.isMatch)
                    .matchedGeometryEffect(id: result.id, in: namespace)
                    .opacity(landed ? (miss ? 0.2 : 1) : 0)
                    .blur(radius: landed ? 0 : 4)
                    .offset(y: landed || reduceMotion ? 0 : 6)
                    .scaleEffect(miss && !reduceMotion ? 0.96 : 1)
                    .animation(glide.delay(Double(position) * 0.012), value: landed)
                    .animation(glide.delay(reduceMotion ? 0 : Self.scan * (Double(row) + 0.6) / Double(rows)), value: scanned)
            }
        }
        .overlay(alignment: .top) {
            if !reduceMotion {
                GeometryReader { proxy in
                    ScanLine()
                        .offset(y: line * proxy.size.height - ScanLine.height)
                        .opacity(scanned && line < 1 ? 1 : 0)
                }
                .allowsHitTesting(false)
            }
        }
        .task {
            landed = true
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 320))
            scanned = true
            withAnimation(.linear(duration: reduceMotion ? 0 : Self.scan)) { line = 1 }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.3 : Self.scan + 0.4))
            onDone()
        }
    }
}

/// A soft band of light with a hairline leading edge, sweeping down.
private struct ScanLine: View {
    static let height: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.primary.opacity(0), .primary.opacity(0.1)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.primary.opacity(0.55)).frame(height: 1.5)
        }
        .frame(height: Self.height)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
    }
}

/// Placeholder tiles in the grid's exact layout. A soft wave runs across them while the query is
/// being compared, and stops once real thumbnails cover them.
private struct Skeleton: View {
    let pulsing: Bool
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: ScanGrid.columns), spacing: 6) {
            ForEach(0..<Search.candidates, id: \.self) { position in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(0.1))
                    .aspectRatio(1, contentMode: .fit)
                    // scoped to opacity: a repeating animation must never touch layout
                    .animation(
                        pulsing && !reduceMotion
                            ? .easeInOut(duration: 0.8).repeatForever().delay(Double(position % ScanGrid.columns) * 0.07)
                            : .easeOut(duration: 0.2)
                    ) { tile in
                        tile.opacity(lit && pulsing ? 1 : 0.5)
                    }
            }
        }
        .onAppear { lit = true }
    }
}

// MARK: - Found

private struct Found: View {
    let matches: [Result]
    let filters: [String]
    let thumbnails: [String: CGImage]
    let namespace: Namespace.ID

    @State private var selected: Set<String> = []
    @State private var shown = false
    @State private var sharing = false

    private var chosen: [String] {
        let ids = matches.map(\.id)
        return selected.isEmpty ? ids : ids.filter(selected.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text((matches.count == 1 ? "found 1 photo" : "found \(matches.count) photos") + filters.map { " · \($0)" }.joined())
                .font(.system(size: 13, weight: .semibold))
                .opacity(shown ? 1 : 0)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(matches) { result in
                    Button {
                        if selected.contains(result.id) { selected.remove(result.id) } else { selected.insert(result.id) }
                    } label: {
                        Tile(image: thumbnails[result.id], result: result, corner: 11,
                             outlined: selected.contains(result.id), dimmed: !selected.isEmpty && !selected.contains(result.id))
                    }
                    .buttonStyle(Press())
                    .matchedGeometryEffect(id: result.id, in: namespace)
                }
            }

            HStack(spacing: 8) {
                Action(title: "AirDrop", symbol: "dot.radiowaves.up.forward") { share(.airDrop, $0) }
                Action(title: "Messages", symbol: "message") { share(.messages, $0) }
                Action(title: "Share…", symbol: "square.and.arrow.up") { share(.menu, $0) }
                Spacer()
                Text(selected.isEmpty ? "click photos to pick some" : "\(selected.count) picked")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.opacity)
            }
            .disabled(sharing)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
        }
        .onAppear {
            withAnimation(glide.delay(0.25)) { shown = true }
        }
    }

    private func share(_ destination: Sharing.Destination, _ anchor: CGRect) {
        sharing = true
        Task {
            await Sharing.share(chosen, to: destination, anchor: anchor)
            sharing = false
        }
    }
}

private struct Nothing: View {
    let status: Search.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("nothing like that yet")
                .font(.system(size: 13, weight: .semibold))
            if case .indexing(let done, let total) = status {
                Text("peek is still reading your library (\(done.formatted()) of \(total.formatted())). try again in a bit.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pieces

private struct Tile: View {
    let image: CGImage?
    let result: Result
    var corner: CGFloat
    var outlined = false
    var dimmed = false

    var body: some View {
        Color.primary.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if result.kind == .video {
                    // the moment that matched; videos only in icloud have just their poster frame
                    Label(result.time > 0 ? Duration.seconds(result.time).formatted(.time(pattern: .minuteSecond)) : "video",
                          systemImage: "play.fill")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .labelStyle(Compact())
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.primary, lineWidth: outlined ? 2 : 0)
            }
            .opacity(dimmed ? 0.45 : 1)
            .animation(glide, value: outlined)
            .animation(glide, value: dimmed)
    }
}

private struct Compact: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}

/// A share action. Reports where it sits on screen so the share menu opens from it.
private struct Action: View {
    let title: String
    let symbol: String
    let perform: (CGRect) -> Void
    @State private var frame: CGRect = .zero

    var body: some View {
        Button { perform(frame) } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(Press())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

/// Pressables shrink a touch so the panel feels like it heard the click.
private struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.16), value: configuration.isPressed)
    }
}

private struct StatusLabel: View {
    let status: Search.Status

    var body: some View {
        switch status {
        case .indexing(let done, let total) where total > 0 && done < total:
            Text("reading library \(Int((Double(done) / Double(total) * 100).rounded(.down)))%")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("\(done.formatted()) of \(total.formatted()) photos read so far. search already covers those.")
        case .denied:
            Button("allow photos access") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        default:
            Text("⏎")
                .font(.system(size: 13))
                .foregroundStyle(.quaternary)
        }
    }
}
