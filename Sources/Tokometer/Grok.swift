import Foundation

/// Grok Build keeps each session under $GROK_HOME/sessions/<encoded-cwd>/<session-id>/ (default
/// ~/.grok). `updates.jsonl` is the session's event log; when a turn ends it gets a
/// `turn_completed` update whose usage has, per backend model:
///   outputTokens (including reasoning), apiDurationMs (time in model calls, not tools), modelCalls.
/// Grok doesn't log individual model calls, so a sample is one turn of one model: its tokens
/// over its API time, which is the token-weighted speed of that turn's calls.
extension Scanner {
    func scanGrok(cutoff: Date, _ out: inout [Sample]) {
        let home = grokHome
            ?? ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? self.home.appendingPathComponent(".grok")
        guard let en = FileManager.default.enumerator(
            at: home.appendingPathComponent("sessions"),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en where url.lastPathComponent == "updates.jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = v.fileSize.map(UInt64.init), let mtime = v.contentModificationDate else { continue }
            let key = url.path
            if mtime < cutoff { cache.files[key] = nil; continue }
            var st = cache.files[key] ?? FileState()
            if st.size == size { continue }
            if size < st.offset { st = FileState() }
            st.size = size
            st.offset = forEachLine(path: url.path, from: st.offset) { line in handleGrok(line, &st, &out) }
            cache.files[key] = st
        }
    }

    private func handleGrok(_ line: UnsafeRawBufferPointer, _ st: inout FileState, _ out: inout [Sample]) {
        // The update kind sits near the start of the line; tool output can make lines huge.
        let head = String(decoding: UnsafeRawBufferPointer(rebasing: line.prefix(400)), as: UTF8.self)
        if head.contains("\"user_message_chunk\"") {
            // The model the user picked, e.g. "grok-4.7" (answered by "grok-4.7-build").
            if let obj = json(line), let params = obj["params"] as? [String: Any],
               let update = params["update"] as? [String: Any],
               let meta = update["_meta"] as? [String: Any], let model = meta["modelId"] as? String {
                st.model = model
            }
            return
        }
        guard head.contains("\"turn_completed\""), let obj = json(line),
              let params = obj["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let usage = update["usage"] as? [String: Any] else { return }
        let meta = params["_meta"] as? [String: Any]
        guard let endMs = (meta?["agentTimestampMs"] as? NSNumber)?.doubleValue
                ?? (obj["timestamp"] as? NSNumber).map({ $0.doubleValue * 1000 }) else { return }
        let turn = update["prompt_id"] as? String ?? meta?["eventId"] as? String ?? "\(endMs)"

        var perModel = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
        if perModel.isEmpty, let model = st.model { perModel = [model: usage] }
        for (model, u) in perModel {
            guard let tokens = (u["outputTokens"] as? NSNumber)?.intValue,
                  let apiMs = (u["apiDurationMs"] as? NSNumber)?.doubleValue else { continue }
            add(Sample(source: .grok, model: model, end: endMs / 1000, duration: apiMs / 1000, tokens: tokens,
                       requested: st.model != nil && st.model != model ? st.model : nil),
                id: "grok:\(turn):\(model)", &out)
        }
    }
}
