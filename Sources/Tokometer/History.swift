import Foundation

/// One model's responses on one local calendar day.
struct DayStat: Codable {
    /// Speeds (t/s) of a uniform random subset of the day's responses, for medians.
    var values: [Float] = []
    var count = 0
    var tokens = 0
    /// Models that were asked for, when a different one answered: name -> responses.
    var requested: [String: Int]?

    static let cap = 500

    mutating func add(_ s: Sample) {
        count += 1
        tokens += s.tokens
        if let r = s.requested { requested = (requested ?? [:]).merging([r: 1], uniquingKeysWith: +) }
        if values.count < DayStat.cap {
            values.append(Float(s.tps))
        } else {
            // Reservoir sampling keeps the subset uniform however busy the day gets.
            let j = Int.random(in: 0..<count)
            if j < DayStat.cap { values[j] = Float(s.tps) }
        }
    }
}

/// Daily per-model summaries, kept for `keepDays`. Live scanning adds new responses; the
/// time before it started is filled in once by a background backfill of the last 30 days.
struct History: Codable {
    static let keepDays = 30
    /// Bump when model keys change meaning (v2: split by tier and served model, v3: backfill,
    /// v4: count requested models, v5: OpenCode, v6: Grok Build).
    static let currentVersion = 6
    var version = currentVersion
    /// Live scanning has counted every response that ended after this.
    var coveredFrom: Double = 0
    /// Whether the time before `coveredFrom` has been filled in from older logs.
    var backfilled = false

    /// "yyyy-MM-dd" -> model key -> stats
    var days: [String: [String: DayStat]] = [:]
    /// When samples were last folded in. A fresh scan re-finds the last day's responses;
    /// anything that ended before this was already counted.
    var updatedAt: Double = 0

    mutating func add(_ s: Sample) {
        days[History.day(s.end), default: [:]][s.key, default: DayStat()].add(s)
    }

    mutating func prune() {
        let oldest = History.day(Date().timeIntervalSince1970 - Double(History.keepDays) * 86400)
        days = days.filter { $0.key >= oldest }
    }

    /// Day keys covering the last `n` calendar days including today, oldest first.
    static func lastDays(_ n: Int) -> [String] {
        let now = Date().timeIntervalSince1970
        return (0..<n).reversed().map { day(now - Double($0) * 86400) }
    }

    static func day(_ t: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
