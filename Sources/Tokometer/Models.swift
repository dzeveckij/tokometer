import Foundation

enum Source: String, Codable, CaseIterable {
    case claude, codex, antigravity

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }
}

/// One model response: output tokens produced over the wall-clock time from
/// request start (prompt / tool result) to the last byte of the response.
struct Sample: Codable {
    var source: Source
    /// The model that actually produced the response, when the logs say so.
    var model: String
    var end: Double       // unix seconds
    var duration: Double  // seconds
    var tokens: Int
    /// "fast" for Codex priority / Claude fast mode; nil for the standard tier.
    var tier: String? = nil
    /// The model that was asked for, when a different one answered (Antigravity reroutes).
    var requested: String? = nil

    var tps: Double { Double(tokens) / duration }
    var key: String { ModelKey.make(source, model, tier) }
}

enum ModelKey {
    static func make(_ source: Source, _ model: String, _ tier: String? = nil) -> String {
        "\(source.rawValue)|\(model)" + (tier.map { "|\($0)" } ?? "")
    }

    static func split(_ key: String) -> (source: Source, model: String, tier: String?)? {
        let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let source = Source(rawValue: parts[0]) else { return nil }
        return (source, parts[1], parts.count > 2 ? parts[2] : nil)
    }
}

/// Row title: pretty model name plus the tier, e.g. "gpt-6-astra · Fast".
func displayName(_ model: String, tier: String?) -> String {
    displayName(model) + (tier.map { " · \($0.capitalized)" } ?? "")
}

/// Pretty names: "claude-opus-5-5" -> "Opus 5.5", "claude-sonnet-4-5-20250929" -> "Sonnet 4.5".
func displayName(_ model: String) -> String {
    guard model.hasPrefix("claude-") else { return model }
    var parts = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
    if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
    guard let family = parts.first, Int(family) == nil else { return model }
    let version = parts.dropFirst().filter { Int($0) != nil }
    let rest = parts.dropFirst().filter { Int($0) == nil }
    var name = family.capitalized
    if !version.isEmpty { name += " " + version.joined(separator: ".") }
    if !rest.isEmpty { name += " " + rest.joined(separator: " ") }
    return name
}
