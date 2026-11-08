import Foundation

/// GitHub Copilot CLI keeps each session in $COPILOT_HOME/session-state/<id>/events.jsonl
/// (default ~/.copilot). Every model call adds a `session.usage_record` event:
///   {"type":"session.usage_record", "data":{"usage":{"model", "provider", "isByok",
///    "outputTokens" (reasoning included), "duration" (ms, the call only, not tools),
///    "accounting":{"usageId"}}}, "id", "timestamp": <ISO, when the call ended>}
extension Scanner {
    func scanCopilot(cutoff: Date, _ out: inout [Sample]) {
        let home = copilotHome
            ?? ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? self.home.appendingPathComponent(".copilot")
        let sessions = home.appendingPathComponent("session-state")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            let url = sessions.appendingPathComponent(name).appendingPathComponent("events.jsonl")
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = v.fileSize.map(UInt64.init), let mtime = v.contentModificationDate else { continue }
            let key = url.path
            if mtime < cutoff { cache.files[key] = nil; continue }
            var st = cache.files[key] ?? FileState()
            if st.size == size { continue }
            if size < st.offset { st = FileState() }
            st.size = size
            st.offset = forEachLine(path: url.path, from: st.offset) { line in handleCopilot(line, &out) }
            cache.files[key] = st
        }
    }

    private func handleCopilot(_ line: UnsafeRawBufferPointer, _ out: inout [Sample]) {
        // The event type comes first; other events can be huge.
        let head = String(decoding: UnsafeRawBufferPointer(rebasing: line.prefix(200)), as: UTF8.self)
        guard head.contains("\"session.usage_record\""), let event = json(line),
              let s = Scanner.copilotSample(event) else { return }
        // Forked sessions copy usage with its accounting id, so this counts each call once.
        let usage = (event["data"] as? [String: Any])?["usage"] as? [String: Any]
        let id = (usage?["accounting"] as? [String: Any])?["usageId"] as? String ?? event["id"] as? String
        add(s, id: id.map { "copilot:\($0)" }, &out)
    }

    static func copilotSample(_ event: [String: Any]) -> Sample? {
        guard event["type"] as? String == "session.usage_record",
              let usage = (event["data"] as? [String: Any])?["usage"] as? [String: Any],
              let model = usage["model"] as? String,
              let tokens = (usage["outputTokens"] as? NSNumber)?.intValue,
              let ms = (usage["duration"] as? NSNumber)?.doubleValue,
              let iso = event["timestamp"] as? String, let end = parseISO(iso) else { return nil }
        // Your own API key can reach the same model through a much faster or slower provider.
        let byok = (usage["isByok"] as? NSNumber)?.boolValue == true
        let name = byok ? (usage["provider"] as? String).map { "\($0)/\(model)" } ?? model : model
        return Sample(source: .copilot, model: name, end: end, duration: ms / 1000, tokens: tokens)
    }
}
