import Foundation
import Observation

enum StatsWindow: String, CaseIterable, Identifiable {
    case quarter = "15M", hour = "1H", day = "24H"
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .quarter: return 900
        case .hour: return 3600
        case .day: return 86400
        }
    }
}

struct ModelStats: Identifiable {
    let key: String
    let source: Source
    let model: String
    let recent: Double        // median of the last 5 responses
    let median: Double        // median over the window
    let p90: Double
    let count: Int
    let tokens: Int
    let lastSeen: Double
    let points: [Sample]      // for sparkline
    var id: String { key }
    var name: String { displayName(model) }
}

@MainActor @Observable
final class Store {
    private(set) var samples: [Sample] = []
    private(set) var scanning = false

    var window: StatsWindow = StatsWindow(rawValue: UserDefaults.standard.string(forKey: "window") ?? "") ?? .day {
        didSet { UserDefaults.standard.set(window.rawValue, forKey: "window") }
    }
    /// nil = follow the most recently active model.
    var pinned: String? = UserDefaults.standard.string(forKey: "pinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned") }
    }
    var showModelInBar: Bool = UserDefaults.standard.object(forKey: "showModelInBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showModelInBar, forKey: "showModelInBar") }
    }
    /// Providers whose model list is folded away in the panel.
    var collapsed: Set<Source> = Set((UserDefaults.standard.stringArray(forKey: "collapsed") ?? []).compactMap(Source.init)) {
        didSet { if persistCollapsed { UserDefaults.standard.set(collapsed.map(\.rawValue), forKey: "collapsed") } }
    }
    @ObservationIgnored private var persistCollapsed = true

    func toggleCollapsed(_ source: Source) {
        if collapsed.contains(source) { collapsed.remove(source) } else { collapsed.insert(source) }
    }

    @ObservationIgnored nonisolated private let scanner = Scanner()
    @ObservationIgnored nonisolated private let queue = DispatchQueue(label: "tokometer.scan", qos: .utility)
    @ObservationIgnored private var timer: Timer?

    func start() {
        scanning = true
        queue.async { [scanner] in
            scanner.load()
            let initial = scanner.cache.samples
            DispatchQueue.main.async { self.samples = initial }
            self.runScan()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func loadCachedForSnapshot(collapsed: Set<Source>) {
        scanner.load()
        samples = scanner.cache.samples
        persistCollapsed = false
        self.collapsed = collapsed
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { self.runScan() }
    }

    nonisolated private func runScan() {
        let new = scanner.scan()
        if !new.isEmpty { scanner.save() }
        DispatchQueue.main.async {
            let cutoff = Date().timeIntervalSince1970 - self.scanner.lookback
            self.samples.removeAll { $0.end < cutoff }
            if !new.isEmpty { self.samples.append(contentsOf: new) }
            self.scanning = false
        }
    }

    // MARK: Derived

    var stats: [ModelStats] {
        let cutoff = Date().timeIntervalSince1970 - window.seconds
        let grouped = Dictionary(grouping: samples.filter { $0.end >= cutoff }, by: \.key)
        return grouped.compactMap { key, list in
            let sorted = list.sorted { $0.end < $1.end }
            guard let first = sorted.first else { return nil }
            let tps = sorted.map(\.tps).sorted()
            return ModelStats(
                key: key, source: first.source, model: first.model,
                recent: Store.median(sorted.suffix(5).map(\.tps)),
                median: Store.median(tps),
                p90: tps[min(tps.count - 1, Int(Double(tps.count) * 0.9))],
                count: sorted.count,
                tokens: sorted.reduce(0) { $0 + $1.tokens },
                lastSeen: sorted.last!.end,
                points: Array(sorted.suffix(60)))
        }
        .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// The model shown in the menu bar: pinned one, else whichever responded last.
    /// nil once nothing has run for a while, so the bar doesn't show a stale speed.
    var barStats: (name: String, tps: Double)? {
        let key = pinned ?? samples.max { $0.end < $1.end }?.key
        guard let key else { return nil }
        let list = samples.filter { $0.key == key }.sorted { $0.end < $1.end }.suffix(5)
        guard let last = list.last, Date().timeIntervalSince1970 - last.end < 30 * 60 else { return nil }
        return (displayName(last.model), Store.median(list.map(\.tps)))
    }

    nonisolated static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
