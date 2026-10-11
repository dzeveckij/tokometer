import Foundation
import SQLite3

/// Antigravity (app, CLI, IDE) keeps each conversation in a SQLite DB under ~/.gemini/<variant>/conversations.
/// Model responses are `steps` rows with step_type 15; their `metadata` protobuf holds:
///   .1 created timestamp, .7 completed timestamp, .9 usage { .1 model enum, .3 output tokens }.
/// `gen_metadata` rows map the model enum to a name: .3 { .1 enum, .28 name }.
extension Scanner {
    func scanAntigravity(cutoff: Date, _ out: inout [Sample]) {
        let fm = FileManager.default
        for variant in ["antigravity", "antigravity-cli", "antigravity-ide"] {
            let dir = home.appendingPathComponent(".gemini/\(variant)/conversations")
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".db") {
                let path = dir.appendingPathComponent(name).path
                // The WAL changes before the main file does, so it counts toward "modified".
                let stamp = [path, path + "-wal"].compactMap {
                    (try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date)?.timeIntervalSince1970
                }.max() ?? 0
                if stamp < cutoff.timeIntervalSince1970 { cache.files[path] = nil; continue }
                var st = cache.files[path] ?? FileState()
                if st.stamp == stamp { continue }
                if readAntigravity(path: path, &st, &out) { st.stamp = stamp }
                cache.files[path] = st
            }
        }
    }

    /// Returns false if the DB couldn't be read (retried next scan).
    private func readAntigravity(path: String, _ st: inout FileState, _ out: inout [Sample]) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let namesOK = forEachRow(db, "SELECT data FROM gen_metadata") { stmt in
            guard let cfg = PB(blob(stmt, 0)).bytes(3).map(PB.init),
                  let id = cfg.varint(1), let name = cfg.string(28) else { return true }
            cache.agyModels[Int(id)] = name
            return true
        }

        let after = st.agyLastIdx ?? -1
        var lastDone = after
        let ok = forEachRow(db, "SELECT idx, metadata FROM steps WHERE step_type = 15 AND idx > \(after) ORDER BY idx") { stmt in
            let idx = Int(sqlite3_column_int64(stmt, 0))
            let meta = PB(blob(stmt, 1))
            // Still streaming: stop here and pick it up once it completes.
            guard let end = meta.timestamp(7) else { return false }
            lastDone = idx
            guard let start = meta.timestamp(1), let usage = meta.bytes(9).map(PB.init),
                  let tokens = usage.varint(3) else { return true }
            let id = Int(usage.varint(1) ?? 0)
            let model = cache.agyModels[id] ?? "model-\(id)"
            add(Sample(source: .antigravity, model: model, end: end, duration: end - start, tokens: Int(tokens)), &out)
            return true
        }
        st.agyLastIdx = lastDone
        return ok && namesOK
    }

    /// Returns false on any SQLite error (e.g. busy while Antigravity writes), so the DB is retried.
    private func forEachRow(_ db: OpaquePointer?, _ sql: String, _ body: (OpaquePointer?) -> Bool) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if !body(stmt) { return true }
            rc = sqlite3_step(stmt)
        }
        return rc == SQLITE_DONE
    }

    private func blob(_ stmt: OpaquePointer?, _ col: Int32) -> [UInt8] {
        guard let p = sqlite3_column_blob(stmt, col) else { return [] }
        return Array(UnsafeRawBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, col))))
    }
}

/// Minimal protobuf reader: first occurrence of each top-level field.
struct PB {
    private var varints: [Int: UInt64] = [:]
    private var blobs: [Int: ArraySlice<UInt8>] = [:]

    init(_ b: ArraySlice<UInt8>) {
        var i = b.startIndex
        func varint() -> UInt64? {
            var r: UInt64 = 0, s: UInt64 = 0
            while i < b.endIndex, s < 64 {
                let c = b[i]; i += 1
                r |= UInt64(c & 0x7f) << s; s += 7
                if c < 0x80 { return r }
            }
            return nil
        }
        while i < b.endIndex, let key = varint() {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: guard let v = varint() else { return }; if varints[field] == nil { varints[field] = v }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(), n <= UInt64(b.endIndex - i) else { return }
                if blobs[field] == nil { blobs[field] = b[i..<i + Int(n)] }
                i += Int(n)
            default: return
            }
        }
    }
    init(_ b: [UInt8]) { self.init(b[...]) }

    func varint(_ f: Int) -> UInt64? { varints[f] }
    func bytes(_ f: Int) -> ArraySlice<UInt8>? { blobs[f] }
    func string(_ f: Int) -> String? { blobs[f].flatMap { String(bytes: $0, encoding: .utf8) } }
    /// google.protobuf.Timestamp { 1: seconds, 2: nanos }
    func timestamp(_ f: Int) -> Double? {
        guard let t = bytes(f).map(PB.init), let s = t.varint(1) else { return nil }
        return Double(s) + Double(t.varint(2) ?? 0) / 1e9
    }
}
