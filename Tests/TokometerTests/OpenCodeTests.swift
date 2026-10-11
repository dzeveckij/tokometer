import XCTest
import SQLite3
@testable import Tokometer

final class OpenCodeTests: XCTestCase {
    private var dir: URL!
    private let now = Date().timeIntervalSince1970 * 1000   // ms, like OpenCode

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func scanner() -> Tokometer.Scanner {
        let s = Tokometer.Scanner()
        s.openCodeDir = dir
        return s
    }

    private func scan(_ s: Tokometer.Scanner) -> [Sample] {
        var out: [Sample] = []
        s.scanOpenCode(cutoff: Date().addingTimeInterval(-s.lookback), &out)
        return out
    }

    /// Current (v2) message JSON.
    private func v2Message(created: Double, streamed: Double?, completed: Double?, output: Int, reasoning: Int,
                           model: String = "big-pickle", provider: String = "opencode", variant: String = "default") -> String {
        var time = ["\"created\":\(Int(created))"]
        if let streamed { time.append("\"streamed\":\(Int(streamed))") }
        if let completed { time.append("\"completed\":\(Int(completed))") }
        return """
        {"time":{\(time.joined(separator: ","))},"agent":"build",
         "model":{"id":"\(model)","providerID":"\(provider)","variant":"\(variant)"},
         "content":[],"finish":"stop",
         "tokens":{"input":1000,"output":\(output),"reasoning":\(reasoning),"cache":{"read":0,"write":0}}}
        """
    }

    // MARK: Parsing

    func testParsesV2MessageUsingStreamEndAndCountingReasoning() throws {
        let json = v2Message(created: now - 10_000, streamed: now - 5_000, completed: now, output: 300, reasoning: 200)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let s = try XCTUnwrap(Tokometer.Scanner.openCodeSample(obj))
        XCTAssertEqual(s.source, .opencode)
        XCTAssertEqual(s.model, "big-pickle")
        XCTAssertNil(s.tier)
        XCTAssertEqual(s.tokens, 500)                       // output + reasoning
        XCTAssertEqual(s.duration, 5, accuracy: 0.001)      // created -> streamed, not tool time after it
    }

    func testKeepsProviderAndVariantInLabel() throws {
        let json = v2Message(created: now - 4_000, streamed: nil, completed: now, output: 400, reasoning: 0,
                             model: "claude-sonnet-4-5", provider: "openrouter", variant: "high")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let s = try XCTUnwrap(Tokometer.Scanner.openCodeSample(obj))
        XCTAssertEqual(s.model, "openrouter/claude-sonnet-4-5")
        XCTAssertEqual(s.tier, "high")
        XCTAssertEqual(s.duration, 4, accuracy: 0.001)      // falls back to completed
        XCTAssertEqual(displayName(s.model, tier: s.tier), "openrouter/claude-sonnet-4-5 · High")
    }

