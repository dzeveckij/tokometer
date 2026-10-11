import Foundation
import SQLite3

/// OpenCode keeps sessions under $XDG_DATA_HOME/opencode (default ~/.local/share/opencode):
///   - v2: opencode.db, table `session_message` (type = 'assistant', JSON `data`)
///   - v1 SQLite: opencode.db, table `message` (JSON `data` with role = 'assistant')
///   - older: storage/message/<session>/<message>.json
/// An assistant message is one model response:
///   time { created (request sent), streamed (stream ended), completed (after its tool calls ran) } in ms,
///   tokens { output (text + tool calls), reasoning }, model { id, providerID, variant }
///   (older: modelID / providerID at the top level).
extension Scanner {
    func scanOpenCode(cutoff: Date, _ out: inout [Sample]) {
        let fm = FileManager.default
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        let dir = openCodeDir ?? base.appendingPathComponent("opencode")

        // SQLite (v1.2+ and v2). Channel builds use opencode-<channel>.db.
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("opencode") && name.hasSuffix(".db") {
            let path = dir.appendingPathComponent(name).path
            let stamp = [path, path + "-wal"].compactMap {
                (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date)?.timeIntervalSince1970
            }.max() ?? 0
            if stamp < cutoff.timeIntervalSince1970 { cache.files[path] = nil; continue }
            var st = cache.files[path] ?? FileState()
            if st.stamp == stamp { continue }
            if readOpenCodeDB(path: path, &st, &out) { st.stamp = stamp }
            cache.files[path] = st
        }

        // Older JSON storage: one file per message.
        let messages = dir.appendingPathComponent("storage/message")
        guard let en = fm.enumerator(at: messages, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en where url.pathExtension == "json" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let size = v.fileSize.map(UInt64.init), let mtime = v.contentModificationDate else { continue }
            let key = url.path
            if mtime < cutoff { cache.files[key] = nil; continue }
            if cache.files[key]?.size == size, cache.files[key]?.stamp == mtime.timeIntervalSince1970 { continue }
            var st = FileState()
            st.size = size
            if let data = try? Data(contentsOf: url),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["role"] as? String == "assistant" {
                let id = obj["id"] as? String ?? url.deletingPathExtension().lastPathComponent
                if let s = Scanner.openCodeSample(obj) {
                    add(s, id: "opencode:" + id, &out)
                    st.stamp = mtime.timeIntervalSince1970
                }
                // Not finished yet: leave stamp unset so the file is read again when it changes.
            } else {
                st.stamp = mtime.timeIntervalSince1970   // not an assistant message; skip until it changes
            }
            cache.files[key] = st
        }
    }

    /// Reads assistant messages updated since the last read. Returns false if the DB couldn't be
    /// read (retried next scan).
    private func readOpenCodeDB(path: String, _ st: inout FileState, _ out: inout [Sample]) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        var tables = Set<String>()
        guard query(db, "SELECT name FROM sqlite_master WHERE type = 'table'", { stmt in
            if let c = sqlite3_column_text(stmt, 0) { tables.insert(String(cString: c)) }
        }) else { return false }

        let sql: String
        if tables.contains("session_message") {
            sql = "SELECT id, time_updated, data FROM session_message WHERE type = 'assistant' AND time_updated > ? ORDER BY time_updated"
        } else if tables.contains("message") {
            sql = "SELECT id, time_updated, data FROM message WHERE time_updated > ? ORDER BY time_updated"
        } else {
            return true   // not an OpenCode sessions database
        }

        // Messages are rewritten while streaming and their time_updated moves forward when they
        // finish, so reading everything updated after the newest row seen picks each up once done.
        var newest = st.openCodeUpdated ?? 0
        let ok = query(db, sql, bind: newest) { stmt in
            newest = max(newest, sqlite3_column_int64(stmt, 1))
            guard let idC = sqlite3_column_text(stmt, 0), let raw = sqlite3_column_blob(stmt, 2) else { return }
            let data = Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, 2)))
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["role"] as? String ?? "assistant") == "assistant",
                  let s = Scanner.openCodeSample(obj) else { return }
            add(s, id: "opencode:" + String(cString: idC), &out)
        }
        if ok { st.openCodeUpdated = newest }
        return ok
    }

    /// A finished OpenCode assistant message as a sample; nil while streaming or if it failed.
    static func openCodeSample(_ m: [String: Any]) -> Sample? {
        guard let time = m["time"] as? [String: Any],
              let created = (time["created"] as? NSNumber)?.doubleValue,
              let end = ((time["streamed"] ?? time["completed"]) as? NSNumber)?.doubleValue,
              let tokens = m["tokens"] as? [String: Any] else { return nil }
        // `output` is the visible text and tool calls; reasoning is counted separately. Claude Code
        // and Codex both include thinking in their output, so add it here too.
        let generated = ((tokens["output"] as? NSNumber)?.intValue ?? 0)
            + ((tokens["reasoning"] as? NSNumber)?.intValue ?? 0)

        let model = m["model"] as? [String: Any]
        guard let id = model?["id"] as? String ?? m["modelID"] as? String else { return nil }
        let provider = model?["providerID"] as? String ?? m["providerID"] as? String
        let variant = model?["variant"] as? String ?? m["variant"] as? String

        // OpenCode's own models are shown by name; the same model through another provider
        // (e.g. openrouter) can be much faster or slower, so keep the provider in the label.
        let name = provider == nil || provider == "opencode" ? id : "\(provider!)/\(id)"
        return Sample(source: .opencode, model: name, end: end / 1000, duration: (end - created) / 1000,
                      tokens: generated, tier: variant == "default" ? nil : variant)
    }

    private func query(_ db: OpaquePointer?, _ sql: String, bind: Int64? = nil, _ row: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        if let bind { sqlite3_bind_int64(stmt, 1, bind) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { row(stmt); rc = sqlite3_step(stmt) }
        return rc == SQLITE_DONE
    }
}
