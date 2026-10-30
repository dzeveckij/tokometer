import Foundation

/// pi (pi-coding-agent) and its fork OMP (oh-my-pi) write the same session format:
///   <agent dir>/sessions/<encoded cwd>/<timestamp>_<id>.jsonl   (OMP sub-agents: <session>/<name>.jsonl)
/// with agent dirs ~/.pi/agent ($PI_CODING_AGENT_DIR) and ~/.omp/agent. Each model call is a
///   {"type":"message", "timestamp": <ISO, written when the call ends>,
///    "message": {"role":"assistant", "provider", "model", "usage": {"output", ...},
///                "stopReason", "timestamp": <ms, call start>, "duration"?, "completedAt"?}}
/// entry; `output` already includes reasoning. OMP adds duration/completedAt; for pi the entry's
/// own timestamp marks the end (it's written before any tool runs).
extension Scanner {
    func scanPiAgents(cutoff: Date, _ out: inout [Sample]) {
        let env = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) }
        let roots: [(URL, Source)] = [
            (piDir ?? env ?? home.appendingPathComponent(".pi/agent"), .pi),
            (ompDir ?? home.appendingPathComponent(".omp/agent"), .omp),
        ]
        for (agentDir, source) in roots {
            guard let en = FileManager.default.enumerator(
                at: agentDir.appendingPathComponent("sessions"),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let size = v.fileSize.map(UInt64.init), let mtime = v.contentModificationDate else { continue }
                let key = url.path
                if mtime < cutoff { cache.files[key] = nil; continue }
                var st = cache.files[key] ?? FileState()
                if st.size == size { continue }
                if size < st.offset { st = FileState() }
                st.size = size
                st.offset = forEachLine(path: url.path, from: st.offset) { line in handlePi(line, source, &out) }
                cache.files[key] = st
            }
        }
    }

    private func handlePi(_ line: UnsafeRawBufferPointer, _ source: Source, _ out: inout [Sample]) {
        // Role sits near the start; tool results can make other lines huge.
        let head = String(decoding: UnsafeRawBufferPointer(rebasing: line.prefix(400)), as: UTF8.self)
        guard head.contains("\"type\":\"message\""), head.contains("\"role\":\"assistant\""),
              let entry = json(line), let s = Scanner.piSample(entry, source: source) else { return }
        // Forked sessions copy entries with their ids and timestamps, so this dedupes them.
        let id = (entry["message"] as? [String: Any])?["responseId"] as? String
            ?? "\(entry["id"] as? String ?? ""):\(Int(s.end * 1000))"
        add(s, id: "\(source.rawValue):\(id)", &out)
    }

    static func piSample(_ entry: [String: Any], source: Source) -> Sample? {
        guard let m = entry["message"] as? [String: Any], m["role"] as? String == "assistant",
              let model = m["model"] as? String,
              let start = (m["timestamp"] as? NSNumber)?.doubleValue,
              let usage = m["usage"] as? [String: Any],
              let tokens = (usage["output"] as? NSNumber)?.intValue else { return nil }
        if let stop = m["stopReason"] as? String, stop == "error" || stop == "aborted" { return nil }

        let end: Double
        if let done = (m["completedAt"] as? NSNumber)?.doubleValue {
            end = done
        } else if let ms = (m["duration"] as? NSNumber)?.doubleValue {
            end = start + ms
        } else if let iso = entry["timestamp"] as? String, let t = parseISO(iso) {
            end = t * 1000
        } else {
            return nil
        }
        // Both tools reach the same model through many providers, which differ a lot in speed.
        let name = (m["provider"] as? String).map { "\($0)/\(model)" } ?? model
        return Sample(source: source, model: name, end: end / 1000, duration: (end - start) / 1000, tokens: tokens)
    }
}