    func testSkipsUnfinishedOrFailedMessages() throws {
        let streaming = v2Message(created: now, streamed: nil, completed: nil, output: 300, reasoning: 0)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(streaming.utf8)) as? [String: Any])
        XCTAssertNil(Tokometer.Scanner.openCodeSample(obj))
        let failed: [String: Any] = ["time": ["created": now, "completed": now + 1000], "model": ["id": "x"], "finish": "error"]
        XCTAssertNil(Tokometer.Scanner.openCodeSample(failed))        // no tokens
    }

    // MARK: Older JSON storage

    func testReadsLegacyJSONStorage() throws {
        let session = dir.appendingPathComponent("storage/message/ses_1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let assistant = """
        {"id":"msg_a","sessionID":"ses_1","role":"assistant","modelID":"gpt-5","providerID":"openai",
         "time":{"created":\(Int(now - 8_000)),"completed":\(Int(now))},
         "tokens":{"input":10,"output":600,"reasoning":200,"cache":{"read":0,"write":0}}}
        """
        let user = #"{"id":"msg_u","sessionID":"ses_1","role":"user","time":{"created":1}}"#
        try assistant.write(to: session.appendingPathComponent("msg_a.json"), atomically: true, encoding: .utf8)
        try user.write(to: session.appendingPathComponent("msg_u.json"), atomically: true, encoding: .utf8)

        let s = scanner()
        let found = scan(s)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.model, "openai/gpt-5")
        XCTAssertEqual(found.first?.tokens, 800)
        XCTAssertEqual(found.first?.duration ?? 0, 8, accuracy: 0.001)
        XCTAssertTrue(scan(s).isEmpty, "unchanged files aren't read again")
    }

    // MARK: SQLite

    private func makeDB(_ schema: String) throws -> OpaquePointer? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("opencode.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        return db
    }

    private func exec(_ db: OpaquePointer?, _ sql: String, _ args: [Any]) {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            if let n = a as? Int { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n)) }
            else if let t = a as? String { sqlite3_bind_text(stmt, Int32(i + 1), t, -1, transient) }
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    /// Writes bump the file's modification time; make sure the next scan sees a new stamp.
    private func touch() throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double.random(in: 1...5))],
                                              ofItemAtPath: dir.appendingPathComponent("opencode.db").path)
    }

    func testV2DatabasePicksUpMessagesOnceTheyFinish() throws {
        let db = try makeDB("""
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
                time_created INTEGER, time_updated INTEGER, data TEXT);
            """)
        defer { sqlite3_close(db) }
        let created = now - 6_000
        exec(db, "INSERT INTO session_message VALUES (?,?,?,?,?,?,?)",
             ["m1", "s1", "user", 1, Int(created - 100), Int(created - 100), #"{"text":"hi"}"#])
        exec(db, "INSERT INTO session_message VALUES (?,?,?,?,?,?,?)",
             ["m2", "s1", "assistant", 2, Int(created), Int(created + 1),
              v2Message(created: created, streamed: nil, completed: nil, output: 0, reasoning: 0)])

        let s = scanner()
        XCTAssertTrue(scan(s).isEmpty, "still streaming")

        exec(db, "UPDATE session_message SET time_updated = ?, data = ? WHERE id = 'm2'",
             [Int(now), v2Message(created: created, streamed: now - 1_000, completed: now, output: 400, reasoning: 100)])
        try touch()
        let found = scan(s)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.tokens, 500)
        XCTAssertEqual(found.first?.duration ?? 0, 5, accuracy: 0.01)

        try touch()
        XCTAssertTrue(scan(s).isEmpty, "a finished message is counted once")
    }

    func testV1DatabaseMessageTable() throws {
        let db = try makeDB("""
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER,
                time_updated INTEGER, data TEXT);
            """)
        defer { sqlite3_close(db) }
        let created = now - 3_000
        exec(db, "INSERT INTO message VALUES (?,?,?,?,?)",
             ["u1", "s1", Int(created), Int(created), #"{"role":"user","time":{"created":1}}"#])
        exec(db, "INSERT INTO message VALUES (?,?,?,?,?)",
             ["a1", "s1", Int(created), Int(now), """
              {"role":"assistant","modelID":"kimi-k2","providerID":"opencode",
               "time":{"created":\(Int(created)),"completed":\(Int(now))},
               "tokens":{"input":5,"output":300,"reasoning":0,"cache":{"read":0,"write":0}}}
              """])
        let found = scan(scanner())
        XCTAssertEqual(found.map(\.model), ["kimi-k2"])
        XCTAssertEqual(found.first?.duration ?? 0, 3, accuracy: 0.01)
    }

    func testShortRepliesAreIgnored() throws {
        let db = try makeDB("""
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
                time_created INTEGER, time_updated INTEGER, data TEXT);
            """)
        defer { sqlite3_close(db) }
        exec(db, "INSERT INTO session_message VALUES (?,?,?,?,?,?,?)",
             ["m1", "s1", "assistant", 1, Int(now - 2_000), Int(now),
              v2Message(created: now - 2_000, streamed: now, completed: now, output: 50, reasoning: 20)])
        XCTAssertTrue(scan(scanner()).isEmpty, "under 200 tokens the rate mostly measures latency")
    }
}
