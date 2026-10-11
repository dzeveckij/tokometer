import SwiftUI
import Charts
import ServiceManagement

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--dump") { dump(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { snapshot(to: CommandLine.arguments[i + 1]) }
            return
        }
        TokometerApp.main()
    }

    /// `--snapshot <path>`: renders the panel to a PNG from cached data (used for the README screenshot).
    @MainActor static func snapshot(to path: String) {
        let store = Store()
        store.loadCachedForSnapshot()
        // Render through a real window so AppKit controls and scroll views draw like they do live.
        let host = NSHostingView(rootView: PanelView().environment(store))
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        let size = host.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size  // 2x (Retina) pixels
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `--dump`: fresh scan without cache, printing per-model stats (for debugging the parsers).
    static func dump() {
        let scanner = Scanner()
        let t0 = Date()
        let samples = scanner.scan()
        print(String(format: "scanned in %.1fs, %d samples", Date().timeIntervalSince(t0), samples.count))
        for (key, list) in Dictionary(grouping: samples, by: \.key).sorted(by: { $0.key < $1.key }) {
            let tokens = list.reduce(0) { $0 + $1.tokens }, secs = list.reduce(0) { $0 + $1.duration }
            print(String(format: "%-36@ n=%5d  median %6.1f  aggregate %6.1f t/s", key as NSString, list.count,
                         Store.median(list.map(\.tps)), Double(tokens) / secs))
        }
    }
}

struct TokometerApp: App {
    @State private var store: Store = {
        let s = Store()
        s.start()
        return s
    }()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environment(store)
        } label: {
            BarLabel().environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct BarLabel: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let b = store.barStats {
            Text((store.showModelInBar ? "\(b.name) " : "") + "\(Int(b.tps.rounded())) t/s")
                .monospacedDigit()
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }
}

struct PanelView: View {
    @Environment(Store.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var listHeight: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        let stats = store.stats
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tokens / second").font(.headline)
                Spacer()
                Picker("", selection: $store.window) {
                    ForEach(StatsWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }

            if stats.isEmpty {
                Text(store.scanning ? "Scanning logs…" : "No responses in this window.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            }

            // Grow with content, scroll once it would get taller than ~560pt.
            ScrollView {
                modelList(stats)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, 560))

            Divider()
            HStack {
                Toggle("Model name in bar", isOn: $store.showModelInBar)
                Spacer()
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
            .toggleStyle(.checkbox).font(.caption)
            HStack {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private func modelList(_ stats: [ModelStats]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Source.allCases, id: \.self) { source in
                let rows = stats.filter { $0.source == source }
                if !rows.isEmpty {
                    Text(source.label.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(rows) { ModelRow(stats: $0) }
                }
            }
        }
    }

    private var footer: String {
        var s = store.pinned == nil ? "Bar follows latest model" : "Bar pinned · click row to unpin"
        if store.scanning { s += " · scanning…" }
        return s
    }
}

struct ModelRow: View {
    @Environment(Store.self) private var store
    let stats: ModelStats

    var body: some View {
        let pinned = store.pinned == stats.key
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(stats.name).font(.system(.body, weight: .medium)).lineLimit(1)
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tint) }
                }
                Text("med \(fmt(stats.median)) · p90 \(fmt(stats.p90)) · n=\(stats.count)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Text("\(compact(stats.tokens)) tokens · \(ago(stats.lastSeen))").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Sparkline(points: stats.points).frame(width: 80, height: 28)
            VStack(alignment: .trailing, spacing: 0) {
                Text(fmt(stats.recent)).font(.title3.weight(.semibold)).monospacedDigit()
                Text("t/s").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(pinned ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { store.pinned = pinned ? nil : stats.key }
        .help("Big number: median of last 5 responses. Click to pin to the menu bar.")
    }

    private func fmt(_ v: Double) -> String { v >= 100 ? String(Int(v.rounded())) : String(format: "%.1f", v) }
    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }
    private func ago(_ t: Double) -> String {
        let d = Date().timeIntervalSince1970 - t
        if d < 60 { return "just now" }
        if d < 3600 { return "\(Int(d / 60))m ago" }
        if d < 86400 { return "\(Int(d / 3600))h ago" }
        return "\(Int(d / 86400))d ago"
    }
}

struct Sparkline: View {
    let points: [Sample]

    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { i, s in
            LineMark(x: .value("i", i), y: .value("tps", s.tps))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...(max(points.map(\.tps).max() ?? 1, 1)))
    }
}
