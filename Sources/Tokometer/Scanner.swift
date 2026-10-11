import Foundation

/// Per-file incremental parse state, persisted so restarts only read what was appended.
struct FileState: Codable {
    var offset: UInt64 = 0
    var size: UInt64 = 0

    // Codex
    var model: String?
    var lastInput: Double?
    var threadId: String?
    var parentThread: String?
    /// Latest service tier this session logged ("priority" = fast mode).
    var tier: String?

    // Claude Code
    var pending: ClaudePending?
    var recentTs: [String: Double] = [:]   // uuid -> timestamp (bounded)
    var lastNonAssistant: Double?

    // Antigravity (SQLite)
    var stamp: Double?
    var agyLastIdx: Int?
    /// Model names logged in this conversation: enum -> name -> count.
    var agyNames: [Int: [String: Int]]?

    // OpenCode (SQLite): newest message time_updated already read, in ms.
    var openCodeUpdated: Int64?
}

struct ClaudePending: Codable {
    var id: String
    var model: String
    var start: Double
    var last: Double
    var tokens: Int
    var tier: String?
}

struct ScanCache: Codable {
    /// Bump when parsing or filtering changes so stale samples get rebuilt.
    static let currentVersion = 6
    var version = currentVersion
    var files: [String: FileState] = [:]
    var samples: [Sample] = []
    var agyModels: [Int: String] = [:]   // Antigravity model enum -> name
    /// Response id -> end time. Resumed/forked sessions copy old messages into new files.
    var seen: [String: Double] = [:]
    /// Codex thread id -> latest service tier, so sub-agent sessions can inherit their parent's.
    var threadTiers: [String: String] = [:]
}

/// Only touched from Store's serial scan queue.
final class Scanner: @unchecked Sendable {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var cache = ScanCache()
    var history = History()
    private var codexDefaultTier: String?
    /// True until the first scan after starting without a usable cache.
    private var freshScan = true
    /// Individual responses kept; log files untouched for longer are skipped entirely.
    let lookback: TimeInterval
    /// OpenCode data directory; defaults to $XDG_DATA_HOME/opencode or ~/.local/share/opencode.
    var openCodeDir: URL?

    init(lookback: TimeInterval = 86400) {
        self.lookback = lookback
    }

    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tokometer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var cacheURL: URL { supportDir.appendingPathComponent("cache.json") }
    /// Separate from the cache so a cache rebuild never loses history.
    private var historyURL: URL { supportDir.appendingPathComponent("history.json") }

    func load() {
        let savedHistory = (try? Data(contentsOf: historyURL))
            .flatMap { try? JSONDecoder().decode(History.self, from: $0) }
            .flatMap { $0.version == History.currentVersion ? $0 : nil }
        if let savedHistory { history = savedHistory }
        guard let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(ScanCache.self, from: data),
              c.version == ScanCache.currentVersion else { return }
        cache = c
        freshScan = false
        // First run with history: start it from the responses already in the cache.
        if savedHistory == nil {
            for s in cache.samples { history.add(s) }
            history.updatedAt = Date().timeIntervalSince1970
            history.coveredFrom = history.updatedAt - lookback
        }
    }

    var needsBackfill: Bool { !history.backfilled && history.coveredFrom > 0 }

    /// One-time import of the `History.keepDays` before live scanning began, so 7D/30D aren't
    /// empty on first launch. Only daily summaries are kept; the logs aren't read again.
    func backfill() {
        guard needsBackfill else { return }
        let older = Scanner(lookback: Double(History.keepDays) * 86400)
        for s in older.scan() where s.end < history.coveredFrom { history.add(s) }
        history.backfilled = true
        saveHistory()
    }

    func save() {
        let cutoff = Date().timeIntervalSince1970 - lookback
        cache.samples.removeAll { $0.end < cutoff }
        cache.seen = cache.seen.filter { $0.value >= cutoff }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        saveHistory()
    }

