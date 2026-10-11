import Foundation
import Observation

enum StatsWindow: String, CaseIterable, Identifiable {
    case quarter = "15M", hour = "1H", day = "24H", week = "7D", month = "30D"
    var id: String { rawValue }
    /// Short windows come from individual responses (last 24 h).
    var seconds: Double? {
        switch self {
        case .quarter: return 900
        case .hour: return 3600
        case .day: return 86400
        case .week, .month: return nil
        }
    }
    /// Long windows come from daily history.
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        default: return nil
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
    let points: [Double]      // sparkline: per response, or per day for 7D/30D
    /// Typical speed: median over the last 7 days of history.
    let usual: Double?
    var id: String { key }
    var name: String { displayName(model) }

    /// Recent speed relative to usual, e.g. -0.18 = 18% slower. nil without enough history.
    var change: Double? { usual.map { recent / $0 - 1 } }
}

@MainActor @Observable
final class Store {
    private(set) var samples: [Sample] = []
    private(set) var history = History()
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
            let initial = scanner.cache.samples, history = scanner.history
            DispatchQueue.main.async { self.samples = initial; self.history = history }
            self.runScan()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func loadCachedForSnapshot(collapsed: Set<Source>) {
        scanner.load()
        samples = scanner.cache.samples
        history = scanner.history
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
        let history = scanner.history
        DispatchQueue.main.async {
            let cutoff = Date().timeIntervalSince1970 - self.scanner.lookback
            self.samples.removeAll { $0.end < cutoff }
            if !new.isEmpty { self.samples.append(contentsOf: new); self.history = history }
            self.scanning = false
        }
    }

    // MARK: Derived

    var stats: [ModelStats] {
        let usual = usualSpeeds()
        let byKey = Dictionary(grouping: samples, by: \.key).mapValues { $0.sorted { $0.end < $1.end } }

        if let days = window.days {
            let dayKeys = History.lastDays(days)
            var keys = Set<String>()
            for d in dayKeys { keys.formUnion(history.days[d]?.keys ?? [:].keys) }
            return keys.compactMap { key -> ModelStats? in
                let perDay = dayKeys.compactMap { history.days[$0]?[key] }
                let tps = perDay.flatMap(\.values).map(Double.init).sorted()
                guard !tps.isEmpty, let (source, model) = Store.split(key) else { return nil }
                let recent = byKey[key].map { Store.median($0.suffix(5).map(\.tps)) }
                    ?? Store.median(perDay.last?.values.map(Double.init) ?? [])
                return ModelStats(
                    key: key, source: source, model: model,
                    recent: recent, median: Store.median(tps), p90: Store.p90(tps),
                    count: perDay.reduce(0) { $0 + $1.count },
                    tokens: perDay.reduce(0) { $0 + $1.tokens },
                    lastSeen: byKey[key]?.last?.end ?? lastDayEnd(key, dayKeys),
                    points: perDay.map { Store.median($0.values.map(Double.init)) },
                    usual: usual[key])
            }
            .sorted { $0.lastSeen > $1.lastSeen }
        }

        let cutoff = Date().timeIntervalSince1970 - (window.seconds ?? 86400)
        return byKey.compactMap { key, all in
            let sorted = all.filter { $0.end >= cutoff }
            guard let first = sorted.first else { return nil }
            let tps = sorted.map(\.tps).sorted()
            return ModelStats(
                key: key, source: first.source, model: first.model,
                recent: Store.median(sorted.suffix(5).map(\.tps)),
                median: Store.median(tps), p90: Store.p90(tps),
                count: sorted.count,
                tokens: sorted.reduce(0) { $0 + $1.tokens },
                lastSeen: sorted.last!.end,
                points: sorted.suffix(60).map(\.tps),
                usual: usual[key])
        }
        .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Median speed per model over the last 7 days of history, once there's enough to trust.
    private func usualSpeeds() -> [String: Double] {
        var values: [String: [Double]] = [:]
        for d in History.lastDays(7) {
            for (key, stat) in history.days[d] ?? [:] { values[key, default: []] += stat.values.map(Double.init) }
        }
        return values.filter { $0.value.count >= 20 }.mapValues { Store.median($0) }
    }

    /// For a model only in history: end of the last day it was seen.
    private func lastDayEnd(_ key: String, _ dayKeys: [String]) -> Double {
        guard let i = dayKeys.lastIndex(where: { history.days[$0]?[key] != nil }) else { return 0 }
        return Date().timeIntervalSince1970 - Double(dayKeys.count - 1 - i) * 86400
    }

    private static func split(_ key: String) -> (Source, String)? {
        guard let bar = key.firstIndex(of: "|"), let source = Source(rawValue: String(key[..<bar])) else { return nil }
        return (source, String(key[key.index(after: bar)...]))
    }

    /// The model shown in the menu bar: pinned one, else whichever responded last.
    /// nil once nothing has run for a while, so the bar doesn't show a stale speed.
    var barStats: (name: String, tps: Double, change: Double?)? {
        let key = pinned ?? samples.max { $0.end < $1.end }?.key
        guard let key else { return nil }
        let list = samples.filter { $0.key == key }.sorted { $0.end < $1.end }.suffix(5)
        guard let last = list.last, Date().timeIntervalSince1970 - last.end < 30 * 60 else { return nil }
        let tps = Store.median(list.map(\.tps))
        return (displayName(last.model), tps, usualSpeeds()[key].map { tps / $0 - 1 })
    }

    nonisolated static func p90(_ sorted: [Double]) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    }

    nonisolated static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