    private func saveHistory() {
        history.prune()
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    /// Scans all known log roots, returns newly found samples.
    func scan() -> [Sample] {
        var out: [Sample] = []
        let cutoff = Date().addingTimeInterval(-lookback)
        codexDefaultTier = readCodexDefaultTier()
        let roots: [(URL, Source)] = [
            (home.appendingPathComponent(".claude/projects"), .claude),
            (home.appendingPathComponent(".codex/sessions"), .codex),
            (home.appendingPathComponent(".codex/archived_sessions"), .codex),
        ]
        for (root, source) in roots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let size = v.fileSize.map(UInt64.init), let mtime = v.contentModificationDate else { continue }
                // Codex moves sessions into archived_sessions; key by filename so we don't double count.
                let key = source == .codex ? "codex/" + url.lastPathComponent : url.path
                if mtime < cutoff { cache.files[key] = nil; continue }
                var st: FileState
                if let existing = cache.files[key] {
                    st = existing
                    if existing.size == size {
                        flushIdleClaude(&st, &out)
                        cache.files[key] = st
                        continue
                    }
                    if size < st.offset { st = FileState() } // truncated / rewritten
                } else {
                    st = FileState()
                }
                st.size = size
                st.offset = forEachLine(path: url.path, from: st.offset) { line in
                    switch source {
                    case .codex: handleCodex(line, &st, &out)
                    case .claude: handleClaude(line, &st, &out)
                    case .antigravity, .opencode: break
                    }
                }
                flushIdleClaude(&st, &out)
                cache.files[key] = st
            }
        }
        // Sub-agent responses whose parent's tier wasn't known yet when they were read.
        for i in out.indices where out[i].tier?.hasPrefix(Scanner.parentMarker) == true {
            let parent = String(out[i].tier!.dropFirst(Scanner.parentMarker.count))
            out[i].tier = Scanner.normalizeTier(cache.threadTiers[parent] ?? codexDefaultTier)
        }
        scanAntigravity(cutoff: cutoff, &out)
        scanOpenCode(cutoff: cutoff, &out)
        cache.samples.append(contentsOf: out)
        for s in out where !freshScan || s.end > history.updatedAt { history.add(s) }
        history.updatedAt = Date().timeIntervalSince1970
        if history.coveredFrom == 0 { history.coveredFrom = history.updatedAt - lookback }
        freshScan = false
        return out
    }

    // MARK: Codex

    private func handleCodex(_ line: UnsafeRawBufferPointer, _ st: inout FileState, _ out: inout [Sample]) {
        let head = String(decoding: UnsafeRawBufferPointer(rebasing: line.prefix(320)), as: UTF8.self)
        guard let top = value(of: "\"type\":\"", in: head) else { return }
        switch top {
        case "turn_context":
            guard let obj = json(line), let p = obj["payload"] as? [String: Any] else { return }
            if let m = p["model"] as? String { st.model = m }
        case "session_meta":
            guard let obj = json(line), let p = obj["payload"] as? [String: Any] else { return }
            st.threadId = p["id"] as? String
            st.parentThread = p["parent_thread_id"] as? String
        case "token_usage_record":
            guard let ts = timestamp(head), let obj = json(line), let p = obj["payload"] as? [String: Any],
                  let usage = p["usage"] as? [String: Any], let tokens = usage["output_tokens"] as? Int else { return }
            if let start = st.lastInput, let model = st.model {
                add(Sample(source: .codex, model: model, end: ts, duration: ts - start, tokens: tokens,
                           tier: codexTier(st)),
                    id: p["response_id"] as? String, &out)
            }
            st.lastInput = ts
        case "event_msg":
            switch payloadType(head) {
            case "task_started":
                st.lastInput = timestamp(head) ?? st.lastInput
            case "thread_settings_applied":
                guard let obj = json(line), let p = obj["payload"] as? [String: Any],
                      let settings = p["thread_settings"] as? [String: Any] else { return }
                st.tier = settings["service_tier"] as? String ?? "default"
                if let id = st.threadId { cache.threadTiers[id] = st.tier }
            default: break
            }
        case "response_item":
            guard let pt = payloadType(head) else { return }
            if pt.hasSuffix("_output") || (pt == "message" && head.contains("\"role\":\"user\"")) {
                st.lastInput = timestamp(head) ?? st.lastInput
            }
        default: break
        }
    }

    /// Codex sessions log their tier only when settings are applied. Sub-agents usually
    /// don't, and inherit the parent's; anything else falls back to config.toml.
    private func codexTier(_ st: FileState) -> String? {
        if let tier = st.tier { return Scanner.normalizeTier(tier) }
        if let parent = st.parentThread {
            if let tier = cache.threadTiers[parent] { return Scanner.normalizeTier(tier) }
            return Scanner.parentMarker + parent   // resolved after this scan's files are read
        }
        return Scanner.normalizeTier(codexDefaultTier)
    }

    private static let parentMarker = "parent:"

    /// "priority" is Codex's fast mode; standard tiers get no label.
    static func normalizeTier(_ tier: String?) -> String? {
        switch tier {
        case nil, "default", "standard", "auto": return nil
        case "priority", "fast": return "fast"
        case let other?: return other
        }
    }

    private func readCodexDefaultTier() -> String? {
        guard let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("service_tier") {
            return line.split(separator: "\"").dropFirst().first.map(String.init)
        }
        return nil
    }

    private func payloadType(_ head: String) -> String? {
        guard let r = head.range(of: "\"payload\":{\"type\":\"") else { return nil }
        return head[r.upperBound...].prefix { $0 != "\"" }.description
    }

    // MARK: Claude Code

    private func handleClaude(_ line: UnsafeRawBufferPointer, _ st: inout FileState, _ out: inout [Sample]) {
        guard let obj = json(line), let tsStr = obj["timestamp"] as? String, let ts = parseISO(tsStr) else { return }
        let type = obj["type"] as? String
        if type == "assistant", let msg = obj["message"] as? [String: Any],
           let id = msg["id"] as? String, let model = msg["model"] as? String, model != "<synthetic>",
           let usage = msg["usage"] as? [String: Any] {
            let tokens = usage["output_tokens"] as? Int ?? 0
            let tier = Scanner.normalizeTier(usage["speed"] as? String)
            if var p = st.pending, p.id == id {
                p.last = max(p.last, ts); p.tokens = max(p.tokens, tokens); st.pending = p
            } else {
                if let p = st.pending { emit(p, &out) }
                let parentTs = (obj["parentUuid"] as? String).flatMap { st.recentTs[$0] }
                let start = parentTs ?? st.lastNonAssistant ?? ts
                st.pending = ClaudePending(id: id, model: model, start: start, last: ts, tokens: tokens, tier: tier)
            }
        } else if type == "user" {
            // Not the end of the pending response: tools can run (and post results) while
            // the same message is still streaming. It ends when the next message starts.
            st.lastNonAssistant = ts
        }
        if let uuid = obj["uuid"] as? String {
            if st.recentTs.count > 2000 { st.recentTs.removeAll(keepingCapacity: true) }
            // Only prompts/tool results and responses mark real time. Attachments and other
            // bookkeeping entries are often written when the response lands, so they inherit
            // their parent's time instead of cutting the measured duration short.
            let parentTs = (obj["parentUuid"] as? String).flatMap { st.recentTs[$0] }
            st.recentTs[uuid] = (type == "user" || type == "assistant") ? ts : (parentTs ?? ts)
        }
    }

    /// A Claude response that nothing followed yet: count it once it's clearly finished.
    private func flushIdleClaude(_ st: inout FileState, _ out: inout [Sample]) {
        guard let p = st.pending, Date().timeIntervalSince1970 - p.last > 30 else { return }
        emit(p, &out)
        st.pending = nil
    }

    private func emit(_ p: ClaudePending, _ out: inout [Sample]) {
        add(Sample(source: .claude, model: p.model, end: p.last, duration: p.last - p.start, tokens: p.tokens,
                   tier: p.tier),
            id: p.id, &out)
    }

    func add(_ s: Sample, id: String? = nil, _ out: inout [Sample]) {
        // Below ~200 output tokens the wait for the first token dominates and the
        // measured rate says more about latency than speed, so skip those.
        guard s.tokens >= 200, s.duration > 0.2, s.tps < 5000,
              s.end >= Date().timeIntervalSince1970 - lookback else { return }
        if let id {
            guard cache.seen[id] == nil else { return }
            cache.seen[id] = s.end
        }
        out.append(s)
    }

    // MARK: Helpers

    private func value(of marker: String, in s: String) -> String? {
        guard let r = s.range(of: marker) else { return nil }
        return String(s[r.upperBound...].prefix { $0 != "\"" })
    }

    private func timestamp(_ head: String) -> Double? {
        value(of: "\"timestamp\":\"", in: head).flatMap(parseISO)
    }

    private func json(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Fast parser for "2026-10-09T06:59:47.669Z".
func parseISO(_ s: String) -> Double? {
    let u = Array(s.utf8)
    guard u.count >= 20, u[4] == 45, u[10] == 84 else { return nil }
    func n(_ a: Int, _ b: Int) -> Int32 {
        var v: Int32 = 0
        for i in a..<b { v = v * 10 + Int32(u[i] &- 48) }
        return v
    }
    var t = tm()
    t.tm_year = n(0, 4) - 1900; t.tm_mon = n(5, 7) - 1; t.tm_mday = n(8, 10)
    t.tm_hour = n(11, 13); t.tm_min = n(14, 16); t.tm_sec = n(17, 19)
    var frac = 0.0
    if u[19] == 46 {
        var i = 20, scale = 0.1
        while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
    }
    return Double(timegm(&t)) + frac
}

/// Calls `body` for each complete line starting at `offset`; returns the offset after the last newline.
func forEachLine(path: String, from offset: UInt64, _ body: (UnsafeRawBufferPointer) -> Void) -> UInt64 {
    guard let fh = FileHandle(forReadingAtPath: path) else { return offset }
    defer { try? fh.close() }
    do { try fh.seek(toOffset: offset) } catch { return offset }
    var pos = offset
    var carry = Data()
    while let chunk = try? fh.read(upToCount: 8 << 20), !chunk.isEmpty {
        var buf = carry
        buf.append(chunk)
        var consumed = 0
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count, let nl = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start { body(UnsafeRawBufferPointer(rebasing: raw[start..<end])) }
                start = end + 1
            }
            consumed = start
        }
        pos += UInt64(consumed)
        carry = buf.subdata(in: consumed..<buf.count)
    }
    return pos
}
